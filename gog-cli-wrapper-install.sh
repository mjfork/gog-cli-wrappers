#!/bin/bash
set -euo pipefail

# gog-cli-wrapper-install.sh
# Installs gog-safe wrapper and blocks direct gog access
# For use on VPS where LLM agents have shell access

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Configuration ---
SAFE_BIN_DIR="${HOME}/.local/bin"
HIDDEN_SUFFIX=$(head -c 8 /dev/urandom | xxd -p)

# --- Find gog binary ---
find_gog() {
    local gog_path

    # Check common locations
    for path in \
        "/home/linuxbrew/.linuxbrew/bin/gog" \
        "/usr/local/bin/gog" \
        "/usr/bin/gog" \
        "$(command -v gog 2>/dev/null || true)"; do
        if [[ -n "$path" && -x "$path" && "$(file -b "$path")" == *ELF* ]]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# --- Check if already installed ---
check_existing() {
    if [[ -f "${SAFE_BIN_DIR}/gog-safe" ]]; then
        if grep -q "gog wrapper that blocks destructive" "${SAFE_BIN_DIR}/gog-safe" 2>/dev/null; then
            warn "gog-safe already installed at ${SAFE_BIN_DIR}/gog-safe"
            read -p "Reinstall? [y/N] " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || exit 0
        fi
    fi
}

# --- Main installation ---
main() {
    info "gog-cli-wrapper installer"
    echo

    # Check for root (needed to modify system paths)
    if [[ $EUID -eq 0 ]]; then
        error "Do not run as root. Script will use sudo when needed."
    fi

    # Find gog
    info "Looking for gog binary..."
    GOG_PATH=$(find_gog) || error "gog binary not found. Install gog first."
    info "Found gog at: ${GOG_PATH}"

    GOG_DIR=$(dirname "$GOG_PATH")
    HIDDEN_NAME=".gog-${HIDDEN_SUFFIX}"
    HIDDEN_PATH="${GOG_DIR}/${HIDDEN_NAME}"

    # Check existing installation
    check_existing

    # Create bin directory
    mkdir -p "${SAFE_BIN_DIR}"

    # Check if binary is already hidden (re-running installer)
    if [[ "$(basename "$GOG_PATH")" == .gog-* ]]; then
        info "Binary already hidden, reusing existing location"
        HIDDEN_PATH="$GOG_PATH"
        HIDDEN_NAME=$(basename "$GOG_PATH")
        GOG_DIR=$(dirname "$GOG_PATH")
        # Find original location for blocker
        GOG_PATH="${GOG_DIR}/gog"
    else
        # Rename real binary to hidden name
        info "Moving gog binary to hidden location..."
        sudo mv "$GOG_PATH" "$HIDDEN_PATH" || error "Failed to move gog binary"
        info "Binary moved to: ${HIDDEN_PATH}"
    fi

    # Create gog-safe wrapper
    info "Creating gog-safe wrapper..."
    cat > "${SAFE_BIN_DIR}/gog-safe" << 'WRAPPER_EOF'
#!/bin/bash
# gog wrapper that blocks destructive operations for LLM safety
#
# Blocked operations:
#   - gmail send, drafts send/delete, batch delete
#   - drive delete/rm/del
#   - chat messages send, dm send

# Extract first 3 command tokens, skipping flags and their values
cmd=()
skip_next=0
for arg in "$@"; do
  if (( skip_next )); then skip_next=0; continue; fi
  case "$arg" in
    --)           break ;;
    --*=*)        continue ;;
    --account|--client|--color|--enable-commands)
                  skip_next=1; continue ;;
    -*)           continue ;;
    *)            cmd+=("$arg")
                  (( ${#cmd[@]} >= 3 )) && break ;;
  esac
done

key="${cmd[0]}:${cmd[1]}:${cmd[2]}"
case "$key" in
  gmail:send:*)            echo "error: gmail send blocked" >&2; exit 1 ;;
  gmail:drafts:send)       echo "error: drafts send blocked" >&2; exit 1 ;;
  gmail:drafts:delete)     echo "error: drafts delete blocked" >&2; exit 1 ;;
  gmail:batch:delete)      echo "error: batch delete blocked" >&2; exit 1 ;;
  drive:delete:*|drive:rm:*|drive:del:*)
                           echo "error: drive delete blocked" >&2; exit 1 ;;
  chat:messages:send)      echo "error: chat send blocked" >&2; exit 1 ;;
  chat:dm:send)            echo "error: chat dm send blocked" >&2; exit 1 ;;
esac

# Path components (not stored as single greppable string)
_p="__GOG_DIR__"
_n="__HIDDEN_NAME__"
exec "${_p}/${_n}" "$@"
WRAPPER_EOF

    # Substitute actual paths
    sed -i "s|__GOG_DIR__|${GOG_DIR}|g" "${SAFE_BIN_DIR}/gog-safe"
    sed -i "s|__HIDDEN_NAME__|${HIDDEN_NAME}|g" "${SAFE_BIN_DIR}/gog-safe"
    chmod +x "${SAFE_BIN_DIR}/gog-safe"

    # Create blocker at original gog location
    info "Creating blocker at original gog location..."
    sudo tee "${GOG_DIR}/gog" > /dev/null << 'BLOCKER_EOF'
#!/bin/bash
echo "error: gog is not available. Use gog-safe for Google Workspace access." >&2
exit 1
BLOCKER_EOF
    sudo chmod +x "${GOG_DIR}/gog"

    # Create blocker in user bin dir too
    info "Creating blocker in ${SAFE_BIN_DIR}..."
    cat > "${SAFE_BIN_DIR}/gog" << 'BLOCKER_EOF'
#!/bin/bash
echo "error: gog is not available. Use gog-safe for Google Workspace access." >&2
exit 1
BLOCKER_EOF
    chmod +x "${SAFE_BIN_DIR}/gog"

    # Verify PATH
    echo
    if [[ ":$PATH:" != *":${SAFE_BIN_DIR}:"* ]]; then
        warn "${SAFE_BIN_DIR} is not in PATH"
        warn "Add to ~/.bashrc or ~/.zshrc:"
        echo "  export PATH=\"${SAFE_BIN_DIR}:\$PATH\""
    fi

    # Test
    echo
    info "Testing installation..."
    if "${SAFE_BIN_DIR}/gog-safe" --version &>/dev/null; then
        info "gog-safe works!"
    else
        warn "gog-safe may not be configured (--version failed, but binary exists)"
    fi

    if "${SAFE_BIN_DIR}/gog" 2>&1 | grep -q "Use gog-safe"; then
        info "gog blocker works!"
    else
        error "gog blocker not working"
    fi

    echo
    info "Installation complete!"
    echo
    echo "Usage:"
    echo "  gog-safe gmail search 'in:inbox' --account=<alias>"
    echo "  gog-safe calendar events --today --account=<alias>"
    echo "  gog-safe drive ls --account=<alias>"
    echo
    echo "Direct 'gog' usage is now blocked."
}

main "$@"
