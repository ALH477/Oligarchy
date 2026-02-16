# Blipply Assistant - Technical Architecture

**Copyright © 2026 DeMoD LLC**  
Licensed under the MIT License

## Overview

Blipply Assistant is a production-ready, Rust-based AI desktop assistant with full voice interaction capabilities. This document describes the technical architecture and design decisions.

## Technology Stack

### Core Language & Runtime
- **Rust 1.75+**: Memory safety, zero-cost abstractions, fearless concurrency
- **Tokio**: Async runtime for I/O-bound operations
- **GTK4**: Modern UI toolkit with Wayland-native support

### AI & Audio
- **Ollama**: Local LLM inference (HTTP/REST API)
- **Whisper**: Speech-to-text via `whisper-rs` (C++ bindings)
- **Piper**: Neural TTS via ONNX Runtime
- **WebRTC VAD**: Voice activity detection

### System Integration
- **gtk4-layer-shell**: Wayland layer-shell protocol
- **evdev**: Low-level input device access
- **PipeWire/ALSA**: Audio I/O via cpal

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     User Interface Layer                     │
│  ┌────────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │   Window   │  │ Widgets  │  │ Profile  │  │  Avatar   │ │
│  │ (Layer-    │  │          │  │ Selector │  │  Display  │ │
│  │  shell)    │  │          │  │          │  │           │ │
│  └─────┬──────┘  └────┬─────┘  └────┬─────┘  └─────┬─────┘ │
└────────┼──────────────┼─────────────┼──────────────┼────────┘
         │              │             │              │
         │              └─────────────┴──────────────┘
         ▼                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Application State                         │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Arc<RwLock<Config>>                                 │   │
│  │  Arc<RwLock<ProfileManager>>                         │   │
│  │  Arc<OllamaClient>                                   │   │
│  │  Arc<RwLock<Option<SttPipeline>>>                    │   │
│  │  Arc<RwLock<Option<TtsPipeline>>>                    │   │
│  │  Arc<RwLock<VecDeque<Message>>> (chat history)       │   │
│  │  mpsc::UnboundedSender<UiCommand>                    │   │
│  └──────────────────────────────────────────────────────┘   │
└───────┬──────────────────┬───────────────────┬──────────────┘
        │                  │                   │
        ▼                  ▼                   ▼
┌───────────────┐  ┌──────────────┐  ┌────────────────┐
│  Audio Layer  │  │ Ollama Client│  │ Hotkey System  │
├───────────────┤  ├──────────────┤  ├────────────────┤
│ ┌───────────┐ │  │ HTTP Streaming│  │ xdg-portal    │
│ │    STT    │ │  │ JSON parsing │  │ (preferred)   │
│ │ (Whisper) │ │  │ Async chunks │  │               │
│ └─────┬─────┘ │  │              │  │ OR            │
│       │       │  │ Models:      │  │ evdev         │
│ ┌─────▼─────┐ │  │ - llama3.2   │  │ (fallback)    │
│ │    VAD    │ │  │ - mistral    │  │               │
│ │ (WebRTC)  │ │  │ - codellama  │  │ Hotkey parse: │
│ └─────┬─────┘ │  │ - custom     │  │ Super+Shift+A │
│       │       │  │              │  │               │
│ ┌─────▼─────┐ │  └──────────────┘  └────────────────┘
│ │    TTS    │ │
│ │  (Piper)  │ │
│ └─────┬─────┘ │
│       │       │
│ ┌─────▼─────┐ │
│ │ PipeWire  │ │
│ │  (cpal)   │ │
│ └───────────┘ │
└───────────────┘
```

## Threading Model

### Main Thread (GTK Event Loop)
- UI rendering and event handling
- **Must** run on main thread due to GTK requirements
- All UI updates via `glib::spawn_future_local`

### Tokio Thread Pool
- Async I/O operations (HTTP, file system)
- Ollama API communication
- Audio event processing
- Hotkey listening

### Blocking Thread Pool (`tokio::task::spawn_blocking`)
- Whisper inference (CPU-bound, blocking)
- ONNX Runtime inference (TTS)
- File I/O for large models

### Audio Callback Threads (cpal)
- Real-time audio capture/playback
- Minimal processing, forward to async queues
- Lock-free where possible

## Data Flow

### Voice Interaction Flow

```
User speaks
    │
    ▼
┌───────────────────┐
│ Audio Input       │ (cpal capture)
│ f32 samples       │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ VAD Processing    │ Convert to i16, check for speech
│ 30ms frames       │
└────────┬──────────┘
         │
    ┌────┴────┐
    │ Speech? │
    └────┬────┘
         │ Yes
         ▼
┌───────────────────┐
│ Audio Buffer      │ Accumulate samples until silence
│ Vec<f32>          │
└────────┬──────────┘
         │ Silence detected
         ▼
┌───────────────────┐
│ Whisper Inference │ spawn_blocking
│ CPU-bound         │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Text Output       │ "Hello, how are you?"
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Ollama API        │ Streaming HTTP POST
│ Chat Endpoint     │
└────────┬──────────┘
         │
         ▼ (chunks)
