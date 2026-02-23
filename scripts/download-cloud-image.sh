#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/images"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE="$IMAGE_DIR/ubuntu-24.04-cloudimg-amd64.img"

mkdir -p "$IMAGE_DIR"

if [ ! -f "$IMAGE_FILE" ]; then
    echo "Downloading Ubuntu 24.04 (Noble Numbat) cloud image..."
    echo "URL: $IMAGE_URL"
    curl -fSL --progress-bar -o "$IMAGE_FILE" "$IMAGE_URL"
    echo ""
    echo "Download complete."
else
    echo "Image already exists at $IMAGE_FILE"
fi

echo ""
echo "Image info:"
qemu-img info "$IMAGE_FILE" 2>/dev/null || echo "qemu-img not yet installed (will be available after host-setup.sh)"
