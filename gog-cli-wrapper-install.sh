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
CONFIG_FILE="${HOME}/.config/gog-safe.conf"
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

    # Create directories
    mkdir -p "${SAFE_BIN_DIR}"
    mkdir -p "$(dirname "$CONFIG_FILE")"

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

    # Create config file if it doesn't exist
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "Creating config file at ${CONFIG_FILE}..."
        cat > "$CONFIG_FILE" << 'CONFIG_EOF'
# gog-safe configuration
#
# Restrict drive uploads to specific folder(s)
# Use folder ID or name (name requires runtime lookup)
#
# Examples:
#   ALLOWED_UPLOAD_FOLDER_ID=1OnIs7EL3xRxLpj62ShqAUJ_qDT7AohVK
#   ALLOWED_UPLOAD_FOLDER_NAME=OpenClaw
#   ALLOWED_UPLOAD_ACCOUNT=twt
#
# Environment variables override config:
#   GOG_SAFE_UPLOAD_FOLDER_ID
#   GOG_SAFE_UPLOAD_FOLDER_NAME
#   GOG_SAFE_UPLOAD_ACCOUNT

# Folder restriction (uncomment and configure):
#ALLOWED_UPLOAD_FOLDER_ID=your-folder-id-here
#ALLOWED_UPLOAD_FOLDER_NAME=MyUploadsFolder
#ALLOWED_UPLOAD_ACCOUNT=myaccount
CONFIG_EOF
    else
        info "Config file exists at ${CONFIG_FILE}, keeping existing"
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
#   - drive upload (unless to allowed folder)
#   - chat messages send, dm send
#
# Config: ~/.config/gog-safe.conf
# Env overrides: GOG_SAFE_UPLOAD_FOLDER_ID, GOG_SAFE_UPLOAD_FOLDER_NAME, GOG_SAFE_UPLOAD_ACCOUNT

CONFIG_FILE="${HOME}/.config/gog-safe.conf"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Env overrides
ALLOWED_FOLDER_ID="${GOG_SAFE_UPLOAD_FOLDER_ID:-${ALLOWED_UPLOAD_FOLDER_ID:-}}"
ALLOWED_FOLDER_NAME="${GOG_SAFE_UPLOAD_FOLDER_NAME:-${ALLOWED_UPLOAD_FOLDER_NAME:-}}"
ALLOWED_ACCOUNT="${GOG_SAFE_UPLOAD_ACCOUNT:-${ALLOWED_UPLOAD_ACCOUNT:-}}"

# Path components (not stored as single greppable string)
_p="__GOG_DIR__"
_n="__HIDDEN_NAME__"
GOG_BIN="${_p}/${_n}"

# Resolve folder name to ID at runtime
resolve_folder_id() {
    local name="$1"
    local account="$2"

    if [[ -z "$name" || -z "$account" ]]; then
        return 1
    fi

    # Query Drive for folder by name
    local result
    result=$("$GOG_BIN" drive ls --account="$account" --json 2>/dev/null | \
        jq -r --arg name "$name" '.files[] | select(.name == $name and .mimeType == "application/vnd.google-apps.folder") | .id' | head -1)

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    return 1
}

# Extract command tokens and flags
cmd=()
skip_next=0
parent_value=""
account_value=""
for arg in "$@"; do
  if (( skip_next )); then
    if [[ -z "$parent_value" && "$prev_flag" == "--parent" ]]; then
      parent_value="$arg"
    elif [[ -z "$account_value" && "$prev_flag" == "--account" ]]; then
      account_value="$arg"
    fi
    skip_next=0
    continue
  fi
  case "$arg" in
    --)           break ;;
    --parent=*)   parent_value="${arg#--parent=}" ;;
    --parent)     skip_next=1; prev_flag="--parent" ;;
    --account=*)  account_value="${arg#--account=}" ;;
    --account)    skip_next=1; prev_flag="--account" ;;
    --*=*)        continue ;;
    --client|--color|--enable-commands|--name)
                  skip_next=1; prev_flag="$arg" ;;
    -*)           continue ;;
    *)            cmd+=("$arg")
                  (( ${#cmd[@]} >= 3 )) && break ;;
  esac
done

key="${cmd[0]:-}:${cmd[1]:-}:${cmd[2]:-}"
case "$key" in
  # Gmail: block send and delete
  gmail:send:*)            echo "error: gmail send blocked" >&2; exit 1 ;;
  gmail:drafts:send*)      echo "error: drafts send blocked" >&2; exit 1 ;;
  gmail:drafts:delete*)    echo "error: drafts delete blocked" >&2; exit 1 ;;
  gmail:batch:delete*)     echo "error: batch delete blocked" >&2; exit 1 ;;

  # Drive: block delete (aliases: rm, del)
  drive:delete:*|drive:rm:*|drive:del:*)
                           echo "error: drive delete blocked" >&2; exit 1 ;;

  # Drive: upload only to allowed folder
  drive:upload:*)
    # Resolve allowed folder ID if we only have name
    if [[ -z "$ALLOWED_FOLDER_ID" && -n "$ALLOWED_FOLDER_NAME" ]]; then
        lookup_account="${account_value:-$ALLOWED_ACCOUNT}"
        if [[ -z "$lookup_account" ]]; then
            echo "error: drive upload blocked - no account specified for folder lookup" >&2
            exit 1
        fi
        ALLOWED_FOLDER_ID=$(resolve_folder_id "$ALLOWED_FOLDER_NAME" "$lookup_account")
        if [[ -z "$ALLOWED_FOLDER_ID" ]]; then
            echo "error: drive upload blocked - could not find folder '$ALLOWED_FOLDER_NAME'" >&2
            exit 1
        fi
    fi

    if [[ -z "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: drive upload blocked - no allowed folder configured" >&2
        echo "hint: set ALLOWED_UPLOAD_FOLDER_ID or ALLOWED_UPLOAD_FOLDER_NAME in ~/.config/gog-safe.conf" >&2
        exit 1
    fi

    if [[ -z "$parent_value" ]]; then
        echo "error: drive upload blocked - must specify --parent=$ALLOWED_FOLDER_ID" >&2
        exit 1
    elif [[ "$parent_value" != "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: drive upload blocked - only allowed to folder '$ALLOWED_FOLDER_NAME' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Chat: block send
  chat:messages:send*)     echo "error: chat send blocked" >&2; exit 1 ;;
  chat:dm:send*)           echo "error: chat dm send blocked" >&2; exit 1 ;;
esac

exec "$GOG_BIN" "$@"
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
    fi

    echo
    info "Installation complete!"
    echo
    echo "Config: ${CONFIG_FILE}"
    echo
    echo "Usage:"
    echo "  gog-safe gmail search 'in:inbox' --account=<alias>"
    echo "  gog-safe calendar events --today --account=<alias>"
    echo "  gog-safe drive ls --account=<alias>"
    echo "  gog-safe drive upload ./file.pdf --parent=<folder-id> --account=<alias>"
    echo
    echo "Blocked:"
    echo "  - Direct 'gog' usage"
    echo "  - gmail send, drafts send/delete"
    echo "  - drive delete/rm/del"
    echo "  - drive upload (except to configured allowed folder)"
    echo "  - chat send"
}

main "$@"
