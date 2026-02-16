# Build Instructions

**Blipply Assistant** - Copyright © 2026 DeMoD LLC

This document provides detailed instructions for building Blipply Assistant from source.

## Prerequisites

### NixOS (Recommended)

On NixOS, all dependencies are managed by the Nix flake:

```bash
# No additional setup needed
nix develop
```

### Other Linux Distributions

#### Ubuntu/Debian

```bash
# System dependencies
sudo apt install -y \
  build-essential \
  pkg-config \
  libgtk-4-dev \
  libglib2.0-dev \
  libcairo2-dev \
  libpango1.0-dev \
  libgdk-pixbuf-2.0-dev \
  libasound2-dev \
  curl

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# gtk4-layer-shell (build from source if not in repos)
git clone https://github.com/wmww/gtk4-layer-shell.git
cd gtk4-layer-shell
meson build
ninja -C build
sudo ninja -C build install
```

#### Fedora

```bash
# System dependencies
sudo dnf install -y \
  gcc \
  pkg-config \
  gtk4-devel \
  glib2-devel \
  cairo-devel \
  pango-devel \
  gdk-pixbuf2-devel \
  alsa-lib-devel

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# gtk4-layer-shell
sudo dnf install gtk4-layer-shell-devel
```

#### Arch Linux

```bash
# System dependencies
sudo pacman -S \
  base-devel \
  gtk4 \
  gtk4-layer-shell \
  alsa-lib \
  rust

# Rust should be installed, but if not:
# curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## Building

### Quick Build

```bash
# Clone repository
git clone https://github.com/demod-llc/blipply-assistant
cd blipply-assistant

# Build release version
cargo build --release

# Binary will be at: target/release/blipply-assistant
```

### Development Build

```bash
# Build with debug symbols
cargo build

# Run directly
cargo run -- daemon

# Watch mode (rebuild on changes)
cargo install cargo-watch
cargo watch -x run
```

### Optimized Release Build

```bash
# Maximum optimization
RUSTFLAGS="-C target-cpu=native" cargo build --release

# Profile-guided optimization (advanced)
cargo pgo build
cargo pgo run -- daemon &
# Use the app for a while
cargo pgo optimize build
```

## Cross-Compilation

### For ARM (e.g., Raspberry Pi)

```bash
# Add target
rustup target add aarch64-unknown-linux-gnu

# Install cross-compilation toolchain (Ubuntu)
sudo apt install gcc-aarch64-linux-gnu

# Configure cargo
cat >> ~/.cargo/config.toml << EOF
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"
EOF

# Build
cargo build --release --target aarch64-unknown-linux-gnu
```

### Using Nix

```bash
# Build for different systems
nix build .#packages.aarch64-linux.default
nix build .#packages.x86_64-linux.default
```

## Installing

### System-wide

```bash
# After building
sudo install -Dm755 target/release/blipply-assistant /usr/local/bin/blipply-assistant

# Create systemd user service
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/blipply-assistant.service << EOF
[Unit]
Description=Blipply AI Assistant
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/blipply-assistant daemon
Restart=on-failure

[Install]
WantedBy=graphical-session.target
EOF

# Enable and start
systemctl --user enable --now blipply-assistant
```

### User-only

```bash
# Install to ~/.local/bin
install -Dm755 target/release/blipply-assistant ~/.local/bin/blipply-assistant

# Add to PATH if not already
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### NixOS

```nix
# In your configuration.nix or flake
{
  services.blipply-assistant.enable = true;
  users.users.youruser.extraGroups = [ "input" ];
}
```

## Downloading Models

### Automatic (Recommended)

```bash
# Run the download script
./scripts/download-models.sh
```

### Manual

#### Whisper Models

```bash
mkdir -p ~/.local/share/blipply-assistant/models/whisper
cd ~/.local/share/blipply-assistant/models/whisper

# Download base.en (142 MB, recommended)
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

# Or tiny.en (74 MB, faster but less accurate)
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin

# Or small.en (461 MB, better quality)
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
```

#### Piper Voice Models

```bash
mkdir -p ~/.local/share/blipply-assistant/models/piper
cd ~/.local/share/blipply-assistant/models/piper

# Download en_US-lessac-medium (American English, male)
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-lessac-medium.tar.gz
tar xzf voice-en-us-lessac-medium.tar.gz

# Download en_US-amy-medium (American English, female)
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-amy-medium.tar.gz
tar xzf voice-en-us-amy-medium.tar.gz
```

## Ollama Setup

### Installation

```bash
# Download and install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Or on NixOS
nix-env -iA nixpkgs.ollama
```

### Download Models

```bash
# Pull a model (recommended: llama3.2:3b for 8GB RAM)
ollama pull llama3.2:3b

# Or for more capable systems
ollama pull mistral:7b
ollama pull codellama:7b
```

### Start Ollama Service

```bash
# As user service
systemctl --user enable --now ollama

# Or manually
ollama serve &
```

