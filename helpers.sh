#!/usr/bin/env bash
set -euo pipefail

# --- Decide which user should perform git actions ---
set_user_to_run() {
    if [[ -n "${RUN_USER:-}" ]]; then
        USER_TO_RUN="$RUN_USER"
    elif id immich &>/dev/null; then
        USER_TO_RUN="immich"
    else
        USER_TO_RUN="$(id -un)"
    fi
    export USER_TO_RUN
}

# --- Core clone/update logic (no privilege switching) ---
git_checkout_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local ref="${3:-main}"

    mkdir -p "$(dirname "$target_dir")"

    if [[ -d "$target_dir/.git" ]]; then
        echo "🔁 Updating repo at $target_dir..."
        git -C "$target_dir" fetch --tags origin
        git -C "$target_dir" checkout "$ref" || {
            echo "Fetching missing ref '$ref'..."
            git -C "$target_dir" fetch origin "refs/tags/$ref:refs/tags/$ref"
            git -C "$target_dir" checkout -f "$ref"
        }
    else
        echo "🧱 Cloning $repo_url → $target_dir (ref: $ref)..."
        git clone --depth 1 --branch "$ref" "$repo_url" "$target_dir" 2>/dev/null \
            || git clone "$repo_url" "$target_dir"
    fi

    git config --global --add safe.directory "$target_dir"
    echo "✅ Repository ready at $target_dir (user: $(id -un))"
}

# --- Safe wrapper: run as USER_TO_RUN if different from current user ---
safe_git_checkout() {
    set_user_to_run
    local repo_url="$1"
    local target_dir="$2"
    local ref="${3:-main}"

    run_git_ops() {
        set -euo pipefail

        if [[ ! -d "$target_dir/.git" ]]; then
            echo "📥 Cloning $repo_url -> $target_dir"
            git clone "$repo_url" "$target_dir"
        fi

        echo "🔁 Forcing repo at $target_dir to origin/$ref"
        cd "$target_dir"

        git fetch --all --tags

        if git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
            git checkout --detach "$ref"
        else
            git checkout -B "$ref" "origin/$ref"
            git reset --hard "origin/$ref"
        fi

        git clean -fdx

        echo "✅ Repository ready at $target_dir (user: $(id -un))"
    }

    export repo_url target_dir ref
    export -f run_git_ops

    if [[ "$(id -un)" == "$USER_TO_RUN" ]]; then
        run_git_ops
        return
    fi

    if [[ "$(id -un)" != "root" ]]; then
        echo "❌ Cannot switch to $USER_TO_RUN (not root)."
        exit 1
    fi

    echo "Switching to $USER_TO_RUN for git operations..."
    su "$USER_TO_RUN" -s /bin/bash -c "run_git_ops"
}

# --- Library revision tracking ---
REVISION_FILE="${REVISION_FILE:-$HOME/.immich_library_revisions}"

init_revision_tracking() {
    if [[ ! -f "$REVISION_FILE" ]]; then
        touch "$REVISION_FILE"
    fi
}

get_tracked_revision() {
    local library="$1"
    grep "^${library}: " "$REVISION_FILE" 2>/dev/null | awk '{print $2}' || echo ""
}

set_tracked_revision() {
    local library="$1"
    local revision="$2"
    if grep -q "^${library}: " "$REVISION_FILE" 2>/dev/null; then
        sed -i "s/^${library}: .*$/${library}: ${revision}/" "$REVISION_FILE"
    else
        echo "${library}: ${revision}" >> "$REVISION_FILE"
    fi
}

needs_recompile() {
    local library="$1"
    local new_revision="$2"
    local current
    current="$(get_tracked_revision "$library")"
    if [[ "$current" == "$new_revision" ]]; then
        return 1 # No recompile needed
    fi
    return 0 # Recompile needed
}
