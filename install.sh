#!/bin/bash

# -------------------
# Include helper functions
# -------------------
source "./helpers.sh"


# -------------------
# Check services are off
# -------------------

check_services_off() {
    local services=(
        "immich-web.service"
        "immich-ml.service"
    )

    for svc in "${services[@]}"; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}"; then
            if systemctl is-active --quiet "$svc"; then
                echo "Service $svc is RUNNING — expected OFF."
                echo "To stop services (as root):"
                echo "systemctl stop $svc"
                return 1
            else
                echo "Service $svc exists and is OFF."
            fi
        else
            echo "Service $svc does not exist yet — treating as OFF."
        fi
    done

    return 0
}

# -------------------
# Check current user
# -------------------

check_user_id () {
    if [ "$EUID" -eq 0 ]; then
        echo "Error: This script should NOT be run as root."
        exit 1
    fi
}


# -------------------
# Create env file if it does not exist
# -------------------
SCRIPT_DIR=$PWD

create_install_env_file () {
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        echo "Error: .env file not found"
        echo "Create one by modifying an example file example.env"
        echo "cp example.env .env"
        exit 1
    fi
}


# -------------------
# Load environment variables from env file
# -------------------

load_environment_variables () {
    cd "$SCRIPT_DIR"
    set -a
    . ./.env
    set +a
}


# -------------------
# Common variables
# -------------------
set_common_variables () {
    set -a
    INSTALL_DIR_src=$INSTALL_DIR/source
    INSTALL_DIR_app=$INSTALL_DIR/app
    INSTALL_DIR_ml=$INSTALL_DIR_app/machine-learning
    INSTALL_DIR_geo=$INSTALL_DIR/geodata
    TMP_DIR=/tmp/$(whoami)/immich-in-lxc/
    REPO_URL="https://github.com/immich-app/immich"
    set +a
}


# -------------------
# Review environment variables
# -------------------

review_install_information () {
    echo "------------------Installation Configuration from .env------------------"
    echo "Desired version: $REPO_TAG"
    echo "Install Location: $INSTALL_DIR"
    echo "Upload Location: $UPLOAD_DIR"
    echo "isCUDA: $isCUDA"
    echo "PROXY_NPM: $PROXY_NPM"
    echo "PROXY_NPM_DIST: $PROXY_NPM_DIST"
    echo "PROXY_POETRY: $PROXY_POETRY"
    echo
}


# -------------------
# Check if node is installed
# -------------------

install_node () {
    if ! command -v node &> /dev/null; then
        echo "ERROR: Node.js is not installed."
        echo "Installing Node.js for current user"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
        \. "$HOME/.nvm/nvm.sh"
        NVM_NODEJS_ORG_MIRROR=$PROXY_NPM_DIST
        nvm install 24
        echo "Finish installing Node.js 24"
    fi

    # Source nvm in case it's a fresh shell
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Get required pnpm version from source package.json if available
    local PNPM_VERSION="10"
    if [[ -f "$INSTALL_DIR_src/package.json" ]]; then
        local PKG_PNPM
        PKG_PNPM="$(jq -r '.packageManager // empty' "$INSTALL_DIR_src/package.json" | grep -oP '[\d.]+')" || true
        if [[ -n "$PKG_PNPM" ]]; then
            PNPM_VERSION="$PKG_PNPM"
        fi
    fi

    if ! command -v pnpm &> /dev/null; then
        echo "Installing pnpm@${PNPM_VERSION}"
        npm install -g "pnpm@${PNPM_VERSION}"
    fi

    echo "------------------Current versions------------------"
    echo "npm version: $(npm -v)"
    echo "node version: $(node -v)"
    echo "pnpm version: $(pnpm -v)"
    echo
}


# -------------------
# Check if dependencies are met
# -------------------

