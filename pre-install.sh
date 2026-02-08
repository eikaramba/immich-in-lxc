#!/bin/bash

# -------------------
# Include helper functions
# -------------------
source "./helpers.sh"


# -------------------
# Common variables
# -------------------
set_common_variables () {
    set -a
    SCRIPT_DIR=$PWD
    REPO_URL="https://github.com/immich-app/base-images"
    APP_REPO_URL="https://github.com/immich-app/immich"
    BASE_IMG_REPO_DIR=$SCRIPT_DIR/base-images
    SOURCE_DIR=$SCRIPT_DIR/image-source
    LD_LIBRARY_PATH=/usr/local/lib
    LD_RUN_PATH=/usr/local/lib
    REVISION_FILE=/root/.immich_library_revisions
    set_user_to_run
    set +a
}


# -------------------
# Remove build folder function
# -------------------

function remove_build_folder () {
    cd "$1"
    if [ -d "build" ]; then
        rm -r build
    fi
}

# -------------------
# Install runtime component
# -------------------

install_runtime_component () {
    cd "$SCRIPT_DIR"

    apt install --no-install-recommends -y \
        redis
}


# -------------------
# Install build dependency
# -------------------

install_build_dependency () {
    cd "$SCRIPT_DIR"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        echo "Error: /etc/os-release not found."
        exit 1
    fi

    ## Install common tools
    apt-get install --no-install-recommends -y \
        curl git python3-venv python3-dev unzip

    ## Install common build components
    apt-get install --no-install-recommends -y \
        autoconf \
        build-essential \
        ccache \
        cmake \
        jq \
        libbrotli-dev \
        libde265-dev \
        libexif-dev \
        libexpat1-dev \
        libglib2.0-dev \
        libgsf-1-dev \
        liblcms2-2 \
        libspng-dev \
        librsvg2-dev \
        meson \
        ninja-build \
        pkg-config \
        wget \
        zlib1g \
        cpanminus

    # Install for imagick & sharp
    apt-get install --no-install-recommends -y \
        libtool \
        libaom-dev \
        libx265-dev \
        libgif-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libpng-dev \
        libtiff-dev \
        liblcms2-dev \
        libxml2-dev \
        libfftw3-dev \
        libopenexr-dev \
        libzip-dev \
        libssl-dev \
        g++ \
        libimagequant-dev \
        libfontconfig1-dev \
        libcairo2-dev

    # Enable ccache for faster rebuilds
    export PATH="/usr/lib/ccache:$PATH"

    case "$ID" in
        ubuntu)
            echo "Detected Ubuntu. Running Ubuntu-specific script..."
            ./dep-ubuntu.sh
            JPEGLI_LIBJPEG_LIBRARY_SOVERSION="8"
            JPEGLI_LIBJPEG_LIBRARY_VERSION="8.2.2"
            ;;
        debian)
            echo "Detected Debian. Running Debian-specific script..."
            ./dep-debian.sh
            JPEGLI_LIBJPEG_LIBRARY_SOVERSION="62"
            JPEGLI_LIBJPEG_LIBRARY_VERSION="62.3.0"
            ;;
        *)
            echo "Unsupported OS ID: $ID"
            exit 1
            ;;
    esac
}


# -------------------
# Install ffmpeg automatically
# -------------------

install_ffmpeg () {
    if ! command -v ffmpeg &> /dev/null; then
        export SKIP_CONFIRM=true
        curl https://repo.jellyfin.org/install-debuntu.sh | sed '/apt install --yes jellyfin/,$d' | bash
        unset SKIP_CONFIRM
        apt install -y jellyfin-ffmpeg7
        ln -sf /usr/lib/jellyfin-ffmpeg/ffmpeg  /usr/bin/ffmpeg
        ln -sf /usr/lib/jellyfin-ffmpeg/ffprobe /usr/bin/ffprobe
    else
        echo "Skipping ffmpeg installation, because it is already installed"
    fi
}


# -------------------
# Install PostgreSQL with VectorChord
# -------------------

