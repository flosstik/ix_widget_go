#!/bin/bash

# Build script using Docker for cross-platform compilation
set -e

echo "Building table data Go library with Docker..."

# Change to the script directory
cd "$(dirname "$0")"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "✗ Docker is not installed. Please install Docker to use this script."
    exit 1
fi

# Function to build for a specific platform using Docker
build_with_docker() {
    local PLATFORM=$1
    local OUTPUT_FILE="libtabledata_${PLATFORM}.so"
    
    echo ""
    echo "Building for ${PLATFORM} using Docker..."
    
    # Use golang:latest image which supports cross-compilation
    docker run --rm \
        -v "$(pwd)":/workspace \
        -w /workspace \
        -e GOOS=${PLATFORM} \
        -e GOARCH=amd64 \
        -e CGO_ENABLED=1 \
        golang:latest \
        bash -c "
            apt-get update && apt-get install -y gcc-x86-64-linux-gnu g++-x86-64-linux-gnu &&
            export CC=x86_64-linux-gnu-gcc &&
            export CXX=x86_64-linux-gnu-g++ &&
            go build -buildmode=c-shared -o ${OUTPUT_FILE} table_builder.go
        "
    
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
BUILD_PLATFORM="${1:-linux}"

case "$BUILD_PLATFORM" in
    linux)
        build_with_docker "linux"
        ;;
    all)
        echo "Building native Darwin first..."
        ./build.sh --platform darwin
        echo ""
        echo "Building Linux with Docker..."
        build_with_docker "linux"
        ;;
    *)
        echo "Usage: $0 [linux|all]"
        echo "  linux: Build Linux binary using Docker"
        echo "  all: Build both Darwin (native) and Linux (Docker)"
        exit 1
        ;;
esac

echo ""
echo "Build complete!"