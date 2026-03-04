# gog-cli-wrappers

Safety wrappers for [gog CLI](https://github.com/skyscrapr/gog) to prevent destructive operations when used by LLM agents.

## Problem

LLM agents with shell access can accidentally (or intentionally) run destructive gog commands like sending emails, deleting files, or posting chat messages.

## Solution

`gog-safe` is a wrapper that:
- Blocks destructive operations (send, delete)
- Restricts uploads to a configured folder
- Restricts sheet edits to My Drive only (not shared drives)
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
- `jq` installed (for folder name resolution and My Drive checks)

## Configuration

After installation, edit `~/.config/gog-safe.conf`:

```bash
# Restrict uploads to specific folder by ID
ALLOWED_UPLOAD_FOLDER_ID=your-folder-id-here

# Or by name (resolved at runtime using --account from command)
ALLOWED_UPLOAD_FOLDER_NAME=MyUploadsFolder
```

Environment variables override config:
- `GOG_SAFE_UPLOAD_FOLDER_ID`
- `GOG_SAFE_UPLOAD_FOLDER_NAME`

## What Gets Blocked

| Command | Status |
|---------|--------|
| `gmail send` | Blocked |
| `gmail drafts send` | Blocked |
| `gmail drafts delete` | Blocked |
| `gmail batch delete` | Blocked |
| `drive delete/rm/del` | Blocked |
| `drive upload` | Allowed only to configured folder |
| `sheets update` | Allowed only for files in My Drive |
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
gog-safe sheets get <spreadsheetId> 'Sheet1!A1:D10' --account=personal

# Upload - only to allowed folder
gog-safe drive upload ./file.pdf --parent=<folder-id> --account=myaccount

# Sheets update - only My Drive files (not shared drives)
gog-safe sheets update <spreadsheetId> 'A1' 'value' --account=personal
```

Direct `gog` calls will error:
```
$ gog gmail search 'in:inbox'
error: gog is not available. Use gog-safe for Google Workspace access.
```

Upload to wrong folder will error:
```
$ gog-safe drive upload ./file.pdf --parent=wrong-folder --account=myaccount
error: drive upload blocked - only allowed to folder 'MyUploadsFolder' (<folder-id>)
```

Editing shared drive sheets will error:
```
$ gog-safe sheets update <shared-spreadsheet-id> 'A1' 'value' --account=myaccount
error: sheets update blocked - file is not in My Drive (shared drives not allowed)
```

## Security Notes

This provides **practical protection**, not bulletproof security. An agent with sudo access could:
- Find the hidden binary with `find`
- Read the wrapper script to find the path

For stronger isolation, run agents in containers without the real binary.

## License

MIT
