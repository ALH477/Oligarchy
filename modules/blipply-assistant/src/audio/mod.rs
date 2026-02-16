// Blipply Assistant - Audio Pipeline
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

pub mod stt;
pub mod tts;
pub mod vad;

pub use stt::SttPipeline;
pub use tts::TtsPipeline;
pub use vad::VoiceActivityDetector;

use anyhow::Result;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum AudioEvent {
    SpeechStart,
    SpeechEnd,
    TranscriptPartial(String),
    TranscriptFinal(String),
    TtsStarted,
    TtsFinished,
}

pub type AudioEventSender = mpsc::UnboundedSender<AudioEvent>;
pub type AudioEventReceiver = mpsc::UnboundedReceiver<AudioEvent>;

pub fn create_audio_channel() -> (AudioEventSender, AudioEventReceiver) {
    mpsc::unbounded_channel()
}

/// Convert f32 samples [-1.0, 1.0] to i16 samples
pub fn f32_to_i16(samples: &[f32]) -> Vec<i16> {
    samples.iter()
        .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
        .collect()
}

/// Convert i16 samples to f32 samples [-1.0, 1.0]
pub fn i16_to_f32(samples: &[i16]) -> Vec<f32> {
    samples.iter()
        .map(|&s| s as f32 / 32767.0)
        .collect()
}

/// Resample audio from one sample rate to another
pub fn resample(samples: &[f32], from_rate: u32, to_rate: u32) -> Result<Vec<f32>> {
    use rubato::{Resampler, SincFixedIn, InterpolationType, InterpolationParameters, WindowFunction};
    
    if from_rate == to_rate {
        return Ok(samples.to_vec());
    }
    
    let params = InterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: InterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };
    
    let mut resampler = SincFixedIn::<f32>::new(
        to_rate as f64 / from_rate as f64,
        2.0,
        params,
        samples.len(),
        1,
    )?;
    
    let input = vec![samples.to_vec()];
    let output = resampler.process(&input, None)?;
    
    Ok(output[0].clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_f32_to_i16_conversion() {
        let input = vec![0.0, 0.5, -0.5, 1.0, -1.0];
        let output = f32_to_i16(&input);
        assert_eq!(output.len(), input.len());
        assert_eq!(output[0], 0);
        assert!(output[1] > 0);
        assert!(output[2] < 0);
    }

    #[test]
    fn test_resample_same_rate() {
        let input = vec![0.0, 0.5, -0.5];
        let output = resample(&input, 16000, 16000).unwrap();
        assert_eq!(input, output);
    }
}
