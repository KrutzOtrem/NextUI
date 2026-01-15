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
# Trying to compile it proved difficult due to cross-compiler environment pollution.
# Best approach: Install via apt if available, or download pre-compiled binary.
if ! command -v gperf &> /dev/null; then
    echo "gperf not found."

    # Try apt-get first (Debian/Ubuntu based images)
    if command -v apt-get &> /dev/null; then
        echo "Attempting to install gperf via apt-get..."
        # We need to update first usually, but try install directly just in case to save time/bandwidth
        # ignoring errors to fall back to binary download
        apt-get update && apt-get install -y gperf || echo "apt-get failed, falling back to binary download."
    fi

    # Check again
    if ! command -v gperf &> /dev/null; then
        echo "Downloading pre-compiled gperf binary..."
        # Static binary from a reliable source (e.g. Debian package or similar static build)
        # Since finding a guaranteed static binary URL that works forever is hard,
        # let's try to compile one LAST TIME but with a trick: make -e to override variables
        # actually, the user approved "do what you must", so let's try the safest compilation method:
        # separate source dir entirely from build to ensure no pollution.

        # Actually, let's just retry compilation but simpler:
        # Use gperf 3.0.4, force PATH to NOT include cross compiler during configure/make.

        GPERF_VER="3.0.4"
        cd "$WORK_DIR"
        if [ -d "gperf-$GPERF_VER" ]; then rm -rf "gperf-$GPERF_VER"; fi

        wget -c http://ftp.gnu.org/pub/gnu/gperf/gperf-$GPERF_VER.tar.gz
        tar -xf gperf-$GPERF_VER.tar.gz
        cd "gperf-$GPERF_VER"

        echo "Compiling gperf with strictly sanitized PATH..."
        (
            # Save strict path
            ORIG_PATH=$PATH
            # Set PATH to only system paths to hide cross-compiler
            export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            unset CC CXX CPP CXXCPP CROSS_COMPILE CROSS_TRIPLE AR LD NM RANLIB

            ./configure --prefix="$INSTALL_DIR"
            make -j$JOBS
            make install
        )
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
