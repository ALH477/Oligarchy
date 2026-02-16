// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::Result;
use parking_lot::RwLock;
use std::collections::VecDeque;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{debug, info};

use crate::audio::{SttPipeline, TtsPipeline, AudioEvent, create_audio_channel};
use crate::config::Config;
use crate::ollama::{OllamaClient, Message};
use crate::profiles::{ProfileManager, VoiceProfile};

const MAX_HISTORY_LENGTH: usize = 20;

pub struct AppState {
    config: Arc<RwLock<Config>>,
    profiles: Arc<RwLock<ProfileManager>>,
    ollama: Arc<OllamaClient>,
    stt: Arc<RwLock<Option<SttPipeline>>>,
    tts: Arc<RwLock<Option<TtsPipeline>>>,
    chat_history: Arc<RwLock<VecDeque<Message>>>,
    ui_command_tx: mpsc::UnboundedSender<UiCommand>,
    ui_command_rx: Arc<RwLock<Option<mpsc::UnboundedReceiver<UiCommand>>>>,
    visible: Arc<RwLock<bool>>,
}

#[derive(Debug, Clone)]
pub enum UiCommand {
    Show,
    Hide,
    Toggle,
    AppendMessage(Message),
    StreamChunk(String),
    SetListening(bool),
    SetSpeaking(bool),
    SwitchProfile(String),
    UpdateAvatar(String),
}

impl AppState {
    pub async fn new(config: Config) -> Result<Self> {
        let profiles = ProfileManager::from_config(&config);
        let ollama = OllamaClient::new(config.general.ollama_url.clone());

        let (ui_tx, ui_rx) = mpsc::unbounded_channel();

        Ok(Self {
            config: Arc::new(RwLock::new(config)),
            profiles: Arc::new(RwLock::new(profiles)),
            ollama: Arc::new(ollama),
            stt: Arc::new(RwLock::new(None)),
            tts: Arc::new(RwLock::new(None)),
            chat_history: Arc::new(RwLock::new(VecDeque::new())),
            ui_command_tx: ui_tx,
            ui_command_rx: Arc::new(RwLock::new(Some(ui_rx))),
            visible: Arc::new(RwLock::new(false)),
        })
    }

    pub fn take_ui_receiver(&self) -> Option<mpsc::UnboundedReceiver<UiCommand>> {
        self.ui_command_rx.write().take()
    }

    pub fn send_ui_command(&self, cmd: UiCommand) {
        self.ui_command_tx.send(cmd).ok();
    }

    pub async fn initialize_audio(&self) -> Result<()> {
        let config = self.config.read();
        let (audio_tx, mut audio_rx) = create_audio_channel();

        // Initialize STT
        let model_path = config.whisper_model_path()?;
        let mut stt = SttPipeline::new(
            model_path,
            config.audio.sample_rate,
            config.audio.vad_aggressiveness,
            config.audio.silence_duration_ms,
            audio_tx.clone(),
        )?;

        stt.start()?;
        *self.stt.write() = Some(stt);

        // Initialize TTS
        let profile = self.profiles.read().active_profile()?.clone();
        let voice_path = config.piper_voice_path(&profile.voice_model)?;
        let config_path = voice_path.with_extension("json");
        
        let tts = TtsPipeline::new(
            voice_path,
            config_path,
            profile.tts_speed,
            Some(audio_tx),
        )?;

        *self.tts.write() = Some(tts);

        // Spawn audio event handler
        let state = Arc::new(self.clone());
        tokio::spawn(async move {
            while let Some(event) = audio_rx.recv().await {
                if let Err(e) = state.handle_audio_event(event).await {
                    tracing::error!("Error handling audio event: {}", e);
                }
            }
        });

        info!("Audio pipelines initialized");
        Ok(())
    }

