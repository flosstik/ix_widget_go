#!/bin/bash

# Build script for the table data Go library
set -e

echo "Building table data Go library..."

# Change to the script directory
cd "$(dirname "$0")"

# Initialize Go module if needed
if [ ! -f "go.mod" ]; then
    echo "Initializing Go module..."
    go mod init github.com/is2/table_data
fi

# Function to build for a specific platform
build_for_platform() {
    local GOOS=$1
    local GOARCH=$2
    local PLATFORM=$3
    local OUTPUT_FILE="libtabledata_${PLATFORM}.so"
    
    echo ""
    echo "Building for ${PLATFORM} (GOOS=${GOOS}, GOARCH=${GOARCH})..."
    
    # Set environment variables for cross-compilation
    export GOOS=${GOOS}
    export GOARCH=${GOARCH}
    export CGO_ENABLED=1
    
    # Set cross-compiler for Linux when building on Darwin
    if [ "${GOOS}" = "linux" ] && [ "$(uname -s)" = "Darwin" ]; then
        # Check if cross-compiler is available
        if command -v x86_64-linux-gnu-gcc &> /dev/null; then
            export CC=x86_64-linux-gnu-gcc
        else
            echo "⚠️  Warning: Linux cross-compiler not found. Install with:"
            echo "    brew install FiloSottile/musl-cross/musl-cross"
            echo "    or"
            echo "    brew install messense/macos-cross-toolchains/x86_64-unknown-linux-gnu"
            echo ""
            echo "Skipping Linux build..."
            return 1
        fi
    fi
    
    # Build the shared library
    go build -buildmode=c-shared -o "${OUTPUT_FILE}" table_builder.go
    
    # Check if build was successful
    if [ -f "${OUTPUT_FILE}" ]; then
        echo "✓ Build successful: ${OUTPUT_FILE}"
        chmod 755 "${OUTPUT_FILE}"
        return 0
    else
        echo "✗ Build failed for ${PLATFORM}!"
        return 1
    fi
}

# Parse command line arguments
BUILD_ALL=false
BUILD_PLATFORM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            BUILD_ALL=true
            shift
            ;;
        --platform)
            BUILD_PLATFORM="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--all] [--platform darwin|linux]"
            echo "  --all: Build for all supported platforms"
            echo "  --platform: Build for specific platform only"
            exit 1
            ;;
    esac
done

# Detect current architecture
CURRENT_ARCH=$(go env GOARCH)

# Determine what to build
if [ "$BUILD_ALL" = true ]; then
    echo "Building for all platforms..."
    build_for_platform "darwin" "$CURRENT_ARCH" "darwin"
    build_for_platform "linux" "amd64" "linux"
elif [ -n "$BUILD_PLATFORM" ]; then
    case "$BUILD_PLATFORM" in
        darwin)
            build_for_platform "darwin" "$CURRENT_ARCH" "darwin"
            ;;
        linux)
            build_for_platform "linux" "amd64" "linux"
            ;;
        *)
            echo "✗ Unsupported platform: $BUILD_PLATFORM"
            exit 1
            ;;
    esac
else
    # Default: build for current platform
    case "$(uname -s)" in
        Darwin*)
            build_for_platform "darwin" "$CURRENT_ARCH" "darwin"
            ;;
        Linux*)
            LINUX_ARCH=$(uname -m)
            case "$LINUX_ARCH" in
                x86_64)
                    build_for_platform "linux" "amd64" "linux"
                    ;;
                aarch64)
                    build_for_platform "linux" "arm64" "linux"
                    ;;
                *)
                    build_for_platform "linux" "$CURRENT_ARCH" "linux"
                    ;;
            esac
            ;;
        *)
            echo "✗ Unsupported platform: $(uname -s)"
            exit 1
            ;;
    esac
fi

echo ""
echo "Build complete!" 