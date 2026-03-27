#!/bin/bash
set -e

echo "=== TinyOS Build System ==="

# Check for nasm
if ! command -v nasm &> /dev/null; then
    echo "Error: nasm not found. Install with: brew install nasm"
    exit 1
fi

# Check for xorriso or mkisofs/genisoimage
ISO_TOOL=""
if command -v xorriso &> /dev/null; then
    ISO_TOOL="xorriso"
elif command -v mkisofs &> /dev/null; then
    ISO_TOOL="mkisofs"
elif command -v genisoimage &> /dev/null; then
    ISO_TOOL="genisoimage"
else
    echo "Error: No ISO tool found. Install with: brew install xorriso"
    exit 1
fi

echo "[1/3] Assembling boot sector..."
nasm -f bin boot.asm -o boot.bin

echo "[2/3] Boot sector size: $(wc -c < boot.bin) bytes"

echo "[3/3] Creating bootable ISO with ${ISO_TOOL}..."
mkdir -p iso_root
cp boot.bin iso_root/

if [ "$ISO_TOOL" = "xorriso" ]; then
    xorriso -as mkisofs \
        -b boot.bin \
        -no-emul-boot \
        -boot-load-size 16 \
        -o tinyos.iso \
        -input-charset utf-8 \
        -V "TINYOS" \
        iso_root
else
    $ISO_TOOL \
        -b boot.bin \
        -no-emul-boot \
        -boot-load-size 16 \
        -o tinyos.iso \
        -input-charset utf-8 \
        -V "TINYOS" \
        iso_root
fi

echo ""
echo "Build complete!"
echo "  Output: tinyos.iso ($(du -h tinyos.iso | cut -f1))"
echo ""
echo "To test with QEMU:  qemu-system-x86_64 -cdrom tinyos.iso"
echo "To burn to USB:     dd if=tinyos.iso of=/dev/sdX bs=4M status=progress"

# Cleanup
rm -f boot.bin
rm -rf iso_root
