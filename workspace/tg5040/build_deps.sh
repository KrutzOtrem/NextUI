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

# 1. Freetype
cd "$WORK_DIR"
if [ ! -d "freetype-$FREETYPE_VER" ]; then
    echo "Downloading Freetype..."
    wget -c https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.gz
    tar -xf freetype-$FREETYPE_VER.tar.gz
fi
cd "freetype-$FREETYPE_VER"
if [ ! -f Makefile ]; then
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
    wget -c https://mupdf.com/downloads/archive/mupdf-$MUPDF_VER-source.tar.gz
    tar -xf mupdf-$MUPDF_VER-source.tar.gz
fi
cd "mupdf-$MUPDF_VER-source"
make clean

echo "Building MuPDF (Static)..."
make -j$JOBS CC="$CC" CXX="$CXX" AR="$AR" HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no HAVE_LIBCRYPTO=no USE_SYSTEM_LIBS=no prefix="$INSTALL_DIR" install

echo "Creating Shared Object Plugin (libmanual_plugin.so)..."

# We compile the manual_plugin.c source and link it with MuPDF/Freetype into a shared object.
# We need SDL2 headers. Assuming they are in toolchain path or we need pkg-config.
# Toolchain environment usually has SDL2-config or pkg-config.
# Using $(sdl2-config --cflags) logic, but here we are in bash.
# Assuming standard include path /usr/include/SDL2 or similar in sysroot.
# Let's try explicit -I flags if needed, or rely on toolchain.
# The toolchain usually has SDL2 in the sysroot.

$CC -shared -fPIC -o "$INSTALL_DIR/lib/libmanual_plugin.so" \
    "$SCRIPT_DIR/manual_plugin.c" \
    -I"$INSTALL_DIR/include" \
    -I"$SCRIPT_DIR/../all/common" \
    -Wl,--whole-archive "$INSTALL_DIR/lib/libmupdf.a" "$INSTALL_DIR/lib/libmupdf-third.a" -Wl,--no-whole-archive \
    -lm

echo "Done! Plugin created at $INSTALL_DIR/lib/libmanual_plugin.so"
