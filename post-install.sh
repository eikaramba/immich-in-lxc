#!/bin/bash

set -xeuo pipefail

SCRIPT_DIR=$PWD

# -------------------
# Copy service files
# -------------------

copy_service_files () {
    # Remove deprecated service
    rm -f /etc/systemd/system/immich-microservices.service
    # Copy new services
    cp --update=none immich-ml.service /etc/systemd/system/
    cp --update=none immich-web.service /etc/systemd/system/
}

copy_service_files

# -------------------
# Create log directory
# -------------------

create_log_directory () {
    mkdir -p /var/log/immich
    # Ensure immich user can write logs
    if id immich &>/dev/null; then
        chown immich:immich /var/log/immich
    fi
}

create_log_directory

# -------------------
# Create system-wide symlinks for CLI tools
# -------------------

create_system_symlinks () {
    local INSTALL_DIR="/home/immich"

    # Read from .env if available
    if [[ -f ".env" ]]; then
        local env_install_dir
        env_install_dir="$(grep '^INSTALL_DIR=' .env | cut -d= -f2)"
        if [[ -n "$env_install_dir" ]]; then
            INSTALL_DIR="$env_install_dir"
        fi
    fi

    local APP_DIR="$INSTALL_DIR/app"

    if [[ -f "$APP_DIR/bin/immich-admin" ]]; then
        ln -sf "$APP_DIR/bin/immich-admin" /usr/bin/immich-admin
        echo "Created symlink: /usr/bin/immich-admin"
    fi

    if [[ -f "$APP_DIR/cli/bin/immich" ]]; then
        ln -sf "$APP_DIR/cli/bin/immich" /usr/bin/immich
        echo "Created symlink: /usr/bin/immich"
    fi
}

create_system_symlinks

echo "Done!"
echo ""
echo "Next steps:"
echo "  1. Review/edit service files if INSTALL_DIR is not the default:"
echo "     nano /etc/systemd/system/immich-ml.service"
echo "     nano /etc/systemd/system/immich-web.service"
echo "  2. Start services:"
echo "     systemctl daemon-reload"
echo "     systemctl start immich-ml immich-web"
echo "  3. Enable on boot:"
echo "     systemctl enable immich-ml immich-web"
