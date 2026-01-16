#!/bin/bash
set -e

# Path to the library directory
LIB_DIR="workspace/tg5040/libs/lib"

# Check if directory exists
if [ ! -d "$LIB_DIR" ]; then
    echo "Error: Library directory $LIB_DIR does not exist."
    echo "Please run build_deps.sh first."
    exit 1
fi

# Name of the output archive
OUTPUT_ZIP="freetype_libs.zip"

echo "Archiving libfreetype files from $LIB_DIR..."

# Navigate to the directory to keep paths clean in the zip
cd "$LIB_DIR"

# Zip the files, preserving symbolic links (-y)
# We match libfreetype.so* to get the actual lib and its symlinks
if ls libfreetype.so* 1> /dev/null 2>&1; then
    zip -y "$OUTPUT_ZIP" libfreetype.so*
    echo "Success! Archive created at: $LIB_DIR/$OUTPUT_ZIP"
else
    echo "Error: No libfreetype.so files found in $LIB_DIR."
fi
