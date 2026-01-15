#!/bin/bash
set -e

# Setup paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR="$SCRIPT_DIR/build_work"
INSTALL_DIR="$SCRIPT_DIR/libs"
mkdir -p "$WORK_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin"

# Add install dir to path immediately so we can use tools we build (like gperf)
export PATH="$INSTALL_DIR/bin:$PATH"

# PKG_CONFIG_PATH SETUP
# We need our local libs AND the system libs (for glib-2.0)
# Found system pkgconfig at: /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/pkgconfig
SYSTEM_PKG_PATH="/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$SYSTEM_PKG_PATH:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$LD_LIBRARY_PATH"

# Parallel build
JOBS=$(nproc)

echo "Building dependencies in $WORK_DIR"
echo "Installing to $INSTALL_DIR"

# 0. Install gperf (Host tool needed for fontconfig)
if command -v gperf &> /dev/null; then
    echo "Checking existing gperf..."
    if ! gperf --version &> /dev/null; then
        rm -f "$(command -v gperf)"
        hash -r 2>/dev/null || true
    fi
fi

if ! command -v gperf &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y gperf || true
    fi

    if ! command -v gperf &> /dev/null; then
        echo "Downloading pre-compiled gperf binary (Debian amd64)..."
        cd "$WORK_DIR"
        GPERF_DEB="gperf_3.1-1_amd64.deb"
        rm -f "$GPERF_DEB"
        wget -c http://ftp.debian.org/debian/pool/main/g/gperf/$GPERF_DEB
        ar x "$GPERF_DEB"
        if [ -f "data.tar.xz" ]; then tar -xf data.tar.xz; elif [ -f "data.tar.gz" ]; then tar -xf data.tar.gz; else echo "Error: Could not find data.tar.*"; exit 1; fi
        cp usr/bin/gperf "$INSTALL_DIR/bin/"
        chmod +x "$INSTALL_DIR/bin/gperf"
        "$INSTALL_DIR/bin/gperf" --version || exit 1
        rm -rf usr
        cd "$WORK_DIR"
    fi
else
    echo "gperf found: $(command -v gperf)"
fi

# Ensure environment is set up for cross-compilation
if [ -z "$CROSS_TRIPLE" ]; then
    echo "CROSS_TRIPLE not set. Attempting to detect..."
    if which aarch64-nextui-linux-gnu-gcc >/dev/null 2>&1; then
        export CROSS_TRIPLE="aarch64-nextui-linux-gnu"
    elif [ -d "/opt/aarch64-nextui-linux-gnu/bin" ]; then
        export PATH="/opt/aarch64-nextui-linux-gnu/bin:$PATH"
        export CROSS_TRIPLE="aarch64-nextui-linux-gnu"
    else
        echo "Error: Could not determine CROSS_TRIPLE."
        exit 1
    fi
fi

if [ -z "$CC" ]; then
    export CC="${CROSS_TRIPLE}-gcc"
    export CXX="${CROSS_TRIPLE}-g++"
    export AR="${CROSS_TRIPLE}-ar"
    export LD="${CROSS_TRIPLE}-ld"
fi

echo "Host Triple: $CROSS_TRIPLE"

# Versions
PIXMAN_VER="0.42.2"
CAIRO_VER="1.16.0"
FONTCONFIG_VER="2.14.2"
FREETYPE_VER="2.13.0"

# 1. Pixman
cd "$WORK_DIR"
if [ ! -d "pixman-$PIXMAN_VER" ]; then
    echo "Downloading Pixman..."
    wget -c https://www.cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz
    tar -xf pixman-$PIXMAN_VER.tar.gz
fi
cd "pixman-$PIXMAN_VER"
if [ ! -f Makefile ]; then
    ./configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared
fi
make -j$JOBS
make install

# 2. Freetype
cd "$WORK_DIR"
if [ ! -d "freetype-$FREETYPE_VER" ]; then
    echo "Downloading Freetype..."
    wget -c https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.gz
    tar -xf freetype-$FREETYPE_VER.tar.gz
fi
cd "freetype-$FREETYPE_VER"
echo "Configuring Freetype..."
mkdir -p build
cd build
../configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared --without-brotli --without-harfbuzz --without-png --without-zlib
make -j$JOBS
make install

# 3. Fontconfig
cd "$WORK_DIR"
if [ -d "fontconfig-$FONTCONFIG_VER" ]; then rm -rf "fontconfig-$FONTCONFIG_VER"; fi
if [ ! -d "fontconfig-$FONTCONFIG_VER" ]; then
    echo "Downloading Fontconfig..."
    wget -c https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.gz
    tar -xf fontconfig-$FONTCONFIG_VER.tar.gz
