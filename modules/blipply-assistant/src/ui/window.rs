// Blipply Assistant - User Interface
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::Result;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, Layer, LayerShell};
use std::sync::Arc;
use tracing::{debug, error};

use crate::state::{AppState, UiCommand};
use crate::ollama::Message;
use super::widgets::{create_avatar, create_chat_view, create_input_box, create_profile_selector};

pub fn create_window(state: Arc<AppState>) -> Result<gtk::Window> {
    let window = gtk::Window::new();
    
    // Initialize layer shell
    window.init_layer_shell();
    window.set_layer(Layer::Overlay);
    
    // Anchor to top-right corner
    window.set_anchor(Edge::Top, true);
    window.set_anchor(Edge::Right, true);
    
    // Set margins
    window.set_margin(Edge::Top, 32);
    window.set_margin(Edge::Right, 16);
    
    // Enable keyboard input
    window.set_keyboard_mode(gtk4_layer_shell::KeyboardMode::OnDemand);
    
    // Set size
    window.set_default_size(400, 600);
    window.set_title(Some("Blipply Assistant"));
    
    // Create main layout
    let main_box = gtk::Box::new(gtk::Orientation::Vertical, 12);
    main_box.set_margin_start(16);
    main_box.set_margin_end(16);
    main_box.set_margin_top(16);
    main_box.set_margin_bottom(16);
    
    // Header with avatar and profile selector
    let header_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    
    // Load avatar
    let avatar = {
        let config = state.config.read();
        let profiles = state.profiles.read();
        let profile = profiles.active_profile().unwrap();
        create_avatar(&profile.avatar_path, profile.avatar_size_px as i32)
    };
    header_box.append(&avatar);
    
    // Profile selector
    let profile_selector = create_profile_selector(state.clone());
    header_box.append(&profile_selector);
    
    // Close button
    let close_button = gtk::Button::with_label("✕");
    close_button.add_css_class("circular");
    let window_clone = window.clone();
    close_button.connect_clicked(move |_| {
        window_clone.hide();
    });
    header_box.append(&close_button);
    
    main_box.append(&header_box);
    
    // Chat view
    let (chat_scroll, chat_buffer) = create_chat_view();
    main_box.append(&chat_scroll);
    
    // Input box
    let input_box = create_input_box(state.clone(), chat_buffer.clone());
    main_box.append(&input_box);
    
    // Status indicators
    let status_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let listening_indicator = gtk::Label::new(None);
    listening_indicator.set_visible(false);
    let speaking_indicator = gtk::Label::new(None);
    speaking_indicator.set_visible(false);
    status_box.append(&listening_indicator);
    status_box.append(&speaking_indicator);
    main_box.append(&status_box);
    
    window.set_child(Some(&main_box));
    
    // Handle UI commands
    let mut ui_rx = state.take_ui_receiver().expect("UI receiver already taken");
    let window_clone = window.clone();
    let buffer_clone = chat_buffer.clone();
    let listening_clone = listening_indicator.clone();
    let speaking_clone = speaking_indicator.clone();
    
    glib::spawn_future_local(async move {
        while let Some(cmd) = ui_rx.recv().await {
            match cmd {
                UiCommand::Show => {
                    debug!("Showing window");
                    window_clone.present();
                }
                UiCommand::Hide => {
                    debug!("Hiding window");
                    window_clone.hide();
                }
                UiCommand::Toggle => {
                    if window_clone.is_visible() {
                        window_clone.hide();
                    } else {
                        window_clone.present();
                    }
                }
                UiCommand::AppendMessage(msg) => {
                    append_message_to_buffer(&buffer_clone, &msg);
                }
                UiCommand::StreamChunk(chunk) => {
                    append_chunk_to_buffer(&buffer_clone, &chunk);
                }
                UiCommand::SetListening(listening) => {
                    if listening {
                        listening_clone.set_text("🎤 Listening...");
                        listening_clone.add_css_class("listening");
                    } else {
                        listening_clone.set_text("");
                        listening_clone.remove_css_class("listening");
                    }
                    listening_clone.set_visible(listening);
                }
                UiCommand::SetSpeaking(speaking) => {
                    if speaking {
                        speaking_clone.set_text("🔊 Speaking...");
                        speaking_clone.add_css_class("speaking");
                    } else {
                        speaking_clone.set_text("");
                        speaking_clone.remove_css_class("speaking");
                    }
                    speaking_clone.set_visible(speaking);
                }
                UiCommand::SwitchProfile(profile_name) => {
                    debug!("Switched to profile: {}", profile_name);
                    // Update avatar and other UI elements
                }
                UiCommand::UpdateAvatar(path) => {
                    debug!("Update avatar: {}", path);
                }
            }
        }
    });
    
    Ok(window)
}

fn append_message_to_buffer(buffer: &gtk::TextBuffer, message: &Message) {
    let mut end_iter = buffer.end_iter();
    
    // Add role label
    let role_text = match message.role.as_str() {
        "user" => "You: ",
        "assistant" => "Assistant: ",
        "system" => "System: ",
        _ => "Unknown: ",
    };
    
    buffer.insert(&mut end_iter, "\n");
    buffer.insert(&mut end_iter, role_text);
    
    // Create tag for role
    let tag_name = format!("{}-role", message.role);
    if buffer.tag_table().lookup(&tag_name).is_none() {
        let tag = gtk::TextTag::new(Some(&tag_name));
        tag.set_weight(700); // Bold
        
        // Color coding
        match message.role.as_str() {
            "user" => tag.set_foreground(Some("#4A90E2")),
            "assistant" => tag.set_foreground(Some("#50C878")),
            _ => {}
        }
        
        buffer.tag_table().add(&tag);
    }
    
    let start = end_iter;
    buffer.insert(&mut end_iter, role_text);
    buffer.apply_tag_by_name(&tag_name, &start, &end_iter);
    
    // Add message content
    buffer.insert(&mut end_iter, &message.content);
    buffer.insert(&mut end_iter, "\n");
    
    // Auto-scroll to bottom
    if let Some(mark) = buffer.get_insert() {
        if let Some(view) = buffer.get_property("view") {
            // This would need a reference to the TextView
            // For now, we'll just insert the text
        }
    }
}

fn append_chunk_to_buffer(buffer: &gtk::TextBuffer, chunk: &str) {
    let mut end_iter = buffer.end_iter();
    buffer.insert(&mut end_iter, chunk);
}

fn apply_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(
        r#"
        .listening {
            color: #4A90E2;
            font-weight: bold;
        }
        
        .speaking {
            color: #50C878;
            font-weight: bold;
        }
        
        .circular {
            border-radius: 50%;
            min-width: 32px;
            min-height: 32px;
        }
        "#
    );
    
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().expect("Could not connect to display"),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
