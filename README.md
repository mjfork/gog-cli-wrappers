# gog-cli-wrappers

Safety wrappers for [gog CLI](https://github.com/skyscrapr/gog) to prevent destructive operations when used by LLM agents.

## Problem

LLM agents with shell access can accidentally (or intentionally) run destructive gog commands like sending emails, deleting files, or posting chat messages.

## Solution

`gog-safe` is a wrapper that:
- Blocks destructive operations (send, delete)
- Restricts uploads to a configured folder
- Allows read-only operations (search, list, get)
- Hides the real gog binary to prevent bypass

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/mjfork/gog-cli-wrappers/main/gog-cli-wrapper-install.sh | bash
```

Or download and review first:
```bash
curl -fsSL -o gog-cli-wrapper-install.sh https://raw.githubusercontent.com/mjfork/gog-cli-wrappers/main/gog-cli-wrapper-install.sh
chmod +x gog-cli-wrapper-install.sh
./gog-cli-wrapper-install.sh
```

## Prerequisites

- `gog` CLI installed and configured
- `sudo` access (to move/protect the binary)
- `jq` installed (for folder name resolution)

## Configuration

After installation, edit `~/.config/gog-safe.conf`:

```bash
# Restrict uploads to specific folder by ID
ALLOWED_UPLOAD_FOLDER_ID=1OnIs7EL3xRxLpj62ShqAUJ_qDT7AohVK

# Or by name (resolved at runtime)
ALLOWED_UPLOAD_FOLDER_NAME=OpenClaw
ALLOWED_UPLOAD_ACCOUNT=twt
```

Environment variables override config:
- `GOG_SAFE_UPLOAD_FOLDER_ID`
- `GOG_SAFE_UPLOAD_FOLDER_NAME`
- `GOG_SAFE_UPLOAD_ACCOUNT`

## What Gets Blocked

| Command | Status |
|---------|--------|
| `gmail send` | Blocked |
| `gmail drafts send` | Blocked |
| `gmail drafts delete` | Blocked |
| `gmail batch delete` | Blocked |
| `drive delete/rm/del` | Blocked |
| `drive upload` | Allowed only to configured folder |
| `chat messages send` | Blocked |
| `chat dm send` | Blocked |
| All read operations | Allowed |

## Usage

After installation, use `gog-safe` instead of `gog`:

```bash
# Read operations - always allowed
gog-safe gmail search 'in:inbox' --account=personal
gog-safe calendar events --today --account=work
gog-safe drive ls --account=personal

# Upload - only to allowed folder
gog-safe drive upload ./file.pdf --parent=1OnIs7EL3xRxLpj62ShqAUJ_qDT7AohVK --account=twt
```

Direct `gog` calls will error:
```
$ gog gmail search 'in:inbox'
error: gog is not available. Use gog-safe for Google Workspace access.
```

Upload to wrong folder will error:
```
$ gog-safe drive upload ./file.pdf --parent=some-other-folder --account=twt
error: drive upload blocked - only allowed to folder 'OpenClaw' (1OnIs7EL3xRxLpj62ShqAUJ_qDT7AohVK)
```

## Security Notes

This provides **practical protection**, not bulletproof security. An agent with sudo access could:
- Find the hidden binary with `find`
- Read the wrapper script to find the path

For stronger isolation, run agents in containers without the real binary.

## License

MIT
