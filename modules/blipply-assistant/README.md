# Blipply Assistant

**Copyright © 2026 DeMoD LLC - All Rights Reserved**  
Licensed under the MIT License

A modern, AI-powered desktop assistant with voice interaction for NixOS. Built with Rust, GTK4, and Ollama.

## Features

- 🎤 **Voice Interaction**: Speech-to-text using Whisper, Text-to-speech using Piper
- 🪟 **Native Wayland Support**: Layer-shell integration for KDE Plasma 6 and Hyprland
- 🤖 **Multiple AI Models**: Supports any Ollama-compatible model
- 👤 **Multiple Profiles**: Create different assistants with unique personalities and voices
- ⌨️ **Global Hotkeys**: Quick access via keyboard shortcuts
- 🎨 **Customizable Avatars**: GIF, SVG, and PNG support
- 🔧 **Pure Rust**: Fast, safe, and efficient

## Architecture

```
┌─────────────────────────────────────────────┐
│         Blipply Assistant (Rust)             │
├─────────────────────────────────────────────┤
│  UI Layer (GTK4 + Layer Shell)              │
│  ├── Profile Selector                       │
│  ├── Chat View                              │
│  ├── Avatar Display                         │
│  └── Status Indicators                      │
├─────────────────────────────────────────────┤
│  Audio Pipeline                             │
│  ├── STT (Whisper) ─────────┐               │
│  ├── TTS (Piper/ONNX) ──────┤               │
│  └── VAD (WebRTC) ──────────┤               │
│                             │               │
│  ┌─────────────────────────┘               │
│  │ PipeWire/ALSA                            │
│  └──────────────────────────────────────────┤
│  Ollama Client (Streaming)                  │
│  └─── HTTP/REST API                         │
├─────────────────────────────────────────────┤
│  Hotkey System                              │
│  ├── xdg-desktop-portal (preferred)         │
│  └── evdev (fallback)                       │
└─────────────────────────────────────────────┘
```

## Installation

### NixOS (Recommended)

Add to your `flake.nix`:

```nix
{
  inputs.blipply-assistant.url = "github:demod-llc/blipply-assistant";

  outputs = { self, nixpkgs, blipply-assistant }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        blipply-assistant.nixosModules.default
        {
          services.blipply-assistant.enable = true;
          
          # Add your user to the input group
          users.users.youruser.extraGroups = [ "input" ];
        }
      ];
    };
  };
}
```

### Manual Build

```bash
# Clone repository
git clone https://github.com/demod-llc/blipply-assistant
cd blipply-assistant

# Enter development shell
nix develop

# Build
cargo build --release

# Install
sudo cp target/release/blipply-assistant /usr/local/bin/
```

## Quick Start

### 1. Install Ollama

```bash
# NixOS
nix-shell -p ollama
systemctl --user start ollama

# Or use the system service
sudo systemctl start ollama
```

### 2. Download a Model

```bash
ollama pull llama3.2:3b
```

### 3. Run Setup

```bash
blipply-assistant setup
```

This will guide you through:
- Selecting an AI model
- Choosing a personality
- Configuring hotkeys
- Setting up voice interaction
- Selecting an avatar

### 4. Start the Assistant

```bash
# As a daemon
blipply-assistant daemon

# Or enable the systemd service (NixOS)
systemctl --user enable --now blipply-assistant
```

### 5. Use It!

Press your configured hotkey (default: `Super+Shift+A`) to show/hide the assistant.

## Configuration

Configuration is stored in `~/.config/blipply-assistant/config.toml`:

```toml
[general]
ollama_url = "http://127.0.0.1:11434"
hotkey = "Super+Shift+A"
first_run_complete = true
active_profile = "default"

[audio]
stt_model = "base.en"
vad_enabled = true
vad_aggressiveness = 2
sample_rate = 16000
push_to_talk = false
silence_duration_ms = 1000

[pipewire]
input_device = "auto"
output_device = "auto"
buffer_size = 480

[profiles.default]
name = "Blipply Classic"
model = "llama3.2:3b"
personality = "helpful"
avatar_path = "/usr/share/blipply/clippy.gif"
avatar_size_px = 96
voice_model = "en_US-lessac-medium"
tts_speed = 1.0
tts_enabled = true
```

## Voice Models

### Using Custom Voice Models

If you've trained your own voice model using Piper:

1. Place your ONNX model and config in:
   ```
   ~/.local/share/blipply-assistant/models/piper/my_voice.onnx
   ~/.local/share/blipply-assistant/models/piper/my_voice.json
   ```

