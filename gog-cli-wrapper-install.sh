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

    # Check common locations for original binary
    for path in \
        "/home/ubuntu/gogcli/gogcli/bin/gog" \
        "/home/linuxbrew/.linuxbrew/bin/gog" \
        "/usr/local/bin/gog" \
        "/usr/bin/gog" \
        "$(command -v gog 2>/dev/null || true)"; do
        if [[ -n "$path" && -x "$path" && -f "$path" ]]; then
            # Check it's a binary (ELF magic bytes) not a script
            if head -c 4 "$path" 2>/dev/null | grep -q "ELF"; then
                echo "$path"
                return 0
            fi
        fi
    done

    # Check for already-hidden binaries (reinstall case)
    for dir in "/home/linuxbrew/.linuxbrew/bin" "/usr/local/bin" "/usr/bin"; do
        for path in "$dir"/.gog-*; do
            if [[ -x "$path" && -f "$path" ]]; then
                if head -c 4 "$path" 2>/dev/null | grep -q "ELF"; then
                    echo "$path"
                    return 0
                fi
            fi
        done
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
# Use folder ID or name (name requires runtime lookup via --account)
#
# Examples:
#   ALLOWED_UPLOAD_FOLDER_ID=1abc123def456
#   ALLOWED_UPLOAD_FOLDER_NAME=MyUploadsFolder
#
# Environment variables override config:
#   GOG_SAFE_UPLOAD_FOLDER_ID
#   GOG_SAFE_UPLOAD_FOLDER_NAME

# Folder restriction (uncomment and configure):
#ALLOWED_UPLOAD_FOLDER_ID=your-folder-id-here
#ALLOWED_UPLOAD_FOLDER_NAME=MyUploadsFolder
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
#   - sheets create (auto-moved to allowed folder after creation)
#   - sheets copy/update/append/clear/format (must be in allowed folder)
#   - docs create/copy/write/update (unless in allowed folder)
#   - slides create/copy/write/update (unless in allowed folder)
#   - chat messages send, dm send
#
# Config: ~/.config/gog-safe.conf
# Env overrides: GOG_SAFE_UPLOAD_FOLDER_ID, GOG_SAFE_UPLOAD_FOLDER_NAME

CONFIG_FILE="${HOME}/.config/gog-safe.conf"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Env overrides
ALLOWED_FOLDER_ID="${GOG_SAFE_UPLOAD_FOLDER_ID:-${ALLOWED_UPLOAD_FOLDER_ID:-}}"
ALLOWED_FOLDER_NAME="${GOG_SAFE_UPLOAD_FOLDER_NAME:-${ALLOWED_UPLOAD_FOLDER_NAME:-}}"

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

    # Query Drive for folder by name in My Drive (not shared)
    local result
    result=$("$GOG_BIN" drive ls --account="$account" --json 2>/dev/null | \
        jq -r --arg name "$name" '.files[] | select(.name == $name and .mimeType == "application/vnd.google-apps.folder") | .id' | head -1)

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    return 1
}

# Check if a file is in My Drive (not a shared drive)
# Fails closed - if lookup fails, returns false (not in My Drive)
is_in_my_drive() {
    local file_id="$1"
    local account="$2"

    if [[ -z "$file_id" || -z "$account" ]]; then
        return 1
    fi

    # Get file metadata - capture both output and exit code
    local response
    if ! response=$("$GOG_BIN" drive get "$file_id" --account="$account" --json 2>&1); then
        # API call failed - fail closed
        return 1
    fi

    # Check response isn't empty
    if [[ -z "$response" ]]; then
        return 1
    fi

    # Check for error in response (e.g., file not found)
    if echo "$response" | jq -e 'has("error")' >/dev/null 2>&1; then
        return 1
    fi

    # Get driveId - if null/empty, it's in My Drive (handle both .file.driveId and .driveId)
    local drive_id
    drive_id=$(echo "$response" | jq -r '(.file.driveId // .driveId) // empty' 2>/dev/null)

    # Empty driveId means My Drive
    [[ -z "$drive_id" ]]
}