install_postgresql () {
    apt install -y postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt install -y postgresql-17 postgresql-17-pgvector

    # VectorChord
    VCHORD_VERSION="0.4.3"
    PG_VC_FILE_NAME="postgresql-17-vchord_${VCHORD_VERSION}-1_$(dpkg --print-architecture).deb"
    if [ ! -f "/root/$PG_VC_FILE_NAME" ]; then
        wget -P /root/ "https://github.com/tensorchord/VectorChord/releases/download/${VCHORD_VERSION}/${PG_VC_FILE_NAME}"
    fi
    apt install -y "/root/$PG_VC_FILE_NAME"

    # Track VectorChord version
    echo "$VCHORD_VERSION" > /root/.vectorchord_version

    runuser -u postgres -- psql -c 'ALTER SYSTEM SET shared_preload_libraries = "vchord"'
    systemctl restart postgresql.service
    sleep 5
    runuser -u postgres -- psql -c 'CREATE EXTENSION IF NOT EXISTS vchord CASCADE'
}


# -------------------
# Update VectorChord if needed
# -------------------

update_vectorchord () {
    local VCHORD_VERSION="0.4.3"
    local CURRENT_VERSION=""

    if [[ -f /root/.vectorchord_version ]]; then
        CURRENT_VERSION="$(cat /root/.vectorchord_version)"
    fi

    if [[ "$CURRENT_VERSION" == "$VCHORD_VERSION" ]]; then
        echo "VectorChord is already at version $VCHORD_VERSION, skipping update."
        return 0
    fi

    echo "Updating VectorChord from ${CURRENT_VERSION:-unknown} to $VCHORD_VERSION..."
    local PG_VC_FILE_NAME="postgresql-17-vchord_${VCHORD_VERSION}-1_$(dpkg --print-architecture).deb"
    wget -P /root/ "https://github.com/tensorchord/VectorChord/releases/download/${VCHORD_VERSION}/${PG_VC_FILE_NAME}"
    apt install -y "/root/$PG_VC_FILE_NAME"

    systemctl restart postgresql.service
    sleep 5

    runuser -u postgres -- psql -d immich -c "ALTER EXTENSION vector UPDATE;" || true
    runuser -u postgres -- psql -d immich -c "ALTER EXTENSION vchord UPDATE;" || true
    runuser -u postgres -- psql -d immich -c "REINDEX INDEX face_index;" || true
    runuser -u postgres -- psql -d immich -c "REINDEX INDEX clip_index;" || true

    echo "$VCHORD_VERSION" > /root/.vectorchord_version
    echo "VectorChord updated to $VCHORD_VERSION"
}


# -------------------
# Change lock file permission
# -------------------

