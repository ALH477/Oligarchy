# Contributing to Blipply Assistant

**Copyright © 2026 DeMoD LLC**

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- Rust 1.75+ (latest stable recommended)
- NixOS or Nix package manager
- Ollama running locally
- Basic familiarity with Rust, async programming, and GTK

### Development Environment

```bash
# Clone the repository
git clone https://github.com/demod-llc/blipply-assistant
cd blipply-assistant

# Enter Nix development shell (recommended)
nix develop

# Or install dependencies manually
# See README.md for manual setup

# Download required models
./scripts/download-models.sh

# Build and run
cargo build
cargo run -- setup
cargo run -- daemon
```

## Development Workflow

### Making Changes

1. **Fork the repository**
2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Follow the existing code style
   - Add tests for new functionality
   - Update documentation as needed

4. **Test your changes**
   ```bash
   cargo test
   cargo clippy -- -D warnings
   cargo fmt --check
   ```

5. **Commit your changes**
   ```bash
   git commit -m "feat: add new feature"
   ```
   
   We follow [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat:` New feature
   - `fix:` Bug fix
   - `docs:` Documentation only
   - `style:` Code style changes (formatting)
   - `refactor:` Code refactoring
   - `test:` Adding or updating tests
   - `chore:` Maintenance tasks

6. **Push and create a Pull Request**
   ```bash
   git push origin feature/your-feature-name
   ```

## Code Style

### Rust Style Guide

- Follow the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- Use `cargo fmt` for formatting
- Run `cargo clippy` and address all warnings
- Prefer explicit types over `auto` when clarity improves
- Use descriptive variable names

### Error Handling

- Use `anyhow::Result` for functions that can fail
- Use `thiserror` for custom error types
- Propagate errors with `?` operator
- Add context to errors: `context("Failed to load config")?`

### Async Code

- Use `tokio::spawn` for CPU-bound tasks
- Use `glib::spawn_future_local` for GTK interactions
- Avoid blocking the UI thread
- Use channels (`mpsc`) for cross-thread communication

### Comments

- Document public APIs with `///` doc comments
- Use `//` for implementation notes
- Explain *why*, not *what* (code should be self-explanatory)

### Testing

- Write unit tests for business logic
- Use `#[cfg(test)]` modules
- Mock external dependencies where possible
- Aim for >80% code coverage on new features

Example:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_hotkey() {
        let hotkey = parse_hotkey("Super+Shift+A").unwrap();
        assert!(hotkey.super_mod);
        assert!(hotkey.shift_mod);
    }

    #[tokio::test]
    async fn test_ollama_client() {
        // Async test
    }
}
```

## Project Structure

```
src/
├── main.rs          # CLI entry point
├── config.rs        # Configuration management
├── profiles.rs      # Profile system
├── ollama.rs        # Ollama API client
├── state.rs         # Application state
├── hotkeys.rs       # Hotkey system
├── first_run.rs     # Setup wizard
├── audio/           # Audio pipeline
│   ├── mod.rs       # Common utilities
│   ├── stt.rs       # Speech-to-text
│   ├── tts.rs       # Text-to-speech
│   └── vad.rs       # Voice activity detection
└── ui/              # User interface
    ├── mod.rs
    ├── window.rs    # Main window
    └── widgets.rs   # UI components
```

## Adding New Features

### Audio Pipeline Features

If adding audio processing features:

1. Add functionality to appropriate module (`stt.rs`, `tts.rs`, `vad.rs`)
2. Update `AudioEvent` enum if new event types needed
3. Handle events in `state.rs::handle_audio_event`
4. Add configuration options to `config.rs`
5. Update UI to reflect new capabilities

### UI Features

If adding UI features:

1. Create widgets in `ui/widgets.rs`
2. Add to window layout in `ui/window.rs`
3. Handle `UiCommand` events as needed
4. Follow GTK4 best practices
5. Test on both KDE Plasma 6 and Hyprland

### Profile System Features

If extending profiles:

1. Add fields to `ProfileConfig` in `config.rs`
2. Update `VoiceProfile` in `profiles.rs`
3. Add UI controls in profile selector
4. Update serialization/deserialization
5. Maintain backward compatibility

## Performance Guidelines

### Memory

- Avoid unnecessary clones (use `Arc` for shared data)
- Use `parking_lot` for locks when performance matters
- Profile with `cargo flamegraph` for hot paths

### Latency

- Keep hotkey response <50ms
- First token from LLM <200ms
- UI frame time <16ms (60fps)

### Binary Size

- Minimize dependencies
- Use feature flags for optional functionality
- Target <5 MiB stripped binary

## Documentation

### Code Documentation

- All public items must have doc comments
- Include examples in doc comments where helpful
- Document panics, safety requirements, and errors

Example:
```rust
/// Transcribes audio samples using Whisper.
///
/// # Arguments
///
/// * `samples` - Audio samples at 16kHz, mono
///
/// # Returns
///
/// Transcribed text or error if transcription fails
///
/// # Examples
///
/// ```
/// let text = transcribe(&whisper_ctx, &audio_samples)?;
/// ```
pub fn transcribe(ctx: &WhisperContext, samples: &[f32]) -> Result<String> {
    // ...
}
```

### User Documentation

- Update README.md for user-facing changes
- Add examples to config.example.toml
- Update troubleshooting section if needed

## Pull Request Process

1. **Ensure all tests pass**
   ```bash
   cargo test
   cargo clippy
   cargo fmt --check
   ```

2. **Update documentation**
   - README.md for user-facing changes
   - Doc comments for API changes
   - CHANGELOG.md entry

3. **Create PR with description**
   - What does this PR do?
   - Why is this change needed?
   - How has it been tested?
   - Screenshots (for UI changes)

4. **Address review feedback**
   - Respond to comments
   - Make requested changes
   - Re-request review when ready

5. **Squash commits** (if requested)
   - Maintain clean git history
   - Descriptive commit messages

## Bug Reports

When filing a bug report, include:

1. **System information**
   - NixOS version
   - Desktop environment (KDE/Hyprland/other)
   - Blipply Assistant version

2. **Steps to reproduce**
   - Exact commands run
   - Configuration used
   - Expected vs actual behavior

3. **Logs**
   ```bash
   RUST_LOG=clippy_assistant=debug blipply-assistant daemon
   ```

4. **Screenshots/recordings** (for UI bugs)

## Feature Requests

When requesting a feature:

1. **Use case**: What problem does this solve?
2. **Proposed solution**: How would it work?
3. **Alternatives considered**: Other approaches?
4. **Willing to implement**: Would you like to contribute it?

## Code of Conduct

- Be respectful and constructive
- Welcome newcomers and help them learn
- Focus on the code, not the person
- Assume good intentions

## Questions?

- Open a GitHub Discussion for questions
- Check existing issues and PRs
- Join our Discord/Matrix (if available)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
