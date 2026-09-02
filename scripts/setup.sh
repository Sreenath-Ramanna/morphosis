#!/usr/bin/env bash
# scripts/setup.sh — one-shot setup for Morphosis on Fedora / Debian / Ubuntu
set -euo pipefail

DISTRO=$(. /etc/os-release && echo "$ID")

echo "==> Installing system dependencies..."
if [[ "$DISTRO" == "fedora" ]]; then
    # Note: Fedora spells it "LibRaw-devel", capitalised — "libraw-devel" does
    # not exist, and "libraw1394-devel" is FireWire, not the RAW decoder.
    # "pkg-config" is likewise only a virtual provide; the package is
    # pkgconf-pkg-config.
    sudo dnf install -y \
        LibRaw-devel \
        cmake \
        ninja-build \
        gtk3-devel \
        clang \
        pkgconf-pkg-config \
        python3-pillow
elif [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    sudo apt-get update && sudo apt-get install -y \
        libraw-dev \
        cmake \
        ninja-build \
        libgtk-3-dev \
        clang \
        pkg-config \
        python3-pil
else
    echo "Unsupported distro: $DISTRO — install the LibRaw headers, cmake," \
         "ninja and the gtk3 dev packages manually."
fi

echo "==> Getting Flutter packages..."
flutter pub get

if [[ ! -f "../raw_images_api/CMakeLists.txt" ]]; then
    echo
    echo "!! raw_images_api was not found beside this checkout."
    echo "   Clone it there, or build with:"
    echo "     RAW_IMAGES_API_DIR=/path/to/raw_images_api flutter build linux"
fi

echo "==> Done. Run:  flutter run -d linux"
