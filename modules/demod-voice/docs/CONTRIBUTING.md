# Contributing to DeMoD Voice Clone

Thank you for your interest in contributing to DeMoD Voice Clone. This document provides guidelines and instructions for contributing.

## Development Setup

1. **Install Nix with flakes enabled:**

   ```bash
   # Install Nix
   sh <(curl -L https://nixos.org/nix/install) --daemon
   
   # Enable flakes
   mkdir -p ~/.config/nix
   echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
   ```

2. **Clone the repository:**

   ```bash
   git clone https://github.com/DeMoDLLC/voice-clone-flake.git
   cd voice-clone-flake
   ```

3. **Enter development environment:**

   ```bash
   nix develop
   ```

   This provides all dependencies including Python, PyTorch, Coqui TTS, Piper, and development tools.

## Development Workflow

### Code Style

We use:
- **Black** for Python formatting
- **Ruff** for linting
- **mypy** for type checking

Format your code before committing:

```bash
black bin/
ruff check bin/ --fix
mypy bin/
```

### Testing

Run tests with pytest:

```bash
# Unit tests only
pytest tests/ -v

# Include integration tests (requires models)
pytest tests/ -v -m integration

# Test specific modules
pytest tests/test_config.py tests/test_batch.py -v

# Run all tests with coverage
pytest tests/ --cov=demod_voice --cov-report=html
```

### Code Style

We use:
- **Black** for Python formatting
- **Ruff** for linting
- **mypy** for type checking

Format your code before committing:

```bash
black bin/ demod_voice/
ruff check bin/ demod_voice/ --fix
mypy bin/ demod_voice/
```

### Building

```bash
# Build the package
nix build .#demod-voice

# Test the built binary
./result/bin/demod-voice --help
```

### Running Checks

Before submitting a PR:

```bash
# Run all Nix flake checks
nix flake check

# This validates:
# - Flake syntax
# - Package builds successfully
# - No obvious runtime errors
```

## Contribution Guidelines

### Reporting Issues

When reporting issues, please include:

1. **Nix version:** `nix --version`
2. **System info:** `uname -a`
3. **Reproduction steps**
4. **Expected vs actual behavior**
5. **Relevant logs or error messages**

### Submitting Pull Requests

1. **Fork the repository**
2. **Create a feature branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes:**
   - Follow existing code style
   - Add tests for new functionality
   - Update documentation as needed

4. **Test thoroughly:**
   ```bash
   nix flake check
   pytest tests/
   ```

5. **Commit with clear messages:**
   ```bash
   git commit -m "Add: Brief description of change"
   ```

   Follow conventional commits:
   - `Add: New feature`
   - `Fix: Bug fix`
   - `Docs: Documentation update`
   - `Refactor: Code refactoring`
   - `Test: Test additions/changes`

6. **Push and create PR:**
   ```bash
   git push origin feature/your-feature-name
   ```

### Code Review Process

1. Maintainers will review your PR
2. Address any requested changes
3. Once approved, your PR will be merged
4. Delete your feature branch after merge

## Adding New Features

### New CLI Subcommands

1. Add function to `bin/demod-voice`
2. Register subparser in `main()`
3. Add tests in `tests/test_cli.py`
4. Update README with usage examples

Example:

```python
def run_new_feature(args):
    """Implementation of new feature"""
    # Your code here
    pass

# In main():
p_new = subparsers.add_parser("new-feature", help="Description")
p_new.add_argument("input", type=Path, help="Input file")
p_new.set_defaults(func=run_new_feature)
```

### New Python Dependencies

Add to `flake.nix` in the `pythonEnv` section:

```nix
pythonEnv = pkgs.python3.withPackages (ps: with ps; [
  # existing packages...
  your-new-package
]);
```

If the package isn't in nixpkgs, build from source:

```nix
your-package = pkgs.python3Packages.buildPythonPackage rec {
  pname = "your-package";
  version = "1.0.0";
  src = pkgs.fetchPypi {
    inherit pname version;
    sha256 = "...";
  };
};
```

### Documentation Updates

- Update README.md for user-facing changes
- Add inline comments for complex code
- Update docstrings for new functions
- Add examples to help text

## Release Process

Maintainers handle releases:

1. Update version in `flake.nix`
2. Update CHANGELOG.md
3. Create git tag: `git tag v1.x.x`
4. Push tag: `git push origin v1.x.x`
5. GitHub Actions builds and publishes Docker image
6. GitHub release created automatically

## Community

- **Discussions:** https://github.com/DeMoDLLC/voice-clone-flake/discussions
- **Issues:** https://github.com/DeMoDLLC/voice-clone-flake/issues
- **Email:** dev@demod.llc

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Questions?

Don't hesitate to ask questions in GitHub Discussions or open an issue for clarification on any development topics.