    async fn handle_audio_event(&self, event: AudioEvent) -> Result<()> {
        match event {
            AudioEvent::SpeechStart => {
                debug!("Speech started");
                self.send_ui_command(UiCommand::SetListening(true));
            }
            AudioEvent::SpeechEnd => {
                debug!("Speech ended");
                self.send_ui_command(UiCommand::SetListening(false));
            }
            AudioEvent::TranscriptFinal(text) => {
                info!("Transcript: {}", text);
                self.send_ui_command(UiCommand::AppendMessage(Message::user(&text)));
                
                // Process with Ollama
                self.process_user_message(&text).await?;
            }
            AudioEvent::TtsStarted => {
                self.send_ui_command(UiCommand::SetSpeaking(true));
            }
            AudioEvent::TtsFinished => {
                self.send_ui_command(UiCommand::SetSpeaking(false));
            }
            _ => {}
        }
        Ok(())
    }

    async fn process_user_message(&self, text: &str) -> Result<()> {
        // Add user message to history
        {
            let mut history = self.chat_history.write();
            history.push_back(Message::user(text));
            if history.len() > MAX_HISTORY_LENGTH {
                history.pop_front();
            }
        }

        // Get system prompt
        let system_prompt = {
            let profiles = self.profiles.read();
            let profile = profiles.active_profile()?;
            profiles.get_system_prompt(profile)
        };

        // Build messages for Ollama
        let mut messages = vec![Message::system(system_prompt)];
        {
            let history = self.chat_history.read();
            messages.extend(history.iter().cloned());
        }

        // Get model name
        let model = {
            let profiles = self.profiles.read();
            profiles.active_profile()?.model.clone()
        };

        // Stream response
        use futures::StreamExt;
        let mut stream = self.ollama.chat_stream(model, messages);
        let mut full_response = String::new();

        // Check if TTS is enabled
        let tts_enabled = {
            let profiles = self.profiles.read();
            profiles.active_profile()?.tts_enabled
        };

        while let Some(chunk_result) = stream.next().await {
            match chunk_result {
                Ok(chunk) => {
                    full_response.push_str(&chunk);
                    self.send_ui_command(UiCommand::StreamChunk(chunk));
                }
                Err(e) => {
                    tracing::error!("Streaming error: {}", e);
                    break;
                }
            }
        }

        // Add assistant response to history
        {
            let mut history = self.chat_history.write();
            history.push_back(Message::assistant(&full_response));
            if history.len() > MAX_HISTORY_LENGTH {
                history.pop_front();
            }
        }

        // Speak response if TTS enabled
        if tts_enabled && !full_response.is_empty() {
            if let Some(tts) = self.tts.read().as_ref() {
                tts.speak(&full_response).await?;
            }
        }

        Ok(())
    }

    pub fn toggle_visibility(&self) {
        let mut visible = self.visible.write();
        *visible = !*visible;
        
        if *visible {
            self.send_ui_command(UiCommand::Show);
        } else {
            self.send_ui_command(UiCommand::Hide);
        }
    }

    pub fn is_visible(&self) -> bool {
        *self.visible.read()
    }

    pub fn switch_profile(&self, profile_name: &str) -> Result<()> {
        let mut profiles = self.profiles.write();
        profiles.switch_profile(profile_name)?;
        
        self.send_ui_command(UiCommand::SwitchProfile(profile_name.to_string()));
        
        // Update TTS with new voice
        let profile = profiles.active_profile()?.clone();
        drop(profiles);

        let config = self.config.read();
        let voice_path = config.piper_voice_path(&profile.voice_model)?;
        let config_path = voice_path.with_extension("json");

        let (audio_tx, _) = create_audio_channel();
        let tts = TtsPipeline::new(
            voice_path,
            config_path,
            profile.tts_speed,
            Some(audio_tx),
        )?;

        *self.tts.write() = Some(tts);
        
        info!("Switched to profile: {}", profile_name);
        Ok(())
    }

    pub async fn run(&self) {
        // Main event loop - handles IPC, timers, etc.
        info!("Application state running");
    }
}

// Make AppState Clone-safe by only cloning Arc pointers
impl Clone for AppState {
    fn clone(&self) -> Self {
        Self {
            config: self.config.clone(),
            profiles: self.profiles.clone(),
            ollama: self.ollama.clone(),
            stt: self.stt.clone(),
            tts: self.tts.clone(),
            chat_history: self.chat_history.clone(),
            ui_command_tx: self.ui_command_tx.clone(),
            ui_command_rx: self.ui_command_rx.clone(),
            visible: self.visible.clone(),
        }
    }
}
