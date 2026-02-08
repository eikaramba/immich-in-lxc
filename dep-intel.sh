#!/bin/bash

set -xeuo pipefail

# :warning: This script is only needed for Intel/OpenVINO ONNX execution provider.

# Dynamically fetch Intel GPU driver URLs from upstream Dockerfile
TEMP_DIR=/tmp/immich-intel
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

DOCKERFILE_URL="https://raw.githubusercontent.com/immich-app/base-images/refs/heads/main/server/Dockerfile"

echo "Fetching Intel GPU dependency URLs from upstream Dockerfile..."
curl -fsSL "$DOCKERFILE_URL" -o Dockerfile

apt-get install --no-install-recommends -yqq ocl-icd-libopencl1 wget

# Extract Intel package URLs from Dockerfile
readarray -t INTEL_URLS < <(
    sed -n "/intel-igc\|intel-opencl/p" Dockerfile | grep -oP 'https://\S+\.deb'
    sed -n "/libigdgmm12/p" Dockerfile | grep -oP 'https://\S+\.deb'
)

if [[ ${#INTEL_URLS[@]} -eq 0 ]]; then
    echo "WARNING: Could not parse Intel URLs from Dockerfile. Falling back to known versions."
    wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17384.11/intel-igc-core_1.0.17384.11_amd64.deb
    wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17384.11/intel-igc-opencl_1.0.17384.11_amd64.deb
    wget https://github.com/intel/compute-runtime/releases/download/24.31.30508.7/intel-opencl-icd_24.31.30508.7_amd64.deb
    wget https://github.com/intel/compute-runtime/releases/download/24.31.30508.7/libigdgmm12_22.4.1_amd64.deb
else
    for url in "${INTEL_URLS[@]}"; do
        echo "Downloading: $url"
        wget "$url"
    done
fi

dpkg -i ./*.deb

# Track installed version
dpkg-query -W -f='${Version}\n' intel-opencl-icd > ~/.intel_version 2>/dev/null || true

# Clean up
rm -rf "$TEMP_DIR"

echo "All Good"
