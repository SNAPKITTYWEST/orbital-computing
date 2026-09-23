#!/bin/bash
# Orbital Computing Stack - Build Script

set -e

echo "=== Orbital Computing Stack Build ==="
echo

# Configuration
TARGET_OS=${1:-linux}
TARGET_CPU=${2:-x86_64}
BUILD_MODE=${3:-debug}
INSTALL_DIR="./bin"

echo "Target OS: $TARGET_OS"
echo "Target CPU: $TARGET_CPU"
echo "Build Mode: $BUILD_MODE"
echo

# Create output directories
mkdir -p $INSTALL_DIR
mkdir -p obj/${TARGET_CPU}-${TARGET_OS}

# Compiler flags
FPCFLAGS="-Mobjfpc -H+ -J- -Scgi -Cg"

if [ "$BUILD_MODE" = "release" ]; then
    FPCFLAGS="$FPCFLAGS -O3 -Xs"
else
    FPCFLAGS="$FPCFLAGS -g -gl"
fi

# Platform-specific flags
case $TARGET_OS in
    linux)
        FPCFLAGS="$FPCFLAGS -Tlinux"
        ;;
    win32|win64)
        FPCFLAGS="$FPCFLAGS -Twin${TARGET_CPU%64}"
        ;;
    darwin)
        FPCFLAGS="$FPCFLAGS -Tdarwin"
        ;;
esac

# Set CPU
case $TARGET_CPU in
    x86_64)
        FPCFLAGS="$FPCFLAGS -Px86_64"
        ;;
    i386)
        FPCFLAGS="$FPCFLAGS -Pi386"
        ;;
    arm)
        FPCFLAGS="$FPCFLAGS -Parm"
        ;;
esac

# Compile
echo "Compiling source files..."
fpc $FPCFLAGS \
    -Isrc \
    -FEbin \
    -FUobj/${TARGET_CPU}-${TARGET_OS} \
    src/orbital-main.pas

if [ $? -eq 0 ]; then
    echo
    echo "Build successful!"
    echo "Output: $INSTALL_DIR/orbital-main"
    echo
    ls -lh bin/orbital-main*
else
    echo "Build failed!"
    exit 1
fi

# Generate documentation
echo
echo "Generating documentation..."
echo "See pascal/src/ for implementation details"
echo

# Statistics
echo "Code statistics:"
wc -l src/*.pas | tail -1

echo
echo "Build complete!"
