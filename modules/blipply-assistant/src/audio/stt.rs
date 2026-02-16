// Blipply Assistant - Audio Pipeline
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Stream, StreamConfig, SampleRate};
use parking_lot::Mutex;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{debug, error, warn};
use whisper_rs::{WhisperContext, FullParams, SamplingStrategy};

use super::{AudioEvent, AudioEventSender, VoiceActivityDetector, f32_to_i16};

pub struct SttPipeline {
    whisper_ctx: Arc<WhisperContext>,
    vad: Arc<Mutex<VoiceActivityDetector>>,
    sample_rate: u32,
    event_tx: AudioEventSender,
    audio_buffer: Arc<Mutex<Vec<f32>>>,
    stream: Option<Stream>,
}

impl SttPipeline {
    pub fn new(
        model_path: impl AsRef<std::path::Path>,
        sample_rate: u32,
        vad_aggressiveness: u8,
        silence_duration_ms: u64,
        event_tx: AudioEventSender,
    ) -> Result<Self> {
        debug!("Loading Whisper model from {:?}", model_path.as_ref());
        
        let ctx = WhisperContext::new(model_path.as_ref())
            .context("Failed to load Whisper model")?;

        let vad = VoiceActivityDetector::new(sample_rate, vad_aggressiveness, silence_duration_ms)?;

        Ok(Self {
            whisper_ctx: Arc::new(ctx),
            vad: Arc::new(Mutex::new(vad)),
            sample_rate,
            event_tx,
            audio_buffer: Arc::new(Mutex::new(Vec::new())),
            stream: None,
        })
    }

    pub fn start(&mut self) -> Result<()> {
        if self.stream.is_some() {
            warn!("STT pipeline already started");
            return Ok(());
        }

        debug!("Starting STT audio capture");

        let host = cpal::default_host();
        let device = host.default_input_device()
            .context("No input device available")?;

        debug!("Using input device: {}", device.name()?);

        let config = StreamConfig {
            channels: 1,
            sample_rate: SampleRate(self.sample_rate),
            buffer_size: cpal::BufferSize::Fixed(480), // 30ms at 16kHz
        };

        let vad = self.vad.clone();
        let audio_buffer = self.audio_buffer.clone();
        let event_tx = self.event_tx.clone();
        let whisper_ctx = self.whisper_ctx.clone();
        let sample_rate = self.sample_rate;

        let stream = device.build_input_stream(
            &config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                Self::audio_callback(
                    data,
                    vad.clone(),
                    audio_buffer.clone(),
                    event_tx.clone(),
                    whisper_ctx.clone(),
                    sample_rate,
                );
            },
            move |err| {
                error!("Audio stream error: {}", err);
            },
            None,
        )?;

        stream.play()?;
        self.stream = Some(stream);

        debug!("STT pipeline started successfully");
        Ok(())
    }

    fn audio_callback(
        data: &[f32],
        vad: Arc<Mutex<VoiceActivityDetector>>,
        audio_buffer: Arc<Mutex<Vec<f32>>>,
        event_tx: AudioEventSender,
        whisper_ctx: Arc<WhisperContext>,
        sample_rate: u32,
    ) {
        // Convert to i16 for VAD
        let i16_samples = f32_to_i16(data);

        // Process VAD frame
        let vad_result = {
            let mut vad = vad.lock();
            vad.process_frame(&i16_samples)
        };

        match vad_result {
            Ok(vad_event) => {
                use super::vad::VadEvent;
                
                match vad_event {
                    VadEvent::SpeechStart => {
                        debug!("Speech started");
                        event_tx.send(AudioEvent::SpeechStart).ok();
                        
                        // Start collecting audio
                        let mut buffer = audio_buffer.lock();
                        buffer.clear();
                        buffer.extend_from_slice(data);
                    }
                    VadEvent::Speaking => {
                        // Continue collecting audio
                        let mut buffer = audio_buffer.lock();
                        buffer.extend_from_slice(data);
                    }
                    VadEvent::SpeechEnd => {
                        debug!("Speech ended");
                        event_tx.send(AudioEvent::SpeechEnd).ok();

                        // Transcribe collected audio
                        let audio = {
                            let mut buffer = audio_buffer.lock();
                            let audio = buffer.clone();
                            buffer.clear();
                            audio
                        };

                        if audio.len() > sample_rate as usize / 2 { // At least 0.5 seconds
                            let whisper = whisper_ctx.clone();
                            let tx = event_tx.clone();
                            
                            // Spawn blocking task for transcription
                            tokio::task::spawn_blocking(move || {
                                match Self::transcribe(&whisper, &audio) {
                                    Ok(text) if !text.trim().is_empty() => {
                                        debug!("Transcribed: {}", text);
                                        tx.send(AudioEvent::TranscriptFinal(text)).ok();
                                    }
                                    Ok(_) => {
                                        debug!("Empty transcription");
                                    }
                                    Err(e) => {
                                        error!("Transcription failed: {}", e);
                                    }
                                }
                            });
                        } else {
                            debug!("Audio too short to transcribe");
                        }
                    }
                    VadEvent::Silence => {
                        // Do nothing
                    }
                }
            }
            Err(e) => {
                error!("VAD error: {}", e);
            }
        }
    }

    fn transcribe(ctx: &WhisperContext, samples: &[f32]) -> Result<String> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_language(Some("en"));
        params.set_n_threads(4);
        params.set_translate(false);
        params.set_no_context(false);
        params.set_single_segment(false);

        let mut state = ctx.create_state()
            .context("Failed to create Whisper state")?;
        
        state.full(params, samples)
            .context("Whisper transcription failed")?;

        let num_segments = state.full_n_segments()
            .context("Failed to get segment count")?;

        let mut text = String::new();
        for i in 0..num_segments {
            let segment = state.full_get_segment_text(i)
                .context("Failed to get segment text")?;
            text.push_str(&segment);
            text.push(' ');
        }

        Ok(text.trim().to_string())
    }

    pub fn stop(&mut self) {
        if let Some(stream) = self.stream.take() {
            drop(stream);
            debug!("STT pipeline stopped");
        }
    }
}

impl Drop for SttPipeline {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_f32_to_i16() {
        let samples = vec![0.0, 0.5, -0.5, 1.0, -1.0];
        let i16_samples = f32_to_i16(&samples);
        assert_eq!(i16_samples.len(), samples.len());
    }
}
