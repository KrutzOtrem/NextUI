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
SYSTEM_PKG_PATH="/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$SYSTEM_PKG_PATH:$PKG_CONFIG_PATH"
export PKG_CONFIG_LIBDIR="$INSTALL_DIR/lib/pkgconfig:$SYSTEM_PKG_PATH"
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
fi

# Ensure environment is set up for cross-compilation
if [ -z "$CROSS_TRIPLE" ]; then
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

# Versions
PIXMAN_VER="0.42.2"
CAIRO_VER="1.16.0"
POPPLER_VER="22.02.0"
FONTCONFIG_VER="2.14.2"
FREETYPE_VER="2.13.0"

# 1. Pixman
cd "$WORK_DIR"
if [ ! -d "pixman-$PIXMAN_VER" ]; then
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
    wget -c https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.gz
    tar -xf freetype-$FREETYPE_VER.tar.gz
fi
cd "freetype-$FREETYPE_VER"
mkdir -p build
cd build
../configure --prefix="$INSTALL_DIR" --host=$CROSS_TRIPLE --disable-static --enable-shared --without-brotli --without-harfbuzz --without-png --without-zlib
make -j$JOBS
make install

# 3. Fontconfig
cd "$WORK_DIR"
if [ -d "fontconfig-$FONTCONFIG_VER" ]; then rm -rf "fontconfig-$FONTCONFIG_VER"; fi
if [ ! -d "fontconfig-$FONTCONFIG_VER" ]; then
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

# 5. Poppler
cd "$WORK_DIR"
if [ -d "poppler-$POPPLER_VER" ]; then rm -rf "poppler-$POPPLER_VER"; fi
if [ ! -d "poppler-$POPPLER_VER" ]; then
    wget -c https://poppler.freedesktop.org/poppler-$POPPLER_VER.tar.xz
    tar -xf poppler-$POPPLER_VER.tar.xz
fi
cd "poppler-$POPPLER_VER"

# FORCE PATCH: Disable the check that disables the GLib wrapper
# The original code is:
# if(NOT GLIB2_FOUND)
#   message(STATUS "GLib2 not found, disabling wrapper")
#   set(ENABLE_GLIB OFF)
# endif()
# We replace it to force GLIB2_FOUND to TRUE or simply comment out the disabling logic
echo "Patching CMakeLists.txt to force GLib wrapper..."
sed -i 's/if(NOT GLIB2_FOUND)/if(FALSE)/g' CMakeLists.txt

mkdir -p build
cd build

# Manually define all deps to force GLib wrapper
SYS_ROOT="/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc"
SYS_INC="$SYS_ROOT/usr/include"
SYS_LIB="$SYS_ROOT/usr/lib"

# We must ensure compilation flags include glib paths since auto-detection might fail
export CXXFLAGS="$CXXFLAGS -I$SYS_INC/glib-2.0 -I$SYS_LIB/glib-2.0/include -I$SYS_INC"
export CFLAGS="$CFLAGS -I$SYS_INC/glib-2.0 -I$SYS_LIB/glib-2.0/include -I$SYS_INC"

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
    -DENABLE_BOOST=OFF \
    -DENABLE_LIBPNG=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE \
    -DPNG_FOUND=FALSE \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-DPNG_SKIP_SETJMP_CHECK" \
    -DGLIB2_FOUND=TRUE \
    -DGLIB2_INCLUDE_DIR="$SYS_INC/glib-2.0;$SYS_LIB/glib-2.0/include" \
    -DGLIB2_INCLUDE_DIRS="$SYS_INC/glib-2.0;$SYS_LIB/glib-2.0/include" \
    -DGLIB2_LIBRARIES="$SYS_LIB/libglib-2.0.so" \
    -DGLIB2_LIBRARY="$SYS_LIB/libglib-2.0.so" \
    -DGOBJECT_FOUND=TRUE \
    -DGOBJECT_INCLUDE_DIR="$SYS_INC" \
    -DGOBJECT_INCLUDE_DIRS="$SYS_INC" \
    -DGOBJECT_LIBRARIES="$SYS_LIB/libgobject-2.0.so" \
    -DGOBJECT_LIBRARY="$SYS_LIB/libgobject-2.0.so" \
    -DGIO_FOUND=TRUE \
    -DGIO_INCLUDE_DIR="$SYS_INC" \
    -DGIO_INCLUDE_DIRS="$SYS_INC" \
    -DGIO_LIBRARIES="$SYS_LIB/libgio-2.0.so" \
    -DGIO_LIBRARY="$SYS_LIB/libgio-2.0.so" \
    -DCAIRO_FOUND=TRUE \
    -DCAIRO_INCLUDE_DIRS="$INSTALL_DIR/include/cairo" \
    -DCAIRO_INCLUDE_DIR="$INSTALL_DIR/include/cairo" \
    -DCAIRO_LIBRARIES="$INSTALL_DIR/lib/libcairo.so" \
    -DCAIRO_LIBRARY="$INSTALL_DIR/lib/libcairo.so" \
    -DFREETYPE_INCLUDE_DIRS="$INSTALL_DIR/include/freetype2" \
    -DFREETYPE_LIBRARIES="$INSTALL_DIR/lib/libfreetype.so" \
    -DFONTCONFIG_INCLUDE_DIR="$INSTALL_DIR/include" \
    -DFONTCONFIG_LIBRARIES="$INSTALL_DIR/lib/libfontconfig.so" \
    -DCMAKE_FIND_ROOT_PATH="$INSTALL_DIR" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY

make -j$JOBS
make install

# Final verification
if [ ! -f "$INSTALL_DIR/lib/libpoppler-glib.so" ]; then
    echo "ERROR: libpoppler-glib.so was NOT built! Check CMake output for 'glib wrapper: no'."
    exit 1
fi

echo "Done! Libraries installed to $INSTALL_DIR"
