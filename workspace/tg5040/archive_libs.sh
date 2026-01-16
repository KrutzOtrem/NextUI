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
OUTPUT_ZIP="manual_plugin.zip"

echo "Archiving Manual Plugin..."

# Navigate to the directory to keep paths clean in the zip
cd "$LIB_DIR"

# Zip the wrapper lib
if [ -f libmanual_plugin.so ]; then
    zip -y "$OUTPUT_ZIP" libmanual_plugin.so
    echo "Success! Archive created at: $LIB_DIR/$OUTPUT_ZIP"
else
    echo "Error: libmanual_plugin.so not found in $LIB_DIR."
    echo "Did build_deps.sh complete successfully?"
fi