2. Update your profile:
   ```toml
   [profiles.my_custom]
   voice_model = "my_voice"
   ```

### Pre-trained Voices

Download from [Piper Samples](https://rhasspy.github.io/piper-samples/):

```bash
cd ~/.local/share/blipply-assistant/models/piper/
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-amy-medium.tar.gz
tar xzf voice-en-us-amy-medium.tar.gz
```

## Profile Management

### Create a New Profile

```bash
blipply-assistant create-profile "Technical Expert" --base default
```

Or via the UI: Click the profile dropdown → "➕ Create New"

### List Profiles

```bash
blipply-assistant profiles
```

### Switch Profiles

Use the profile dropdown in the UI or edit `config.toml`.

## Hotkey Configuration

### Supported Modifiers

- `Super` / `Meta` / `Win`
- `Shift`
- `Ctrl` / `Control`
- `Alt`

### Format

`Modifier+Modifier+Key`

Examples:
- `Super+Shift+A` (default)
- `Ctrl+Alt+C`
- `Super+Space`

### Desktop-Specific Setup

#### KDE Plasma 6

The assistant automatically uses `xdg-desktop-portal` for global shortcuts. No additional setup needed.

#### Hyprland

Add to `~/.config/hypr/hyprland.conf`:

```
bind = SUPER SHIFT, A, exec, blipply-assistant --toggle
```

#### Other Compositors

The assistant will fall back to `evdev`. Ensure your user is in the `input` group:

```bash
sudo usermod -a -G input $USER
```

Then log out and back in.

## Troubleshooting

### No Audio Input

```bash
# Check PipeWire status
systemctl --user status pipewire pipewire-pulse wireplumber

# List devices
pactl list sources short

# Test microphone
arecord -d 5 test.wav
aplay test.wav
```

### Ollama Not Responding

```bash
# Check Ollama status
systemctl --user status ollama

# Test manually
curl http://127.0.0.1:11434/api/tags
```

### Hotkey Not Working

1. **KDE**: Check `xdg-desktop-portal-kde` is installed
2. **Hyprland**: Use compositor bindings (see above)
3. **Other**: Ensure user is in `input` group

### Models Not Downloading

```bash
# Manually download Whisper
cd ~/.local/share/blipply-assistant/models/whisper/
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

# Manually download Piper voice
cd ~/.local/share/blipply-assistant/models/piper/
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-lessac-medium.tar.gz
tar xzf voice-en-us-lessac-medium.tar.gz
```

## Development

### Prerequisites

```bash
# Enter development environment
nix develop

# Or install manually
cargo install cargo-watch cargo-edit
```

### Build

```bash
cargo build
```

### Run Tests

```bash
cargo test
```

### Watch Mode

```bash
cargo watch -x run
```

### Code Structure

```
src/
├── main.rs          # Entry point, CLI
├── config.rs        # Configuration management
├── profiles.rs      # Profile system
├── ollama.rs        # Ollama API client
├── state.rs         # Application state
├── hotkeys.rs       # Global hotkey handling
├── first_run.rs     # Setup wizard
├── audio/
│   ├── mod.rs       # Audio utilities
│   ├── stt.rs       # Speech-to-text (Whisper)
│   ├── tts.rs       # Text-to-speech (Piper)
│   └── vad.rs       # Voice activity detection
└── ui/
    ├── mod.rs       # UI module exports
    ├── window.rs    # Main window (layer-shell)
    └── widgets.rs   # UI components
```

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Binary size | <5 MiB | Stripped release build |
| Memory (idle) | <50 MiB | Including GTK overhead |
| Hotkey latency | <50ms | Below perception threshold |
| First token | <200ms | Local LLM warmup |
| UI frame time | <16ms | 60fps target |

## Roadmap

- [x] Core voice interaction
- [x] Profile system
- [x] GTK4 + layer-shell UI
- [ ] Context awareness (active window, clipboard)
- [ ] Memory/conversation persistence
- [ ] Plugin system
- [ ] Mobile companion app (SSH tunnel)
- [ ] Multi-language support
- [ ] System automation hooks

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure `cargo test` passes
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details

## Acknowledgments

- [Ollama](https://ollama.ai/) - Local LLM runtime
- [Whisper](https://github.com/openai/whisper) - Speech recognition
- [Piper](https://github.com/rhasspy/piper) - Text-to-speech
- [GTK4](https://www.gtk.org/) - UI toolkit
- [gtk4-layer-shell](https://github.com/wmww/gtk4-layer-shell) - Wayland layer-shell