review_dependency () {
    if ! command -v ffmpeg &> /dev/null; then
        echo "ERROR: ffmpeg is not installed."
        echo "Please run pre-install.sh first"
        exit 1
    fi

    if ! command -v node &> /dev/null; then
        echo "ERROR: Node.js is not installed."
        exit 1
    fi

    if ! command -v python3 &> /dev/null; then
        echo "ERROR: Python is not installed."
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        echo "ERROR: Git is not installed."
        exit 1
    fi

    # Check for uv
    if ! command -v uv &> /dev/null; then
        # Try sourcing the path
        export PATH="$HOME/.local/bin:$PATH"
        if ! command -v uv &> /dev/null; then
            echo "WARNING: uv is not installed. Falling back to poetry for ML install."
            echo "Install uv for faster ML dependency resolution: curl -LsSf https://astral.sh/uv/install.sh | sh"
        fi
    fi

    if [ "$isCUDA" = true ]; then
        if ! nvidia-smi &> /dev/null; then
            echo "ERROR: Nvidia driver is not installed, and isCUDA is set to true"
            exit 1
        fi
    fi

    echo "Dependency check passed!"
}


# -------------------
# Enable maintenance mode if upgrading
# -------------------

enable_maintenance_mode () {
    if [[ -f "$INSTALL_DIR_app/bin/immich-admin" && -f "$INSTALL_DIR/runtime.env" ]]; then
        echo "Enabling maintenance mode..."
        (
            set -a
            . "$INSTALL_DIR/runtime.env"
            set +a
            cd "$INSTALL_DIR_app/bin"
            node ./immich-admin enable-maintenance-mode 2>/dev/null || true
        )
        export MAINT_MODE=1
    else
        echo "Skipping maintenance mode (first install or runtime.env not found)."
    fi
}



# -------------------
# Disable maintenance mode after upgrade
# -------------------

disable_maintenance_mode () {
    if [[ "${MAINT_MODE:-0}" == "1" && -f "$INSTALL_DIR_app/bin/immich-admin" && -f "$INSTALL_DIR/runtime.env" ]]; then
        echo "Disabling maintenance mode..."
        (
            set -a
            . "$INSTALL_DIR/runtime.env"
            set +a
            cd "$INSTALL_DIR_app/bin"
            node ./immich-admin disable-maintenance-mode 2>/dev/null || true
        )
        unset MAINT_MODE
    fi
}



# -------------------
# Clean previous build
# -------------------

clean_previous_build () {
    confirm_destruction "$INSTALL_DIR_app"
    rm -rf "$INSTALL_DIR_app"
}


# -------------------
# Create folders
# -------------------

create_folders () {
    mkdir -p "$INSTALL_DIR_app"

    if [ ! -d "$UPLOAD_DIR" ]; then
        echo "$UPLOAD_DIR does not exist, creating one"
        mkdir -p "$UPLOAD_DIR"
    else
        echo "$UPLOAD_DIR already exists, skip creation"
    fi

    mkdir -p "$INSTALL_DIR_geo"
    mkdir -p "$TMP_DIR"
}

# -------------------
# Apply version specific git patches
# -------------------