## Verification

### Test Build

```bash
# Run all tests
cargo test

# Run with verbose output
cargo test -- --nocapture

# Run specific test
cargo test test_parse_hotkey
```

### Test Installation

```bash
# Check binary exists
which blipply-assistant

# Check version
blipply-assistant --version

# Run setup
blipply-assistant setup
```

### Test Ollama Connection

```bash
curl http://127.0.0.1:11434/api/tags
```

Should return JSON with available models.

### Test Audio

```bash
# Test microphone
arecord -d 5 -f cd test.wav
aplay test.wav

# List audio devices
arecord -l
aplay -l
```

## Troubleshooting

### Compilation Errors

#### "cannot find -lgtk-4"

```bash
# Install GTK4 development files
# Ubuntu/Debian: sudo apt install libgtk-4-dev
# Fedora: sudo dnf install gtk4-devel
# Arch: sudo pacman -S gtk4
```

#### "error: linker `cc` not found"

```bash
# Install build tools
# Ubuntu/Debian: sudo apt install build-essential
# Fedora: sudo dnf install gcc
# Arch: sudo pacman -S base-devel
```

#### ONNX Runtime linking errors

The ONNX Runtime is downloaded automatically by the `ort` crate. If you encounter issues:

```bash
# Clear cargo cache and rebuild
cargo clean
rm -rf ~/.cargo/registry/cache/ort*
cargo build --release
```

### Runtime Errors

#### "Failed to load Whisper model"

```bash
# Verify model exists
ls -lh ~/.local/share/blipply-assistant/models/whisper/

# Re-download if corrupted
./scripts/download-models.sh
```

#### "No input device available"

```bash
# Check PipeWire/PulseAudio
systemctl --user status pipewire pipewire-pulse

# Restart audio stack
systemctl --user restart pipewire pipewire-pulse wireplumber
```

#### "Could not connect to Ollama"

```bash
# Start Ollama
systemctl --user start ollama

# Or manually
ollama serve &

# Check it's running
curl http://127.0.0.1:11434/api/tags
```

## Performance Tuning

### Compile-Time Optimizations

```bash
# Enable all CPU features
RUSTFLAGS="-C target-cpu=native" cargo build --release

# Enable LTO (slower build, smaller binary)
cargo build --release # Already enabled in Cargo.toml

# Minimize binary size
cargo build --release # Already optimized in Cargo.toml
strip target/release/blipply-assistant
```

### Runtime Optimizations

```toml
# In ~/.config/blipply-assistant/config.toml

[audio]
# Use tiny model for faster transcription (less accurate)
stt_model = "tiny.en"

# Reduce buffer size for lower latency (higher CPU usage)
[pipewire]
buffer_size = 240  # 15ms at 16kHz
```

## Packaging

### Create .deb Package (Debian/Ubuntu)

```bash
cargo install cargo-deb
cargo deb

# Package will be in: target/debian/blipply-assistant_*.deb
sudo dpkg -i target/debian/blipply-assistant_*.deb
```

### Create .rpm Package (Fedora)

```bash
cargo install cargo-generate-rpm
cargo build --release
cargo generate-rpm

# Package will be in: target/generate-rpm/blipply-assistant-*.rpm
sudo rpm -i target/generate-rpm/blipply-assistant-*.rpm
```

### Create AppImage

```bash
# Install linuxdeploy
wget https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
chmod +x linuxdeploy-x86_64.AppImage

# Create AppDir
./linuxdeploy-x86_64.AppImage \
  --executable target/release/blipply-assistant \
  --appdir AppDir \
  --output appimage
```

## Development Tips

### Fast Incremental Builds

```bash
# Use sccache for faster rebuilds
cargo install sccache
export RUSTC_WRAPPER=sccache

# Use mold linker (much faster)
# Install: cargo install mold
# Then add to ~/.cargo/config.toml:
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

### Debugging

```bash
# Run with debugger
rust-gdb target/debug/blipply-assistant
# or
rust-lldb target/debug/blipply-assistant

# Enable backtrace
RUST_BACKTRACE=1 cargo run -- daemon
```

### Profiling

```bash
# CPU profiling
cargo install flamegraph
sudo cargo flamegraph -- daemon

# Memory profiling
cargo install heaptrack
heaptrack target/release/blipply-assistant daemon
```

## Clean Build

```bash
# Remove all build artifacts
cargo clean

# Remove downloaded models
rm -rf ~/.local/share/blipply-assistant/models

# Remove configuration
rm -rf ~/.config/blipply-assistant

# Full reset
cargo clean
rm -rf ~/.local/share/blipply-assistant
rm -rf ~/.config/blipply-assistant
```

## Next Steps

After a successful build:

1. Run `./scripts/download-models.sh` to download AI models
2. Run `blipply-assistant setup` to configure the assistant
3. Run `blipply-assistant daemon` to start
4. Press your configured hotkey to activate

See [README.md](README.md) for usage instructions.
