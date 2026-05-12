#!/usr/bin/env bash
# filenames-sanitise.sh -- Recursively sanitise filenames and folder names
#
# Version:   2026-05-13
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# Applies the same rules as yt-download.sh:
#   - Replace characters forbidden on NTFS/exFAT/APFS/ext4: \ : * ? " < > |
#   - Trim trailing dots or spaces (NTFS rejects these)
# Does NOT replace spaces or force lowercase.

set -euo pipefail

# --- Helpers ---

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Recursively renames files and folders to be safe on Windows, macOS, and Linux.
Replaces forbidden characters with underscores and trims trailing dots/spaces.
Does not rename anything that is already clean.

Options:
  -n, --dry-run    Show what would be renamed without doing anything
  -h, --help       Show this help

Examples:
  $(basename "$0") ~/Downloads/MyChannel
  $(basename "$0") --dry-run .
EOF
    exit "${1:-0}"
}

# --- Sanitise a single name component (not the full path) ---
sanitise() {
    echo "$1" \
        | sed 's/[\\/:*?"<>|]/_/g' \
        | sed 's/[. ]*$//'
}

# --- Argument parsing ---
DRY_RUN=false
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -h|--help)    usage 0 ;;
        -*)           echo "Unknown option: $1" >&2; usage 1 ;;
        *)            TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && usage 1
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."

# Resolve to absolute path so renames don't confuse relative references
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be renamed"
info "Scanning: $TARGET_DIR"

renamed=0
skipped=0

# Process depth-first (deepest paths first) so that renaming a folder doesn't
# invalidate the paths of its children before they are processed.
while IFS= read -r -d '' item; do
    dir="$(dirname "$item")"
    old_name="$(basename "$item")"
    new_name="$(sanitise "$old_name")"

    if [[ "$old_name" == "$new_name" ]]; then
        (( skipped++ )) || true
        continue
    fi

    new_path="${dir}/${new_name}"

    # Guard against collisions -- don't silently overwrite something that already exists
    if [[ -e "$new_path" ]]; then
        echo "SKIP (collision): '$item' -> '$new_path' already exists" >&2
        (( skipped++ )) || true
        continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "WOULD RENAME: '$old_name'  ->  '$new_name'"
        echo "         in: '$dir'"
    else
        mv -- "$item" "$new_path"
        echo "RENAMED: '$old_name'  ->  '$new_name'"
        echo "     in: '$dir'"
    fi

    (( renamed++ )) || true

done < <(
    # -depth ensures children are yielded before their parent directory,
    # so we rename from the inside out.
    # Exclude the root directory itself -- we only rename its contents.
    find "$TARGET_DIR" -depth \( -type f -o -type d \) ! -path "$TARGET_DIR"
)

echo ""
if [[ "$DRY_RUN" == true ]]; then
    info "Done (dry run). Would rename: $renamed  |  Already clean: $skipped"
else
    info "Done. Renamed: $renamed  |  Already clean: $skipped"
fi
