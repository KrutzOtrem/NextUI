#!/bin/bash
set -e

# Setup paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR="$SCRIPT_DIR/build_work"
INSTALL_DIR="$SCRIPT_DIR/libs"
mkdir -p "$WORK_DIR"
mkdir -p "$INSTALL_DIR"

export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$INSTALL_DIR/bin:$PATH"

# Versions
MUPDF_VER="1.23.11"
FREETYPE_VER="2.13.0"

# Parallel build
JOBS=$(nproc)

echo "Building dependencies in $WORK_DIR"
echo "Installing to $INSTALL_DIR"

# 1. Freetype (Restored to ensure SDL_ttf has what it needs)
cd "$WORK_DIR"
if [ ! -d "freetype-$FREETYPE_VER" ]; then
    echo "Downloading Freetype..."
    wget -c https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.gz
    tar -xf freetype-$FREETYPE_VER.tar.gz
fi
cd "freetype-$FREETYPE_VER"
if [ ! -f Makefile ]; then
     # Force out-of-tree build to avoid cross-compile detection issues mentioned in memory
     mkdir -p build
     cd build
     ../configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --enable-static --disable-shared --without-brotli --without-harfbuzz --without-png --without-zlib
     make -j$JOBS
     make install
fi

# 2. MuPDF
cd "$WORK_DIR"
if [ ! -d "mupdf-$MUPDF_VER-source" ]; then
    echo "Downloading MuPDF..."
    # Using a reliable mirror or upstream
    wget -c https://mupdf.com/downloads/archive/mupdf-$MUPDF_VER-source.tar.gz
    tar -xf mupdf-$MUPDF_VER-source.tar.gz
fi
cd "mupdf-$MUPDF_VER-source"

# Clean previous build to be safe
make clean

echo "Building MuPDF (Static)..."

# MuPDF static build
make -j$JOBS \
    CC="$CC" \
    CXX="$CXX" \
    AR="$AR" \
    HAVE_X11=no \
    HAVE_GLUT=no \
    HAVE_CURL=no \
    HAVE_LIBCRYPTO=no \
    USE_SYSTEM_LIBS=no \
    prefix="$INSTALL_DIR" \
    install

echo "Creating Shared Object (libmupdf_wrapper.so)..."
# We combine the static libs into a single shared lib to keep minarch.elf small
# -Wl,--whole-archive ensures we keep all symbols from the static libs
# -lm is needed for math functions
# -fPIC should theoretically have been used during static compile, but often works on ARM without it or if MuPDF sets it.
# Note: If MuPDF wasn't built with -fPIC, this link might fail. MuPDF usually enables it.

$CC -shared -o "$INSTALL_DIR/lib/libmupdf_wrapper.so" \
    -Wl,--whole-archive "$INSTALL_DIR/lib/libmupdf.a" "$INSTALL_DIR/lib/libmupdf-third.a" -Wl,--no-whole-archive \
    -lm

echo "Done! Libraries installed to $INSTALL_DIR"