change_permission () {
    chmod 666 "$BASE_IMG_REPO_DIR"/server/sources/*.json
}


# -------------------
# Setup folders
# -------------------

setup_folders () {
    cd "$SCRIPT_DIR"

    if [ ! -d "$SOURCE_DIR" ]; then
        mkdir "$SOURCE_DIR"
    fi
    chown -R "$USER_TO_RUN":"$USER_TO_RUN" "$SOURCE_DIR"
}


# -------------------
# Change locale
# -------------------

change_locale () {
    if [ -f /etc/locale.gen ]; then
        sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen
    else
        echo "Creating locale.gen for container environment..."
        mkdir -p /etc
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen || echo "locale-gen not available, skipping"
    fi
}


# -------------------
# Install mise from official repo
# -------------------

install_mise () {
    if ! command -v mise &> /dev/null; then
        echo "Installing mise from official APT repository..."
        curl -fsSL https://mise.jdx.dev/gpg-key.pub | tee /etc/apt/keyrings/mise-archive-keyring.pub > /dev/null
        echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.pub arch=amd64] https://mise.jdx.dev/deb stable main" \
            > /etc/apt/sources.list.d/mise.list
        apt-get update
        apt-get install -y mise
    else
        echo "mise is already installed, skipping"
    fi
}


# -------------------
# Install uv (fast Python package manager)
# -------------------

install_uv () {
    if ! command -v uv &> /dev/null; then
        echo "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # Source the env so uv is available in this session
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo "uv is already installed, skipping"
    fi
    # Also make uv available to the immich user
    if id immich &>/dev/null; then
        su - immich -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' 2>/dev/null || true
    fi
}


# -------------------
# Build libjxl
# -------------------

build_libjxl () {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libjxl"

    set -e
    echo "$JPEGLI_LIBJPEG_LIBRARY_SOVERSION"
    echo "$JPEGLI_LIBJPEG_LIBRARY_VERSION"

    : "${LIBJXL_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libjxl.json")}"
    set +e

    # Check if recompile is needed
    if ! needs_recompile "libjxl" "$LIBJXL_REVISION"; then
        echo "libjxl is already at revision $LIBJXL_REVISION, skipping build."
        return 0
    fi

    echo "Building libjxl at revision $LIBJXL_REVISION..."

    # Clean previous source if exists
    [[ -d "$SOURCE" ]] && rm -rf "$SOURCE"

    safe_git_checkout https://github.com/libjxl/libjxl.git "$SOURCE" "$LIBJXL_REVISION"

    cd "$SOURCE"

    git submodule update --init --recursive --depth 1 --recommend-shallow

    git apply "$BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-empty-dht-marker.patch"
    git apply "$BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-icc-warning.patch"

    remove_build_folder "$SOURCE"

    mkdir build
    cd build
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_PLUGIN_GIMP210=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
        -DJPEGXL_FORCE_SYSTEM_HWY=ON \
        -DJPEGXL_ENABLE_JPEGLI=ON \
        -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=ON \
        -DJPEGXL_INSTALL_JPEGLI_LIBJPEG=ON \
        -DJPEGXL_ENABLE_PLUGINS=ON \
        -DJPEGLI_LIBJPEG_LIBRARY_SOVERSION="${JPEGLI_LIBJPEG_LIBRARY_SOVERSION}" \
        -DJPEGLI_LIBJPEG_LIBRARY_VERSION="${JPEGLI_LIBJPEG_LIBRARY_VERSION}" \
        -DLIBJPEG_TURBO_VERSION_NUMBER=2001005 \
        ..
    echo "Building libjxl using $(nproc) threads"
    cmake --build . -- -j"$(nproc)"
    cmake --install .

    ldconfig /usr/local/lib

    make clean
    remove_build_folder "$SOURCE"
    rm -rf "$SOURCE/third_party/"

    set_tracked_revision "libjxl" "$LIBJXL_REVISION"
}


# -------------------
# Build libheif
# -------------------

build_libheif () {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libheif"

    set -e
    : "${LIBHEIF_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libheif.json")}"
    set +e

    if ! needs_recompile "libheif" "$LIBHEIF_REVISION"; then
        echo "libheif is already at revision $LIBHEIF_REVISION, skipping build."
        return 0
    fi

    echo "Building libheif at revision $LIBHEIF_REVISION..."
    [[ -d "$SOURCE" ]] && rm -rf "$SOURCE"

    safe_git_checkout https://github.com/strukturag/libheif.git "$SOURCE" "$LIBHEIF_REVISION"

    cd "$SOURCE"

    remove_build_folder "$SOURCE"

    mkdir build
    cd build
    cmake --preset=release-noplugins \
        -DWITH_DAV1D=ON \
        -DENABLE_PARALLEL_TILE_DECODING=ON \
        -DWITH_LIBSHARPYUV=ON \
        -DWITH_LIBDE265=ON \
        -DWITH_AOM_DECODER=OFF \
        -DWITH_AOM_ENCODER=ON \
        -DWITH_X265=ON \
        -DWITH_EXAMPLES=OFF \
        ..
    make install -j "$(nproc)"
    ldconfig /usr/local/lib

    make clean
    remove_build_folder "$SOURCE"

    set_tracked_revision "libheif" "$LIBHEIF_REVISION"
}


# -------------------
# Build libraw
# -------------------

build_libraw() {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libraw"

    set -e
    : "${LIBRAW_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libraw.json")}"
    set +e

    if ! needs_recompile "libraw" "$LIBRAW_REVISION"; then
        echo "libraw is already at revision $LIBRAW_REVISION, skipping build."
        return 0
    fi

    echo "Building libraw at revision $LIBRAW_REVISION..."
    [[ -d "$SOURCE" ]] && rm -rf "$SOURCE"

    safe_git_checkout "https://github.com/libraw/libraw.git" "$SOURCE" "$LIBRAW_REVISION"

    cd "$SOURCE"
    autoreconf --install

    mkdir -p build
    cd build

    ../configure
    echo "Building libraw using $(nproc) threads"
    make -j"$(nproc)"
    make install
    ldconfig /usr/local/lib

    make clean
    cd ..
    remove_build_folder "$SOURCE"

    set_tracked_revision "libraw" "$LIBRAW_REVISION"
}


# -------------------
# Build image magick
# -------------------

build_image_magick () {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/image-magick"

    set -e
    : "${IMAGEMAGICK_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/imagemagick.json")}"
    set +e

    if ! needs_recompile "imagemagick" "$IMAGEMAGICK_REVISION"; then
        echo "ImageMagick is already at revision $IMAGEMAGICK_REVISION, skipping build."
        return 0
    fi

    echo "Building ImageMagick at revision $IMAGEMAGICK_REVISION..."
    [[ -d "$SOURCE" ]] && rm -rf "$SOURCE"

    safe_git_checkout https://github.com/ImageMagick/ImageMagick.git "$SOURCE" "$IMAGEMAGICK_REVISION"

    cd "$SOURCE"

    ./configure --with-raw --with-modules
    echo "Building ImageMagick using $(nproc) threads"
    make -j"$(nproc)"
    make install
    ldconfig /usr/local/lib

    ldd "$(which magick)" | grep libraw

    make clean

    set_tracked_revision "imagemagick" "$IMAGEMAGICK_REVISION"
}


# -------------------
# Build libvips
# -------------------

build_libvips () {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libvips"

    set -e
    : "${LIBVIPS_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libvips.json")}"
    set +e

    if ! needs_recompile "libvips" "$LIBVIPS_REVISION"; then
        echo "libvips is already at revision $LIBVIPS_REVISION, skipping build."
        return 0
    fi

    echo "Building libvips at revision $LIBVIPS_REVISION..."
    [[ -d "$SOURCE" ]] && rm -rf "$SOURCE"

    safe_git_checkout https://github.com/libvips/libvips.git "$SOURCE" "$LIBVIPS_REVISION"

    cd "$SOURCE"

    remove_build_folder "$SOURCE"

    meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled
    cd build
    ninja install
    ldconfig /usr/local/lib

    remove_build_folder "$SOURCE"

    set_tracked_revision "libvips" "$LIBVIPS_REVISION"
}

# -------------------
# Remove build dependency (conservative — keep what sharp needs)
# -------------------

remove_build_dependency () {
    # Only remove packages that are NOT needed by sharp/node-gyp at build time.
    # sharp requires pkg-config to find vips and all its dependencies' .pc files.
    # We keep: libexpat1-dev, libexif-dev, libspng-dev, libglib2.0-dev, librsvg2-dev,
    #          liblcms2-dev, libgsf-1-dev, libpango1.0-dev, libcairo2-dev, libfontconfig1-dev,
    #          and other -dev packages that vips.pc references.
    apt-get remove -y \
        libheif-dev \
        libvips-dev \
        2>/dev/null || true

    # NOTE: If you want to reclaim more space after install.sh has completed,
    # you can manually remove additional -dev packages. But do NOT remove them
    # before running install.sh, or sharp will fail to build.
}


# -------------------
# Add runtime dependency
# -------------------

add_runtime_dependency () {
    apt-get install --no-install-recommends -yqq \
        libde265-0 \
        libexif12 \
        libexpat1 \
        libgcc-s1 \
        libglib2.0-0 \
        libgomp1 \
        libgsf-1-114 \
        liblcms2-2 \
        liblqr-1-0 \
        libltdl7 \
        libmimalloc2.0 \
        libopenexr-3-1-30 \
        libopenjp2-7 \
        librsvg2-2 \
        libspng0 \
        migraphx \
        mesa-utils \
        mesa-va-drivers \
        mesa-vulkan-drivers \
        tini \
        wget \
        zlib1g \
        ocl-icd-libopencl1
    apt-get install --no-install-recommends -y \
        libio-compress-brotli-perl \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3 \
        libhwy1t64
}

set -xeuo pipefail

set_common_variables
init_revision_tracking
safe_git_checkout "$REPO_URL" "$BASE_IMG_REPO_DIR" main
install_runtime_component
install_build_dependency
install_ffmpeg
install_postgresql
install_mise
install_uv
change_permission
setup_folders
change_locale
build_libjxl
build_libheif
build_libraw
build_image_magick
build_libvips
remove_build_dependency
add_runtime_dependency

echo "================================================================"
echo "Pre-install completed successfully!"
echo "Library revisions tracked in: $REVISION_FILE"
cat "$REVISION_FILE"
echo "================================================================"