# Check if a file is in a specific folder
# Fails closed - if lookup fails, returns false
is_in_folder() {
    local file_id="$1"
    local folder_id="$2"
    local account="$3"

    if [[ -z "$file_id" || -z "$folder_id" || -z "$account" ]]; then
        return 1
    fi

    # Get file metadata
    local response
    if ! response=$("$GOG_BIN" drive get "$file_id" --account="$account" --json 2>&1); then
        return 1
    fi

    if [[ -z "$response" ]]; then
        return 1
    fi

    if echo "$response" | jq -e 'has("error")' >/dev/null 2>&1; then
        return 1
    fi

    # Check if folder_id is in parents array (handle both .file.parents and .parents)
    local in_folder
    in_folder=$(echo "$response" | jq -r --arg fid "$folder_id" '(.file.parents // .parents // []) | map(select(. == $fid)) | length' 2>/dev/null)

    [[ "$in_folder" -gt 0 ]]
}

# Resolve folder and validate for docs/slides operations
resolve_and_validate_folder() {
    local account="$1"

    # Resolve allowed folder ID if we only have name
    if [[ -z "$ALLOWED_FOLDER_ID" && -n "$ALLOWED_FOLDER_NAME" ]]; then
        ALLOWED_FOLDER_ID=$(resolve_folder_id "$ALLOWED_FOLDER_NAME" "$account")
    fi

    if [[ -z "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: no allowed folder configured" >&2
        echo "hint: set ALLOWED_UPLOAD_FOLDER_ID or ALLOWED_UPLOAD_FOLDER_NAME in ~/.config/gog-safe.conf" >&2
        return 1
    fi
    return 0
}

# Extract command tokens and flags
# Process ALL arguments - don't break early so we capture --account and --parent
cmd=()
skip_next=0
parent_value=""
account_value=""
prev_flag=""

for arg in "$@"; do
  if (( skip_next )); then
    case "$prev_flag" in
      --parent)  parent_value="$arg" ;;
      --account) account_value="$arg" ;;
    esac
    skip_next=0
    continue
  fi
  case "$arg" in
    --)           break ;;
    --parent=*)   parent_value="${arg#--parent=}" ;;
    --parent)     skip_next=1; prev_flag="--parent" ;;
    --account=*)  account_value="${arg#--account=}" ;;
    --account|-a) skip_next=1; prev_flag="--account" ;;
    --*=*)        continue ;;
    --client|--color|--enable-commands|--name|--sheets|--text|--title)
                  skip_next=1; prev_flag="$arg" ;;
    -*)           continue ;;
    *)            # Only collect first 4 positional args for command matching
                  (( ${#cmd[@]} < 4 )) && cmd+=("$arg") ;;
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
    if [[ -z "$account_value" ]]; then
        echo "error: drive upload requires --account" >&2
        exit 1
    fi

    # Resolve allowed folder ID if we only have name
    if [[ -z "$ALLOWED_FOLDER_ID" && -n "$ALLOWED_FOLDER_NAME" ]]; then
        ALLOWED_FOLDER_ID=$(resolve_folder_id "$ALLOWED_FOLDER_NAME" "$account_value")
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

  # Sheets: create - run then move to allowed folder (sheets API doesn't support --parent)
  sheets:create:*)
    if [[ -z "$account_value" ]]; then
        echo "error: sheets create requires --account" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    # Run create and capture output
    output=$("$GOG_BIN" "$@" --json 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "$output" >&2
        exit $exit_code
    fi

    # Extract spreadsheet ID
    spreadsheet_id=$(echo "$output" | jq -r '.spreadsheetId // .id // empty' 2>/dev/null)

    if [[ -z "$spreadsheet_id" ]]; then
        echo "error: sheets create succeeded but could not extract ID to move file" >&2
        echo "$output"
        exit 1
    fi

    # Move to allowed folder
    if ! "$GOG_BIN" drive move "$spreadsheet_id" --parent="$ALLOWED_FOLDER_ID" --account="$account_value" >/dev/null 2>&1; then
        echo "warning: sheet created but failed to move to allowed folder" >&2
    fi

    echo "$output"
    exit 0
    ;;

  # Sheets: copy only to allowed folder
  sheets:copy:*)
    if [[ -z "$account_value" ]]; then
        echo "error: sheets copy requires --account" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if [[ -z "$parent_value" ]]; then
        echo "error: sheets copy blocked - must specify --parent=$ALLOWED_FOLDER_ID" >&2
        exit 1
    elif [[ "$parent_value" != "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: sheets copy blocked - only allowed to folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Sheets: update/append/clear/format only for files in allowed folder
  sheets:update:*|sheets:append:*|sheets:clear:*|sheets:format:*)
    if [[ -z "$account_value" ]]; then
        echo "error: sheets ${cmd[1]} requires --account" >&2
        exit 1
    fi

    spreadsheet_id="${cmd[2]:-}"
    if [[ -z "$spreadsheet_id" ]]; then
        echo "error: sheets ${cmd[1]} blocked - no spreadsheet ID provided" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if ! is_in_folder "$spreadsheet_id" "$ALLOWED_FOLDER_ID" "$account_value"; then
        echo "error: sheets ${cmd[1]} blocked - file is not in allowed folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Docs: create/copy only to allowed folder
  docs:create:*|docs:copy:*)
    if [[ -z "$account_value" ]]; then
        echo "error: docs ${cmd[1]} requires --account" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if [[ -z "$parent_value" ]]; then
        echo "error: docs ${cmd[1]} blocked - must specify --parent=$ALLOWED_FOLDER_ID" >&2
        exit 1
    elif [[ "$parent_value" != "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: docs ${cmd[1]} blocked - only allowed to folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Docs: write/update only for files in allowed folder
  docs:write:*|docs:update:*)
    if [[ -z "$account_value" ]]; then
        echo "error: docs write requires --account" >&2
        exit 1
    fi

    doc_id="${cmd[2]:-}"
    if [[ -z "$doc_id" ]]; then
        echo "error: docs write blocked - no document ID provided" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if ! is_in_folder "$doc_id" "$ALLOWED_FOLDER_ID" "$account_value"; then
        echo "error: docs write blocked - file is not in allowed folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Slides: create/copy only to allowed folder
  slides:create:*|slides:copy:*)
    if [[ -z "$account_value" ]]; then
        echo "error: slides ${cmd[1]} requires --account" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if [[ -z "$parent_value" ]]; then
        echo "error: slides ${cmd[1]} blocked - must specify --parent=$ALLOWED_FOLDER_ID" >&2
        exit 1
    elif [[ "$parent_value" != "$ALLOWED_FOLDER_ID" ]]; then
        echo "error: slides ${cmd[1]} blocked - only allowed to folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
        exit 1
    fi
    ;;

  # Slides: write/update only for files in allowed folder
  slides:write:*|slides:update:*)
    if [[ -z "$account_value" ]]; then
        echo "error: slides write requires --account" >&2
        exit 1
    fi

    presentation_id="${cmd[2]:-}"
    if [[ -z "$presentation_id" ]]; then
        echo "error: slides write blocked - no presentation ID provided" >&2
        exit 1
    fi

    if ! resolve_and_validate_folder "$account_value"; then
        exit 1
    fi

    if ! is_in_folder "$presentation_id" "$ALLOWED_FOLDER_ID" "$account_value"; then
        echo "error: slides write blocked - file is not in allowed folder '${ALLOWED_FOLDER_NAME:-}' ($ALLOWED_FOLDER_ID)" >&2
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
    echo "  gog-safe sheets get <spreadsheetId> 'Sheet1!A1:D10' --account=<alias>"
    echo
    echo "Blocked:"
    echo "  - Direct 'gog' usage"
    echo "  - gmail send, drafts send/delete"
    echo "  - drive delete/rm/del"
    echo "  - drive upload (except to allowed folder)"
    echo "  - sheets create (auto-moved to allowed folder)"
    echo "  - sheets copy/update/append/clear/format (must be in allowed folder)"
    echo "  - docs create/copy/write/update (must be in allowed folder)"
    echo "  - slides create/copy/write/update (must be in allowed folder)"
    echo "  - chat send"
}

main "$@"
# v1.3.2
