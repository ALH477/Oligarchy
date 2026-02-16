// Blipply Assistant - Audio Pipeline
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{StreamConfig, SampleRate};
use ort::{Session, Value, GraphOptimizationLevel, ExecutionProvider};
use parking_lot::Mutex;
use std::path::Path;
use std::sync::Arc;
use tracing::{debug, error};

use super::AudioEventSender;

pub struct TtsPipeline {
    session: Arc<Session>,
    config: PiperConfig,
    output_sample_rate: u32,
    event_tx: Option<AudioEventSender>,
}

#[derive(Debug, Clone)]
struct PiperConfig {
    num_speakers: usize,
    sample_rate: u32,
}

impl TtsPipeline {
    pub fn new(
        model_path: impl AsRef<Path>,
        config_path: impl AsRef<Path>,
        speed: f32,
        event_tx: Option<AudioEventSender>,
    ) -> Result<Self> {
        debug!("Loading Piper TTS model from {:?}", model_path.as_ref());

        // Initialize ONNX Runtime
        ort::init()
            .with_execution_providers([ExecutionProvider::CPU(Default::default())])
            .commit()?;

        // Load model
        let session = Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(4)?
            .commit_from_file(model_path)?;

        // Load config (simplified - in practice you'd parse the JSON)
        let config = Self::load_config(config_path)?;

        Ok(Self {
            session: Arc::new(session),
            config,
            output_sample_rate: 22050, // Piper default
            event_tx,
        })
    }

    fn load_config(config_path: impl AsRef<Path>) -> Result<PiperConfig> {
        // In a real implementation, parse the Piper config JSON
        // For now, use defaults
        Ok(PiperConfig {
            num_speakers: 1,
            sample_rate: 22050,
        })
    }

    pub async fn speak(&self, text: &str) -> Result<()> {
        debug!("Synthesizing speech for: {}", text);

        if let Some(ref tx) = self.event_tx {
            tx.send(super::AudioEvent::TtsStarted).ok();
        }

        // Prepare input (phonemes from text)
        let phonemes = self.text_to_phonemes(text)?;
        
        // Run inference
        let audio = self.synthesize(&phonemes)?;

        // Play audio
        self.play_audio(&audio).await?;

        if let Some(ref tx) = self.event_tx {
            tx.send(super::AudioEvent::TtsFinished).ok();
        }

        Ok(())
    }

    fn text_to_phonemes(&self, text: &str) -> Result<Vec<i64>> {
        // In a real implementation, you would:
        // 1. Use espeak-ng or piper's phonemizer to convert text to phonemes
        // 2. Map phonemes to integer IDs
        // For this stub, we'll simulate it
        
        // This is a simplified version - real Piper needs proper phonemization
        let phonemes: Vec<i64> = text.chars()
            .filter_map(|c| {
                if c.is_ascii_alphabetic() {
                    Some((c.to_ascii_lowercase() as i64) - ('a' as i64) + 1)
                } else if c == ' ' {
                    Some(0)
                } else {
                    None
                }
            })
            .collect();

        Ok(phonemes)
    }

    fn synthesize(&self, phonemes: &[i64]) -> Result<Vec<f32>> {
        // Prepare input tensor
        let input_len = phonemes.len() as i64;
        let input_array = ndarray::Array2::from_shape_vec(
            (1, phonemes.len()),
            phonemes.to_vec(),
        )?;

        // Create input
        let inputs = vec![
            ("input", Value::from_array(input_array)?),
            ("input_lengths", Value::from_array(ndarray::arr1(&[input_len]))?),
            ("scales", Value::from_array(ndarray::arr1(&[0.667, 1.0, 0.8]))?),
        ];

        // Run inference
        let outputs = self.session.run(inputs)?;

        // Extract audio
        let audio_tensor = outputs["output"].try_extract_tensor::<f32>()?;
        let audio: Vec<f32> = audio_tensor.view().iter().copied().collect();

        debug!("Generated {} audio samples", audio.len());
        Ok(audio)
    }

    async fn play_audio(&self, samples: &[f32]) -> Result<()> {
        let host = cpal::default_host();
        let device = host.default_output_device()
            .context("No output device available")?;

        debug!("Using output device: {}", device.name()?);

        let config = StreamConfig {
            channels: 1,
            sample_rate: SampleRate(self.output_sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let samples = Arc::new(Mutex::new(samples.to_vec()));
        let sample_index = Arc::new(Mutex::new(0usize));

        let stream = device.build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut idx = sample_index.lock();
                let audio = samples.lock();

                for sample in data.iter_mut() {
                    *sample = if *idx < audio.len() {
                        let value = audio[*idx];
                        *idx += 1;
                        value
                    } else {
                        0.0
                    };
                }
            },
            move |err| {
                error!("TTS playback error: {}", err);
            },
            None,
        )?;

        stream.play()?;

        // Calculate playback duration
        let duration_secs = samples.len() as f64 / self.output_sample_rate as f64;
        let duration = std::time::Duration::from_secs_f64(duration_secs + 0.1);

        tokio::time::sleep(duration).await;

        Ok(())
    }

    pub async fn speak_streaming<S>(&self, mut text_stream: S) -> Result<()>
    where
        S: futures::Stream<Item = String> + Unpin,
    {
        use futures::StreamExt;

        let mut buffer = String::new();

        while let Some(chunk) = text_stream.next().await {
            buffer.push_str(&chunk);

            // Detect sentence boundaries
            if let Some(pos) = buffer.rfind(|c| c == '.' || c == '!' || c == '?') {
                let sentence = buffer.drain(..=pos).collect::<String>();
                
                if !sentence.trim().is_empty() {
                    self.speak(&sentence).await?;
                }
            }
        }

        // Speak remaining text
        if !buffer.trim().is_empty() {
            self.speak(&buffer).await?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_text_to_phonemes() {
        let tts = TtsPipeline {
            session: Arc::new(Session::builder().unwrap().commit_from_file("dummy").unwrap()),
            config: PiperConfig { num_speakers: 1, sample_rate: 22050 },
            output_sample_rate: 22050,
            event_tx: None,
        };
        
        let phonemes = tts.text_to_phonemes("hello").unwrap();
        assert!(!phonemes.is_empty());
    }
}
