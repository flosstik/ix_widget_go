#!/bin/bash

# Alternative build script using static compilation (no CGO)
# This works if your Go code doesn't require CGO features
set -e

echo "Building table data Go library (static compilation)..."

# Change to the script directory
cd "$(dirname "$0")"

# Initialize Go module if needed
if [ ! -f "go.mod" ]; then
    echo "Initializing Go module..."
    go mod init github.com/is2/table_data
fi

# Build for Darwin (current platform)
echo "Building for Darwin..."
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -buildmode=c-shared -o libtabledata_darwin_static.so table_builder.go 2>/dev/null || {
    echo "⚠️  Warning: Static build failed for Darwin. Your code requires CGO."
}

# Build for Linux (cross-compilation without CGO)
echo "Building for Linux..."
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -buildmode=c-shared -o libtabledata_linux_static.so table_builder.go 2>/dev/null || {
    echo "⚠️  Warning: Static build failed for Linux. Your code requires CGO."
}

echo ""
echo "Note: If the builds failed, your code requires CGO for C interop."
echo "In that case, use one of these options:"
echo "1. Install cross-compiler: brew install messense/macos-cross-toolchains/x86_64-unknown-linux-gnu"
echo "2. Use Docker: ./build_with_docker.sh"
echo "3. Build on a Linux machine"