fi
cd "fontconfig-$FONTCONFIG_VER"
export FREETYPE_CFLAGS="-I$INSTALL_DIR/include/freetype2"
export FREETYPE_LIBS="-L$INSTALL_DIR/lib -lfreetype"
./configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared --disable-docs --disable-nls --with-default-fonts=/usr/share/fonts
make -j$JOBS
make install

# 4. Cairo
cd "$WORK_DIR"
rm -rf cairo-1.17.*
if [ -d "cairo-$CAIRO_VER" ]; then rm -rf "cairo-$CAIRO_VER"; fi
if [ ! -d "cairo-$CAIRO_VER" ]; then
    echo "Downloading Cairo..."
    wget -c https://www.cairographics.org/releases/cairo-$CAIRO_VER.tar.xz
    tar -xf cairo-$CAIRO_VER.tar.xz
fi
cd "cairo-$CAIRO_VER"
export pixman_CFLAGS="-I$INSTALL_DIR/include/pixman-1"
export pixman_LIBS="-L$INSTALL_DIR/lib -lpixman-1"
./configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared \
    --disable-xlib --disable-xcb --disable-win32 \
    --enable-pdf --enable-png --enable-ft --enable-fc
make -j$JOBS
make install

# 5. Poppler (Download Pre-compiled ARM64)
# We use Debian Buster (Debian 10) as a safe baseline for glibc compatibility
echo "Downloading pre-compiled Poppler ARM64 packages..."
cd "$WORK_DIR"

# URLs for libpoppler-glib8 and libpoppler82 (compatible versions from Buster)
# Update: Using archive.debian.org because these older versions might be removed from main pool
POPPLER_GLIB_DEB="libpoppler-glib8_0.71.0-5_arm64.deb"
POPPLER_CORE_DEB="libpoppler82_0.71.0-5_arm64.deb"
POPPLER_DEV_DEB="libpoppler-glib-dev_0.71.0-5_arm64.deb"

# Clean old artifacts
rm -f *.deb
rm -rf extract_poppler

# Download from Archive
wget -c http://archive.debian.org/debian/pool/main/p/poppler/$POPPLER_GLIB_DEB
wget -c http://archive.debian.org/debian/pool/main/p/poppler/$POPPLER_CORE_DEB
wget -c http://archive.debian.org/debian/pool/main/p/poppler/$POPPLER_DEV_DEB

mkdir -p extract_poppler
cd extract_poppler

# Extract function
extract_deb() {
    ar x "../$1"
    if [ -f "data.tar.xz" ]; then tar -xf data.tar.xz; elif [ -f "data.tar.gz" ]; then tar -xf data.tar.gz; fi
    rm -f control.tar.* data.tar.* debian-binary
}

extract_deb "$POPPLER_GLIB_DEB"
extract_deb "$POPPLER_CORE_DEB"
extract_deb "$POPPLER_DEV_DEB"

echo "Installing Poppler files..."
# Copy libs
# Preserve links is important here
cp -P -r usr/lib/aarch64-linux-gnu/* "$INSTALL_DIR/lib/"

# Copy headers
mkdir -p "$INSTALL_DIR/include"
cp -r usr/include/poppler "$INSTALL_DIR/include/"

# Cleanup
cd "$WORK_DIR"
rm -rf extract_poppler

# Fix symlinks if needed (Debian often splits .so and .so.X)
# We need libpoppler-glib.so pointing to the real file for linking
cd "$INSTALL_DIR/lib"
if [ ! -f "libpoppler-glib.so" ]; then
    # Find the real file (e.g. libpoppler-glib.so.8)
    REAL_LIB=$(ls libpoppler-glib.so.* | head -n 1)
    if [ -n "$REAL_LIB" ]; then
        ln -sf "$REAL_LIB" libpoppler-glib.so
        echo "Created symlink for $REAL_LIB"
    fi
fi
if [ ! -f "libpoppler.so" ]; then
    REAL_LIB=$(ls libpoppler.so.* | head -n 1)
    if [ -n "$REAL_LIB" ]; then
        ln -sf "$REAL_LIB" libpoppler.so
        echo "Created symlink for $REAL_LIB"
    fi
fi

# Verification
if [ ! -f "$INSTALL_DIR/lib/libpoppler-glib.so" ]; then
    echo "ERROR: Failed to install libpoppler-glib.so from binaries!"
    exit 1
fi

echo "Done! Libraries installed to $INSTALL_DIR"
