// Blipply Assistant - Audio Pipeline
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use webrtc_vad::{Vad, SampleRate, Mode};
use std::time::{Duration, Instant};

pub struct VoiceActivityDetector {
    vad: Vad,
    sample_rate: u32,
    frame_duration_ms: u32,
    silence_duration: Duration,
    last_speech_time: Option<Instant>,
    is_speaking: bool,
}

impl VoiceActivityDetector {
    pub fn new(sample_rate: u32, aggressiveness: u8, silence_duration_ms: u64) -> Result<Self> {
        let vad_sample_rate = match sample_rate {
            8000 => SampleRate::Rate8kHz,
            16000 => SampleRate::Rate16kHz,
            32000 => SampleRate::Rate32kHz,
            48000 => SampleRate::Rate48kHz,
            _ => return Err(anyhow::anyhow!(
                "Unsupported sample rate for VAD: {}. Use 8000, 16000, 32000, or 48000", 
                sample_rate
            )),
        };

        let mode = match aggressiveness {
            0 => Mode::Quality,
            1 => Mode::LowBitrate,
            2 => Mode::Aggressive,
            3 => Mode::VeryAggressive,
            _ => return Err(anyhow::anyhow!("VAD aggressiveness must be 0-3")),
        };

        let vad = Vad::new_with_rate_and_mode(vad_sample_rate, mode);

        Ok(Self {
            vad,
            sample_rate,
            frame_duration_ms: 30, // WebRTC VAD supports 10, 20, or 30ms frames
            silence_duration: Duration::from_millis(silence_duration_ms),
            last_speech_time: None,
            is_speaking: false,
        })
    }

    pub fn samples_per_frame(&self) -> usize {
        (self.sample_rate as u32 * self.frame_duration_ms / 1000) as usize
    }

    pub fn process_frame(&mut self, samples: &[i16]) -> Result<VadEvent> {
        if samples.len() != self.samples_per_frame() {
            return Err(anyhow::anyhow!(
                "Expected {} samples for {}ms frame, got {}",
                self.samples_per_frame(),
                self.frame_duration_ms,
                samples.len()
            ));
        }

        let has_speech = self.vad.is_voice_segment(samples)
            .context("VAD processing failed")?;

        let now = Instant::now();

        if has_speech {
            self.last_speech_time = Some(now);
            
            if !self.is_speaking {
                self.is_speaking = true;
                return Ok(VadEvent::SpeechStart);
            }
            
            Ok(VadEvent::Speaking)
        } else {
            // Check if silence duration has elapsed
            if self.is_speaking {
                if let Some(last_speech) = self.last_speech_time {
                    if now.duration_since(last_speech) >= self.silence_duration {
                        self.is_speaking = false;
                        return Ok(VadEvent::SpeechEnd);
                    }
                }
            }
            
            Ok(VadEvent::Silence)
        }
    }

    pub fn reset(&mut self) {
        self.is_speaking = false;
        self.last_speech_time = None;
    }

    pub fn is_speaking(&self) -> bool {
        self.is_speaking
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadEvent {
    SpeechStart,
    Speaking,
    Silence,
    SpeechEnd,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vad_creation() {
        let vad = VoiceActivityDetector::new(16000, 2, 1000);
        assert!(vad.is_ok());
        
        let vad = vad.unwrap();
        assert_eq!(vad.samples_per_frame(), 480); // 30ms at 16kHz
    }

    #[test]
    fn test_invalid_sample_rate() {
        let vad = VoiceActivityDetector::new(44100, 2, 1000);
        assert!(vad.is_err());
    }

    #[test]
    fn test_invalid_aggressiveness() {
        let vad = VoiceActivityDetector::new(16000, 5, 1000);
        assert!(vad.is_err());
    }
}
