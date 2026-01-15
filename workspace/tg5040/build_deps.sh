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
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$LD_LIBRARY_PATH"

# Parallel build
JOBS=$(nproc)

echo "Building dependencies in $WORK_DIR"
echo "Installing to $INSTALL_DIR"

# 0. Install gperf (Host tool needed for fontconfig)

# Check if existing gperf is working (i.e., not a broken ARM binary from previous runs)
if command -v gperf &> /dev/null; then
    echo "Checking existing gperf..."
    if ! gperf --version &> /dev/null; then
        echo "Existing gperf is broken or incompatible (likely ARM binary). Removing it..."
        rm -f "$(command -v gperf)"
        # Also ensure we clear the hash cache in bash if running interactively, though set -e script implies non-interactive mostly
        hash -r 2>/dev/null || true
    else
        echo "Existing gperf seems to work."
    fi
fi

if ! command -v gperf &> /dev/null; then
    echo "gperf not found (or removed). Installing..."

    # Try apt-get first
    if command -v apt-get &> /dev/null; then
        echo "Attempting to install gperf via apt-get..."
        apt-get update && apt-get install -y gperf || echo "apt-get failed."
    fi

    # Check again
    if ! command -v gperf &> /dev/null; then
        echo "Downloading pre-compiled gperf binary (Debian amd64)..."

        cd "$WORK_DIR"
        # Download gperf 3.1 amd64 deb
        GPERF_DEB="gperf_3.1-1_amd64.deb"

        # Always re-download to be safe
        rm -f "$GPERF_DEB"
        wget -c http://ftp.debian.org/debian/pool/main/g/gperf/$GPERF_DEB

        # Extract it
        ar x "$GPERF_DEB"

        # Extract data.tar.xz (contains usr/bin/gperf)
        if [ -f "data.tar.xz" ]; then
            tar -xf data.tar.xz
        elif [ -f "data.tar.gz" ]; then
            tar -xf data.tar.gz
        else
            echo "Error: Could not find data.tar.* in deb package"
            exit 1
        fi

        # Move binary to our local bin
        cp usr/bin/gperf "$INSTALL_DIR/bin/"
        chmod +x "$INSTALL_DIR/bin/gperf"

        echo "Installed pre-compiled gperf to $INSTALL_DIR/bin/gperf"

        # Verify immediately
        "$INSTALL_DIR/bin/gperf" --version || (echo "Error: Installed gperf binary is invalid!" && exit 1)

        # Cleanup extraction
        rm -rf usr

        cd "$WORK_DIR"
    fi
else
    echo "gperf found: $(command -v gperf)"
fi

# Ensure environment is set up for cross-compilation
if [ -z "$CROSS_TRIPLE" ]; then
    echo "CROSS_TRIPLE not set. Attempting to detect..."
    # Try to find the cross compiler in the path or common locations
    if which aarch64-nextui-linux-gnu-gcc >/dev/null 2>&1; then
        export CROSS_TRIPLE="aarch64-nextui-linux-gnu"
    elif [ -d "/opt/aarch64-nextui-linux-gnu/bin" ]; then
        export PATH="/opt/aarch64-nextui-linux-gnu/bin:$PATH"
        export CROSS_TRIPLE="aarch64-nextui-linux-gnu"
    else
        echo "Error: Could not determine CROSS_TRIPLE. Please ensure you are running in the toolchain."
        exit 1
    fi
    echo "Detected CROSS_TRIPLE: $CROSS_TRIPLE"
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
CAIRO_VER="1.17.8"
POPPLER_VER="22.02.0"
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

# Use out-of-tree build to avoid top-level Makefile auto-detection issues
echo "Configuring Freetype..."
mkdir -p build
cd build
# Call the top-level configure from the build dir; it should correctly pass args down
../configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared --without-brotli --without-harfbuzz --without-png --without-zlib

make -j$JOBS
make install

# 3. Fontconfig
cd "$WORK_DIR"
if [ ! -d "fontconfig-$FONTCONFIG_VER" ]; then
    echo "Downloading Fontconfig..."
    wget -c https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.gz
    tar -xf fontconfig-$FONTCONFIG_VER.tar.gz
fi
cd "fontconfig-$FONTCONFIG_VER"
if [ ! -f Makefile ]; then
    ./configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared --disable-docs --disable-nls --with-default-fonts=/usr/share/fonts
fi
make -j$JOBS
make install

# 4. Cairo
cd "$WORK_DIR"
if [ ! -d "cairo-$CAIRO_VER" ]; then
    echo "Downloading Cairo..."
    wget -c https://www.cairographics.org/snapshots/cairo-$CAIRO_VER.tar.xz
    tar -xf cairo-$CAIRO_VER.tar.xz
fi
cd "cairo-$CAIRO_VER"
if [ ! -f Makefile ]; then
    ./configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared \
        --disable-xlib --disable-xcb --disable-win32 \
        --enable-pdf --enable-png --enable-ft --enable-fc
fi
make -j$JOBS
make install

# 5. Poppler
cd "$WORK_DIR"
if [ ! -d "poppler-$POPPLER_VER" ]; then
    echo "Downloading Poppler..."
    wget -c https://poppler.freedesktop.org/poppler-$POPPLER_VER.tar.xz
    tar -xf poppler-$POPPLER_VER.tar.xz
fi
cd "poppler-$POPPLER_VER"
mkdir -p build
cd build

cmake .. \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DENABLE_UTILS=OFF \
    -DENABLE_QT5=OFF \
    -DENABLE_QT6=OFF \
    -DENABLE_LIBOPENJPEG=none \
    -DENABLE_CPP=OFF \
    -DENABLE_GLIB=ON \
    -DBUILD_GTK_TESTS=OFF \
    -DBUILD_QT5_TESTS=OFF \
    -DBUILD_CPP_TESTS=OFF \
    -DENABLE_BOOST=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_FIND_ROOT_PATH="$INSTALL_DIR" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY

make -j$JOBS
make install

echo "Done! Libraries installed to $INSTALL_DIR"
