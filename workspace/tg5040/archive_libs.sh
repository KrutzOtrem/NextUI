#!/bin/bash
set -e

# Robust way to find the script's directory (absolute path)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Path to the library directory relative to the script
LIB_DIR="$SCRIPT_DIR/libs/lib"

echo "Script Directory: $SCRIPT_DIR"
echo "Target Library Directory: $LIB_DIR"

# Check if directory exists
if [ ! -d "$LIB_DIR" ]; then
    echo "Error: Library directory not found at $LIB_DIR"
    echo "This usually means the build dependencies have not been compiled yet."
    echo "Please run the build script first:"
    echo "  $SCRIPT_DIR/build_deps.sh"
    exit 1
fi

# Name of the output archive
OUTPUT_ZIP="freetype_libs.zip"

echo "Archiving libfreetype files..."

# Navigate to the directory to keep paths clean in the zip
cd "$LIB_DIR"

# Zip the files, preserving symbolic links (-y)
if ls libfreetype.so* 1> /dev/null 2>&1; then
    zip -y "$OUTPUT_ZIP" libfreetype.so*
    echo "Success! Archive created at: $LIB_DIR/$OUTPUT_ZIP"
else
    echo "Error: No libfreetype.so files found in $LIB_DIR."
    echo "Files present:"
    ls -F
fi
