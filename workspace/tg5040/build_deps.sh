#!/bin/bash
set -e

# Setup paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR="$SCRIPT_DIR/build_work"
INSTALL_DIR="$SCRIPT_DIR/libs"
mkdir -p "$WORK_DIR"
mkdir -p "$INSTALL_DIR"

# Add install dir to path immediately so we can use tools we build (like gperf)
export PATH="$INSTALL_DIR/bin:$PATH"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$LD_LIBRARY_PATH"

# Parallel build
JOBS=$(nproc)

echo "Building dependencies in $WORK_DIR"
echo "Installing to $INSTALL_DIR"

# 0. Build gperf (Host tool needed for fontconfig)
GPERF_VER="3.1"
cd "$WORK_DIR"
if ! command -v gperf &> /dev/null; then
    echo "gperf not found. Building gperf..."

    # Force clean build to avoid stuck states from previous failed attempts
    if [ -d "gperf-$GPERF_VER" ]; then
        rm -rf "gperf-$GPERF_VER"
    fi

    if [ ! -d "gperf-$GPERF_VER" ]; then
        echo "Downloading gperf..."
        wget -c http://ftp.gnu.org/pub/gnu/gperf/gperf-$GPERF_VER.tar.gz
        tar -xf gperf-$GPERF_VER.tar.gz
    fi
    cd "gperf-$GPERF_VER"
    if [ ! -f Makefile ]; then
        # Use system gcc for host tool and sanitize env to avoid cross-compiler pollution
        # We run this in a subshell or just setting vars for this command to avoid messing up global state
        echo "Configuring gperf for host..."
        (
            unset CPP CXXCPP CROSS_COMPILE ARCH LDFLAGS CFLAGS CXXFLAGS
            export CC=gcc
            export CXX=g++
            export CPP="gcc -E"
            export CXXCPP="g++ -E"
            ./configure --prefix="$INSTALL_DIR"
        )
    fi
    make -j$JOBS
    make install
    cd "$WORK_DIR"
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
