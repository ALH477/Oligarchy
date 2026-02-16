// Blipply Assistant - User Interface
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use gtk::prelude::*;
use std::sync::Arc;
use tracing::error;

use crate::state::AppState;

pub fn create_avatar(path: &str, size: i32) -> gtk::Widget {
    // Try to load the image
    let image = if path.ends_with(".gif") {
        // For GIF, use GtkImage which supports animation
        let image = gtk::Image::from_file(path);
        image.set_pixel_size(size);
        image.upcast::<gtk::Widget>()
    } else if path.ends_with(".svg") {
        // For SVG, use GtkPicture
        let picture = gtk::Picture::for_filename(path);
        picture.set_can_shrink(true);
        picture.set_content_fit(gtk::ContentFit::ScaleDown);
        picture.upcast::<gtk::Widget>()
    } else {
        // For other formats (PNG, JPEG)
        let image = gtk::Image::from_file(path);
        image.set_pixel_size(size);
        image.upcast::<gtk::Widget>()
    };
    
    image
}

pub fn create_chat_view() -> (gtk::ScrolledWindow, gtk::TextBuffer) {
    let text_view = gtk::TextView::new();
    text_view.set_editable(false);
    text_view.set_cursor_visible(false);
    text_view.set_wrap_mode(gtk::WrapMode::Word);
    text_view.set_margin_start(8);
    text_view.set_margin_end(8);
    text_view.set_margin_top(8);
    text_view.set_margin_bottom(8);
    
    let buffer = text_view.buffer();
    
    let scrolled = gtk::ScrolledWindow::new();
    scrolled.set_child(Some(&text_view));
    scrolled.set_vexpand(true);
    scrolled.set_min_content_height(300);
    
    (scrolled, buffer)
}

pub fn create_input_box(state: Arc<AppState>, buffer: gtk::TextBuffer) -> gtk::Box {
    let input_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some("Type a message..."));
    entry.set_hexpand(true);
    
    let send_button = gtk::Button::with_label("Send");
    
    // Handle send action
    let entry_clone = entry.clone();
    let state_clone = state.clone();
    let buffer_clone = buffer.clone();
    
    let send_action = move || {
        let text = entry_clone.text();
        if !text.is_empty() {
            // Clear input
            entry_clone.set_text("");
            
            // Add to chat
            let message = crate::ollama::Message::user(text.as_str());
            append_message(&buffer_clone, &message);
            
            // Process message
            let state = state_clone.clone();
            let text = text.to_string();
            glib::spawn_future_local(async move {
                // In a real implementation, this would be handled by the audio pipeline
                // For text-only mode, we'd need to trigger Ollama directly
                // For now, we'll just add the message to the buffer
            });
        }
    };
    
    let send_action_clone = send_action.clone();
    send_button.connect_clicked(move |_| {
        send_action_clone();
    });
    
    entry.connect_activate(move |_| {
        send_action();
    });
    
    input_box.append(&entry);
    input_box.append(&send_button);
    
    input_box
}

pub fn create_profile_selector(state: Arc<AppState>) -> gtk::ComboBoxText {
    let combo = gtk::ComboBoxText::new();
    
    // Populate with profiles
    {
        let profiles = state.profiles.read();
        for (id, profile) in &profiles.profiles {
            combo.append(Some(id), &profile.name);
        }
        combo.set_active_id(Some(&profiles.active));
    }
    
    // Add "Create New..." option
    combo.append(Some("__new__"), "➕ Create New");
    
    // Handle selection
    combo.connect_changed(move |combo| {
        if let Some(id) = combo.active_id() {
            let id_str = id.as_str();
            
            if id_str == "__new__" {
                // Show profile creation dialog
                show_create_profile_dialog(state.clone());
                
                // Reset to current active profile
                let profiles = state.profiles.read();
                combo.set_active_id(Some(&profiles.active));
            } else {
                // Switch profile
                if let Err(e) = state.switch_profile(id_str) {
                    error!("Failed to switch profile: {}", e);
                }
            }
        }
    });
    
    combo
}

fn show_create_profile_dialog(state: Arc<AppState>) {
    let dialog = gtk::Dialog::with_buttons(
        Some("Create New Profile"),
        None::<&gtk::Window>,
        gtk::DialogFlags::MODAL,
        &[
            ("Cancel", gtk::ResponseType::Cancel),
            ("Create", gtk::ResponseType::Accept),
        ],
    );
    
    let content = dialog.content_area();
    let grid = gtk::Grid::new();
    grid.set_row_spacing(8);
    grid.set_column_spacing(8);
    grid.set_margin_start(16);
    grid.set_margin_end(16);
    grid.set_margin_top(16);
    grid.set_margin_bottom(16);
    
    // Profile name
    let name_label = gtk::Label::new(Some("Profile Name:"));
    name_label.set_halign(gtk::Align::Start);
    grid.attach(&name_label, 0, 0, 1, 1);
    
    let name_entry = gtk::Entry::new();
    name_entry.set_placeholder_text(Some("My Profile"));
    grid.attach(&name_entry, 1, 0, 1, 1);
    
    // Base profile
    let base_label = gtk::Label::new(Some("Base Template:"));
    base_label.set_halign(gtk::Align::Start);
    grid.attach(&base_label, 0, 1, 1, 1);
    
    let base_combo = gtk::ComboBoxText::new();
    base_combo.append(Some("default"), "Default");
    base_combo.append(Some("none"), "From Scratch");
    base_combo.set_active(Some(0));
    grid.attach(&base_combo, 1, 1, 1, 1);
    
    content.append(&grid);
    
    let state_clone = state.clone();
    dialog.connect_response(move |dialog, response| {
        if response == gtk::ResponseType::Accept {
            let name = name_entry.text().to_string();
            let base = base_combo.active_id()
                .and_then(|id| if id == "none" { None } else { Some(id.to_string()) });
            
            // Create profile via state
            // In a real implementation, this would update the ProfileManager
            
            dialog.close();
        } else {
            dialog.close();
        }
    });
    
    dialog.present();
}

fn append_message(buffer: &gtk::TextBuffer, message: &crate::ollama::Message) {
    let mut end_iter = buffer.end_iter();
    
    buffer.insert(&mut end_iter, "\n");
    
    let role_text = match message.role.as_str() {
        "user" => "You: ",
        "assistant" => "Assistant: ",
        _ => "",
    };
    
    buffer.insert(&mut end_iter, role_text);
    buffer.insert(&mut end_iter, &message.content);
    buffer.insert(&mut end_iter, "\n");
}