git_patch () {
    if [ -d "$SCRIPT_DIR/git-patches/$REPO_TAG" ]; then
        (
            cd "$INSTALL_DIR_src"
            git apply "$SCRIPT_DIR/git-patches/$REPO_TAG"/*.patch
        )
    fi
}

# -------------------
# Remove mise tools that we do not need for server install
# -------------------
mise_local_override() {
    cd "$INSTALL_DIR_src"

    cat > mise.local.toml <<'EOF'
[settings]
disable_tools = [
  "flutter",
  "java",
  "opentofu",
  "terragrunt"
]
EOF
}

# -------------------
# Install immich-web-server
# -------------------

install_immich_web_server_pnpm () {
    cd "$INSTALL_DIR_src"

    # Set mirror for pnpm (if needed)
    if [ -n "${PROXY_NPM}" ]; then
        pnpm config set registry="$PROXY_NPM"
    fi

    # Enable corepack for consistent pnpm version
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    export CI=1
    corepack enable 2>/dev/null || true

    # ============================================================
    # FIX: Increase Node.js heap size for Vite/Svelte web build
    # Default is ~1.7 GB which is insufficient for the web build.
    # Adjust the value based on your available RAM.
    # ============================================================
    export NODE_OPTIONS="--max-old-space-size=8192"

    # Install dependencies
    pnpm install --frozen-lockfile

    # --- Phase 1: Build (ignore global libvips so pnpm install doesn't try to link sharp prematurely) ---
    export SHARP_IGNORE_GLOBAL_LIBVIPS=true
    pnpm --filter immich --frozen-lockfile build
    unset SHARP_IGNORE_GLOBAL_LIBVIPS

    # --- Phase 2: Deploy with system libvips ---
    export SHARP_FORCE_GLOBAL_LIBVIPS=true

    # Build SDK + web
    pnpm --filter @immich/sdk --filter immich-web --frozen-lockfile build

    # Deploy the server component using system libvips
    pnpm --filter immich --prod --frozen-lockfile --no-optional deploy "$INSTALL_DIR_app"

    # Rebuild sharp in the deployed directory against system libvips
    (cd "$INSTALL_DIR_app"; pnpm rebuild sharp)

    unset SHARP_FORCE_GLOBAL_LIBVIPS

    # Build and deploy the CLI
    pnpm --filter @immich/cli --frozen-lockfile --prod --no-optional deploy "$INSTALL_DIR_app/cli"

    ln -sf ../cli/bin/immich "$INSTALL_DIR_app/bin/immich"

    # Copy the built Web UI to the target directory
    cp -a web/build "$INSTALL_DIR_app/www"

    cp -a LICENSE "$INSTALL_DIR_app/"
    cp -a i18n "$INSTALL_DIR/"
    cp -a server/bin/get-cpus.sh server/bin/start.sh "$INSTALL_DIR_app/"

    # Copy package.json to bin for immich-admin
    cp "$INSTALL_DIR_app/package.json" "$INSTALL_DIR_app/bin/" 2>/dev/null || true

    # Fix immich-admin path
    if [[ -f "$INSTALL_DIR_app/bin/immich-admin" ]]; then
        sed -i "s|^start|${INSTALL_DIR_app}/bin/start|" "$INSTALL_DIR_app/bin/immich-admin" 2>/dev/null || true
    fi

    # Build plugins (v2.3.0+)
    if [ -d "plugins" ]; then
        (
            cd plugins
            pnpm install

            # Use mise if available (installed from APT in pre-install)
            if command -v mise &> /dev/null; then
                mise trust --all --yes 2>/dev/null || true
                mise trust ./mise.toml 2>/dev/null || true
                mise install 2>/dev/null || true
                mise run build 2>/dev/null || pnpm run build 2>/dev/null || true
            else
                # Fallback: try npm-installed mise
                if command -v npx &> /dev/null; then
                    npx @jdxcode/mise trust --all --yes 2>/dev/null || true
                    npx @jdxcode/mise build 2>/dev/null || true
                fi
            fi
        )

        mkdir -p "$INSTALL_DIR_app/corePlugin"
        if [ -d "./plugins/dist" ]; then
            cp -a ./plugins/dist "$INSTALL_DIR_app/corePlugin/"
            cp -a ./plugins/manifest.json "$INSTALL_DIR_app/corePlugin/manifest.json"
        fi
    else
        echo "plugins directory not found — skipping plugin build."
    fi

    # Unset mirror for pnpm (if it was set)
    if [ -n "${PROXY_NPM}" ]; then
        pnpm config delete registry
    fi

    # Clean up NODE_OPTIONS after build is done
    unset NODE_OPTIONS
}


# -------------------
# Generate build-lock
# -------------------

generate_build_lock () {
    cd "$SCRIPT_DIR"

    REPO_URL_BASE_IMG="https://github.com/immich-app/base-images"

    tag=$(grep -oP '(?<=immich-app/base-server-dev:)[0-9]+' "$INSTALL_DIR_app/Dockerfile" 2>/dev/null || echo "")

    if [[ -z "$tag" ]]; then
        echo "WARNING: Could not extract base-server-dev tag from Dockerfile. Trying 'main'..."
        tag="main"
    fi

    if [ -d base-images/.git ]; then
        echo "Updating existing base-images repo..."
        git -C base-images fetch --tags
        git -C base-images checkout "$tag" || {
            git -C base-images fetch origin "refs/tags/$tag:refs/tags/$tag"
            git -C base-images checkout "$tag"
        }
    else
        echo "Cloning fresh base-images repo at tag $tag..."
        safe_git_checkout "$REPO_URL_BASE_IMG" base-images "$tag"
    fi

    cd base-images/server/

    jq -s '.' packages/*.json > "$TMP_DIR/packages.json"
    jq -s '.' sources/*.json > "$TMP_DIR/sources.json"
    jq -n \
        --slurpfile sources "$TMP_DIR/sources.json" \
        --slurpfile packages "$TMP_DIR/packages.json" \
        '{sources: $sources[0], packages: $packages[0]}' \
        > "$INSTALL_DIR_app/build-lock.json"
}


# -------------------
# Install Immich-machine-learning (using uv if available, fallback to poetry)
# -------------------

install_immich_machine_learning () {
    cd "$INSTALL_DIR_src/machine-learning"

    # Ensure uv is in PATH
    export PATH="$HOME/.local/bin:$PATH"

    if command -v uv &> /dev/null; then
        install_ml_with_uv
    else
        echo "uv not found, falling back to poetry..."
        install_ml_with_poetry
    fi

    # Copy results
    cd "$INSTALL_DIR_src"
    cp -a machine-learning/ann machine-learning/immich_ml "$INSTALL_DIR_ml/"
}


install_ml_with_uv () {
    echo "Installing ML dependencies with uv..."
    cd "$INSTALL_DIR_src/machine-learning"

    export VIRTUAL_ENV="$INSTALL_DIR_ml/venv"
    mkdir -p "$INSTALL_DIR_ml"

    # Determine Python version
    local PYTHON_VERSION
    PYTHON_VERSION="$(python3 --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)"

    if [ "$isCUDA" = true ]; then
        uv sync --extra cuda --no-dev --active --link-mode copy -n -p "python${PYTHON_VERSION}"
    elif [ "$isCUDA" = "rocm" ]; then
        # Source ROCm environment
        if [[ -f /etc/profile.d/rocm.sh ]]; then
            # shellcheck disable=SC1091
            source /etc/profile.d/rocm.sh
        fi

        # Install base ML dependencies (this installs CPU onnxruntime)
        uv sync --extra cpu --no-dev --active --link-mode copy -n -p "python${PYTHON_VERSION}"

        # Replace CPU onnxruntime with MIGraphX version inside the venv
        (
            . "$VIRTUAL_ENV/bin/activate"

            # Ensure pip is available inside the uv-created venv
            python3 -m ensurepip --upgrade 2>/dev/null || uv pip install pip

            # Step 1: Uninstall CPU-only onnxruntime (conflicts with migraphx)
            python3 -m pip uninstall -y onnxruntime 2>/dev/null || true

            # Step 2: Clean up any leftover onnxruntime namespace directories
            local site_pkgs
            site_pkgs="$(python3 -c 'import site; print(site.getsitepackages()[0])')"
            if [[ -d "$site_pkgs/onnxruntime" ]]; then
                rm -rf "$site_pkgs/onnxruntime"
                rm -rf "$site_pkgs"/onnxruntime-*.dist-info
            fi

            # Step 3: Install onnxruntime-migraphx from AMD repo
            python3 -m pip install --no-cache-dir onnxruntime-migraphx \
                -f https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/

            # Step 4: Pin numpy < 2 (ROCm requirement, migraphx pulls numpy 2.x)
            python3 -m pip install "numpy<2"

            # Step 5: Verify MIGraphX provider is available
            echo "Verifying ROCm ML setup..."
            python3 -c "
import onnxruntime as ort
providers = ort.get_available_providers()
print('Available providers:', providers)
if 'MIGraphXExecutionProvider' not in providers:
    print('WARNING: MIGraphXExecutionProvider not found!')
    exit(1)
else:
    print('SUCCESS: MIGraphX provider is available')
"
        )
    else
        uv sync --extra cpu --no-dev --active --link-mode copy -n -p "python${PYTHON_VERSION}"
    fi
}




install_ml_with_poetry () {
    echo "Installing ML dependencies with poetry..."
    cd "$INSTALL_DIR_src/machine-learning"

    python3 -m venv "$INSTALL_DIR_ml/venv"
    (
        . "$INSTALL_DIR_ml/venv/bin/activate"

        if [ -z "${PROXY_POETRY}" ]; then
            PROXY_POETRY=https://pypi.org/simple/
        fi
        python3 -m pip install poetry -i "$PROXY_POETRY"

        if [ -n "${PROXY_POETRY}" ]; then
            poetry source add --priority=primary langsam "$PROXY_POETRY"
        fi

        python3_version=$(python3 --version 2>&1 | awk -F' ' '{print $2}' | awk -F'.' '{print $2}')
        if [ "$python3_version" = 12 ]; then
            sed -i -e 's/<3.12/<4/g' pyproject.toml
            poetry update
        fi

        if [ "$isCUDA" = true ]; then
            poetry install --no-root --extras cuda
        elif [ "$isCUDA" = "rocm" ]; then
            # Source ROCm environment
            if [[ -f /etc/profile.d/rocm.sh ]]; then
                # shellcheck disable=SC1091
                source /etc/profile.d/rocm.sh
            fi

            # Install base CPU dependencies
            poetry install --no-root --extras cpu

            # Remove CPU onnxruntime and clean up leftovers
            python3 -m pip uninstall -y onnxruntime 2>/dev/null || true
            local site_pkgs
            site_pkgs="$(python3 -c 'import site; print(site.getsitepackages()[0])')"
            if [[ -d "$site_pkgs/onnxruntime" ]]; then
                rm -rf "$site_pkgs/onnxruntime"
                rm -rf "$site_pkgs"/onnxruntime-*.dist-info
            fi

            # Install MIGraphX version
            python3 -m pip install --no-cache-dir onnxruntime-migraphx \
                -f https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/

            # Pin numpy < 2
            python3 -m pip install "numpy<2"

            # Verify
            python3 -c "
import onnxruntime as ort
providers = ort.get_available_providers()
print('Available providers:', providers)
if 'MIGraphXExecutionProvider' not in providers:
    print('WARNING: MIGraphXExecutionProvider not found!')
    exit(1)
else:
    print('SUCCESS: MIGraphX provider is available')
"
        else
            poetry install --no-root --extras cpu
        fi

        if [ -n "${PROXY_POETRY}" ]; then
            poetry source remove langsam
        fi
    )
}




# -------------------
# Replace /usr/src
# -------------------

replace_usr_src () {
    cd "$INSTALL_DIR_app"
    grep -Rl /usr/src | xargs -n1 sed -i -e "s@/usr/src@$INSTALL_DIR@g"
    ln -sf "$INSTALL_DIR_app/resources" "$INSTALL_DIR/"
    mkdir -p "$INSTALL_DIR/cache"

    sed -i -e "s@\"/cache\"@\"$INSTALL_DIR/cache\"@g" "$INSTALL_DIR_ml/immich_ml/config.py"

    grep -RlE "\"/build\"|'/build'" | xargs -n1 sed -i \
        -e "s@\"/build\"@\"$INSTALL_DIR_app\"@g" \
        -e "s@'/build'@'$INSTALL_DIR_app'@g"
}


# -------------------
# Setup upload directory
# -------------------

setup_upload_folder () {
    ln -sf "$UPLOAD_DIR" "$INSTALL_DIR_app/upload"
    ln -sf "$UPLOAD_DIR" "$INSTALL_DIR_ml/upload"
}


# -------------------
# Download GeoNames
# -------------------

download_geonames () {
    cd "$INSTALL_DIR_geo"
    if [ ! -f "cities500.zip" ] || [ ! -f "admin1CodesASCII.txt" ] || [ ! -f "admin2Codes.txt" ] || [ ! -f "ne_10m_admin_0_countries.geojson" ]; then
        echo "Incomplete geodata, start downloading"
        wget -o - https://download.geonames.org/export/dump/admin1CodesASCII.txt &
        wget -o - https://download.geonames.org/export/dump/admin2Codes.txt &
        wget -o - https://download.geonames.org/export/dump/cities500.zip &
        wget -o - https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson &
        wait
        unzip -o cities500.zip
        date --iso-8601=seconds | tr -d "\n" > geodata-date.txt
    else
        echo "Geodata exists, skip downloading"
    fi

    cd "$INSTALL_DIR"
    ln -sf "$INSTALL_DIR_geo" "$INSTALL_DIR_app/"
}


# -------------------
# Create custom start.sh script
# -------------------

create_custom_start_script () {
    # Immich web and microservices
    cat <<EOF > "$INSTALL_DIR_app/start.sh"
#!/bin/bash

export NVM_DIR="$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \\. "\$NVM_DIR/nvm.sh"

set -a
. $INSTALL_DIR/runtime.env
set +a

cd $INSTALL_DIR_app
exec node $INSTALL_DIR_app/dist/main "\$@"
EOF

    chmod 775 "$INSTALL_DIR_app/start.sh"

    # Machine learning
    cat <<EOF > "$INSTALL_DIR_ml/start.sh"
#!/bin/bash

set -a
. $INSTALL_DIR/runtime.env
set +a

cd $INSTALL_DIR_ml
. venv/bin/activate

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=120}"

exec gunicorn immich_ml.main:app \\
        -k immich_ml.config.CustomUvicornWorker \\
        -w "\$MACHINE_LEARNING_WORKERS" \\
        -b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \\
        -t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \\
        --log-config-json log_conf.json \\
        --graceful-timeout 0
EOF

    chmod 775 "$INSTALL_DIR_ml/start.sh"
}


# -------------------
# Create runtime environment file
# -------------------

create_runtime_env_file () {
    cd "$INSTALL_DIR"
    if [ ! -f runtime.env ]; then
        if [ -f "$SCRIPT_DIR/runtime.env" ]; then
            cp "$SCRIPT_DIR/runtime.env" runtime.env
            echo "New runtime.env file created from the template"
        else
            echo "runtime.env not found, please clone the entire repo, exiting"
            exit 1
        fi
    fi
}


# -------------------
# Create symlinks for CLI tools
# -------------------

create_cli_symlinks () {
    # immich CLI
    if [[ -f "$INSTALL_DIR_app/cli/bin/immich" ]]; then
        ln -sf "$INSTALL_DIR_app/cli/bin/immich" "$INSTALL_DIR_app/bin/immich"
        echo "immich CLI symlink created"
    fi

    # immich-admin
    if [[ -f "$INSTALL_DIR_app/bin/immich-admin" ]]; then
        echo "immich-admin is available at: $INSTALL_DIR_app/bin/immich-admin"
        echo "To make it system-wide, run as root:"
        echo "  ln -sf $INSTALL_DIR_app/bin/immich-admin /usr/bin/immich-admin"
    fi
}


# -------------------
# Helper function that checks user consent
# -------------------

confirm_destruction() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        echo "Error: no target path provided to confirm_destruction()" >&2
        exit 1
    fi

    echo "⚠️  WARNING: This operation would permanently DELETE everything under:"
    echo "    $target"
    echo
    read -rp "Are you sure you want to continue? Type 'Y' to proceed: " confirm

    if [[ "$confirm" != "Y" ]]; then
        echo "Aborted. Nothing will be deleted."
        exit 1
    fi
    return 0
}

set -euo pipefail
# set -x # Print each command (Debugging)

check_user_id
check_services_off
create_install_env_file
load_environment_variables
set_common_variables
review_install_information

install_node
review_dependency
enable_maintenance_mode
clean_previous_build
create_folders
safe_git_checkout "$REPO_URL" "$INSTALL_DIR_src" "$REPO_TAG"
mise_local_override
git_patch
install_immich_web_server_pnpm
generate_build_lock
install_immich_machine_learning
replace_usr_src
setup_upload_folder
download_geonames
create_custom_start_script
create_runtime_env_file
create_cli_symlinks
disable_maintenance_mode

echo "================================================================"
echo "Installation/Upgrade Completed"
echo "================================================================"
echo "If this was first installation - run post-install.sh as root."
echo "  ./post-install.sh"
echo "================================================================"
echo "If this was an update, restart the services (as root):"
echo "  systemctl restart immich-web immich-ml"
echo "================================================================"
