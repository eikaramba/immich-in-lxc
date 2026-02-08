#!/bin/bash

set -xeuo pipefail

# Install Dependency for Debian 12/13

# Add source (only for Debian 12; Trixie already has these)
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

if [[ "${VERSION_ID:-}" == "12" ]]; then
    if [ ! -f "/etc/apt/sources.list.d/immich.list" ]; then
        cat > /etc/apt/sources.list.d/immich.list << EOL
deb http://deb.debian.org/debian testing main contrib
EOL
    fi

    if [ ! -f "/etc/apt/preferences.d/immich" ]; then
        cat > /etc/apt/preferences.d/immich << EOL
Package: *
Pin: release a=testing
Pin-Priority: -10
EOL
    fi

    apt update

    apt install --no-install-recommends -y \
        libjpeg62-turbo-dev

    apt install -t testing --no-install-recommends -yqq \
        libdav1d-dev \
        libhwy-dev \
        libwebp-dev \
        libio-compress-brotli-perl

    apt install -t testing --no-install-recommends -y \
        libio-compress-brotli-perl \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3 \
        libhwy1t64
else
    # Debian 13 (Trixie) or newer
    apt update

    apt install --no-install-recommends -y \
        libjpeg62-turbo-dev

    apt install --no-install-recommends -yqq \
        libdav1d-dev \
        libhwy-dev \
        libwebp-dev \
        libio-compress-brotli-perl \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3 \
        libhwy1t64
fi
