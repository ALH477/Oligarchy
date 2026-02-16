// Blipply Assistant - User Interface
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

mod window;
mod widgets;

pub use window::create_window;
pub use widgets::*;

use anyhow::Result;
use std::sync::Arc;

use crate::state::AppState;
