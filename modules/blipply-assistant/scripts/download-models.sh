#!/usr/bin/env bash
# Blipply Assistant - Model Downloader
# Copyright (c) 2026 DeMoD LLC
# Licensed under the MIT License

set -euo pipefail

echo "Blipply Assistant - Model Downloader"
echo "===================================="
echo ""

MODEL_DIR="${HOME}/.local/share/clippy-assistant/models"
mkdir -p "$MODEL_DIR/whisper" "$MODEL_DIR/piper"

# Whisper models
echo "📥 Downloading Whisper models..."
echo ""

WHISPER_MODELS=(
    "tiny.en:https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
    "base.en:https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    "small.en:https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
)

echo "Available Whisper models:"
echo "  1. tiny.en  (74 MB)  - Fastest, lowest quality"
echo "  2. base.en  (142 MB) - Recommended"
echo "  3. small.en (461 MB) - Higher quality"
echo ""
read -p "Select model to download (1-3) [default: 2]: " choice
choice=${choice:-2}

case $choice in
    1) model="tiny.en" ;;
    2) model="base.en" ;;
    3) model="small.en" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

for entry in "${WHISPER_MODELS[@]}"; do
    name="${entry%%:*}"
    url="${entry#*:}"
    
    if [ "$name" = "$model" ]; then
        output="$MODEL_DIR/whisper/${name}.bin"
        
        if [ -f "$output" ]; then
            echo "✓ ${name}.bin already exists"
        else
            echo "⬇ Downloading ${name}..."
            wget --progress=bar:force "$url" -O "$output"
            echo "✓ Downloaded ${name}.bin"
        fi
    fi
done

echo ""
echo "📥 Downloading Piper TTS voices..."
echo ""

PIPER_VOICES=(
    "en_US-lessac-medium:https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-lessac-medium.tar.gz"
    "en_US-amy-medium:https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-amy-medium.tar.gz"
    "en_GB-alan-medium:https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-gb-alan-medium.tar.gz"
)

echo "Available Piper voices:"
echo "  1. en_US-lessac-medium (31 MB) - American English, male"
echo "  2. en_US-amy-medium    (31 MB) - American English, female"
echo "  3. en_GB-alan-medium   (31 MB) - British English, male"
echo ""
read -p "Select voice to download (1-3) [default: 1]: " voice_choice
voice_choice=${voice_choice:-1}

case $voice_choice in
    1) voice="en_US-lessac-medium" ;;
    2) voice="en_US-amy-medium" ;;
    3) voice="en_GB-alan-medium" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

for entry in "${PIPER_VOICES[@]}"; do
    name="${entry%%:*}"
    url="${entry#*:}"
    
    if [ "$name" = "$voice" ]; then
        output="$MODEL_DIR/piper/${name}.onnx"
        
        if [ -f "$output" ]; then
            echo "✓ ${name} already exists"
        else
            echo "⬇ Downloading ${name}..."
            temp_file=$(mktemp)
            wget --progress=bar:force "$url" -O "$temp_file"
            tar xzf "$temp_file" -C "$MODEL_DIR/piper/"
            rm "$temp_file"
            echo "✓ Downloaded ${name}"
        fi
    fi
done

echo ""
echo "✅ Model download complete!"
echo ""
echo "Models installed to: $MODEL_DIR"
echo "  Whisper: $MODEL_DIR/whisper/"
echo "  Piper:   $MODEL_DIR/piper/"
echo ""
echo "You can now run: clippy-assistant setup"