┌───────────────────┐
│ UI Update         │ mpsc → glib::spawn_future_local
│ Append chunks     │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ TTS Synthesis     │ ONNX Runtime
│ Piper VITS        │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Audio Output      │ cpal playback
│ f32 samples       │
└───────────────────┘
```

## Module Breakdown

### `main.rs`
- CLI argument parsing (clap)
- Command dispatch (daemon, toggle, setup, profiles)
- GTK initialization
- Main event loop

### `config.rs`
- TOML serialization/deserialization
- Default configuration generation
- Path resolution (XDG directories)
- Type-safe configuration structs

### `profiles.rs`
- Profile management (CRUD operations)
- System prompt generation per personality
- Profile switching with validation
- Configuration mapping

### `ollama.rs`
- HTTP client (reqwest)
- Streaming response handling
- JSON parsing of NDJSON chunks
- Error handling and retries

### `state.rs`
- Central application state (Arc-wrapped)
- Message history management (ring buffer)
- Audio pipeline coordination
- UI command distribution (mpsc channels)

### `audio/mod.rs`
- Common utilities (sample conversion, resampling)
- Audio event types
- Channel creation

### `audio/stt.rs`
- Whisper context management
- Audio capture (cpal)
- VAD integration
- Transcription in blocking threads

### `audio/tts.rs`
- ONNX Runtime session management
- Phoneme conversion (text → IDs)
- Audio playback (cpal)
- Sentence boundary detection for streaming

### `audio/vad.rs`
- WebRTC VAD wrapper
- Frame-based speech detection
- Silence detection with timeout
- State machine (idle → speaking → silence → idle)

### `hotkeys.rs`
- Multi-backend hotkey system
- xdg-desktop-portal integration (D-Bus)
- evdev fallback (raw input events)
- Hotkey parsing (string → key combo)

### `ui/window.rs`
- Layer-shell window creation
- GTK widget layout
- UI command handler (async message loop)
- Event bindings (buttons, keyboard)

### `ui/widgets.rs`
- Avatar rendering (GIF/SVG/PNG)
- Chat view (TextView + TextBuffer)
- Input box (Entry + Button)
- Profile selector (ComboBoxText)

### `first_run.rs`
- Interactive CLI setup wizard
- Ollama model selection
- Personality configuration
- Audio settings

## Performance Optimizations

### Memory Management
- **Arc<RwLock<T>>** for shared state (read-heavy)
- **mpsc channels** for cross-thread communication
- **VecDeque** for bounded history (auto-eviction)
- **Zero-copy** audio processing where possible

### Latency Reduction
- **Frame-based VAD** (30ms granularity)
- **Streaming LLM responses** (show tokens as they arrive)
- **Sentence-based TTS** (speak while generating)
- **Lock-free audio callbacks** (minimize jitter)

### Binary Size
- `opt-level = 'z'` (optimize for size)
- `lto = true` (link-time optimization)
- `strip = true` (remove debug symbols)
- Feature flags for optional components

## Security Considerations

### Input Validation
- Hotkey parsing with bounds checking
- Audio sample validation (length, range)
- Configuration schema validation (TOML parsing)
- Path sanitization (prevent directory traversal)

### Resource Limits
- Chat history bounded to 20 messages
- Audio buffer max size (prevent OOM)
- VAD frame size validation
- Model file size checks

### Privilege Separation
- No root required (except for evdev on some systems)
- User-level systemd service
- XDG directories for config/data
- No setuid binaries

## Error Handling Strategy

### Layers
1. **Low-level errors** (`thiserror` custom types)
2. **Business logic** (`anyhow::Result` with context)
3. **User-facing** (friendly error messages in UI)
4. **Logging** (`tracing` for diagnostics)

### Recovery
- **Restart audio streams** on failure
- **Reconnect to Ollama** with exponential backoff
- **Graceful degradation** (disable voice if models missing)
- **User notifications** (toast/dialog for critical errors)

## Testing Strategy

### Unit Tests
- Configuration parsing
- Hotkey parsing
- Audio sample conversion
- Profile management

### Integration Tests
- Ollama client (with mock server)
- Audio pipeline (with test fixtures)
- State transitions

### Manual Testing
- KDE Plasma 6 (Wayland)
- Hyprland (Wayland)
- Different Ollama models
- Various audio devices

## Build & Deployment

### Nix Flake
- Hermetic builds (reproducible)
- Dependency pinning
- Cross-platform support (aarch64, x86_64)
- Development shell with all tools

### NixOS Module
- Declarative configuration
- Systemd service integration
- Automatic model downloads
- User group management

## Future Enhancements

### Planned Features
- [ ] Context providers (active window, clipboard)
- [ ] Persistent conversation history (SQLite)
- [ ] Plugin system (Lua/WASM)
- [ ] Multi-user profiles (per-user config)
- [ ] Remote access (SSH tunnel, mobile app)

### Performance Improvements
- [ ] GPU acceleration for Whisper (CUDA/ROCm)
- [ ] Model quantization (smaller footprint)
- [ ] Streaming TTS (speak while synthesizing)
- [ ] Audio pre-processing (noise reduction)

### Platform Support
- [ ] X11 fallback (for older systems)
- [ ] macOS support (via NSPanel)
- [ ] Windows support (via Win32 API)

## Debugging

### Enable Verbose Logging
```bash
RUST_LOG=blipply_assistant=debug,whisper_rs=debug cargo run -- daemon
```

### Profile Performance
```bash
cargo install flamegraph
sudo cargo flamegraph -- daemon
```

### Inspect Audio
```bash
# Record raw audio
RUST_LOG=blipply_assistant=trace cargo run -- daemon 2>&1 | grep "Audio samples"

# Monitor PipeWire
pw-top
```

### Test Ollama API
```bash
curl -X POST http://127.0.0.1:11434/api/chat \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"test"}],"stream":false}'
```

## Conclusion

This architecture balances performance, maintainability, and user experience. The use of Rust provides memory safety and concurrency without garbage collection pauses. The modular design allows for easy extension and testing. The Nix-based build system ensures reproducibility across environments.
