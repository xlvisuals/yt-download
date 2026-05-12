#!/usr/bin/env bash
set -euo pipefail

# filenames-dejellyfin.sh -- Convert Jellyfin-style filenames back to normal playlist style.
#
# Jellyfin style:  Channel - 20231015 - Some Video Title [VideoID].mp4
# Normal style:    001-Some Video Title.mp4
#
# Reads the companion .info.json sidecar to get the playlist index.
# Renames all sidecar files (.info.json, .jpg, .webp, .srt) to match.
# Does not change folder structure.
# Requires python

# --- Helpers ---
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

command -v python3 &>/dev/null || die "python3 is required but not found. Install it and try again."

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Convert Jellyfin-style filenames to normal playlist style.

  Jellyfin: Channel - 20231015 - Some Video Title [VideoID].mp4
  Normal:   001-Some Video Title.mp4

Reads playlist_index from the .info.json sidecar to determine episode number.
Renames all matching sidecar files (.info.json, .jpg, .webp, .srt) together.

Options:
  -n, --dry-run    Show what would be renamed without doing anything
  -h, --help       Show this help

Examples:
  $(basename "$0") ~/Videos/BedtimeHistory
  $(basename "$0") --dry-run .
EOF
    exit "${1:-0}"
}

# --- Sanitise a filename component ---
# Replace NTFS-forbidden chars, trim trailing dots/spaces
sanitise() {
    echo "$1" \
        | sed 's/[\\/:*?"<>|]/_/g' \
        | sed 's/[. ]*$//'
}

# --- Parse arguments ---
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
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be renamed"
info "Scanning: $TARGET_DIR"

renamed=0
skipped=0
errors=0

# Process only .info.json files -- they anchor each video's rename
# Using -maxdepth 3 to handle channel/playlist/file nesting without going too deep
while IFS= read -r -d '' json_file; do
    dir="$(dirname "$json_file")"
    json_name="$(basename "$json_file")"

    # Match Jellyfin pattern: Channel - YYYYMMDD - Title [VideoID].info.json
    # The VideoID is inside square brackets just before the extension
    if [[ ! "$json_name" =~ ^(.+)\ -\ ([0-9]{8}|NA)\ -\ (.+)\ \[([A-Za-z0-9_-]+)\]\.info\.json$ ]]; then
        (( skipped++ )) || true
        continue
    fi

    video_id="${BASH_REMATCH[4]}"
    base_stem="${json_name%.info.json}"   # everything before .info.json

    # Read playlist_index from the json
    # Use python if available for robust JSON parsing, fall back to grep
    playlist_index=""
    if command -v python3 &>/dev/null; then
        playlist_index="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    idx = d.get('playlist_index') or d.get('playlist_autonumber')
    print(int(idx)) if idx is not None else print('')
except Exception:
    print('')
" "$json_file" 2>/dev/null || true)"
    else
        # Fallback: grep for the field
        playlist_index="$(grep -o '"playlist_index": *[0-9]*' "$json_file" \
            | grep -o '[0-9]*$' || true)"
    fi

    # Extract title from the Jellyfin filename using Python for reliability.
    # Pattern: Channel - YYYYMMDD - Title [VideoID]
    # The date anchor (8 digits or NA) lets us split unambiguously even when
    # the channel name itself contains " - ".
    title="$(python3 -c "
import re, sys
stem = sys.argv[1]
m = re.match(r'^.+ - (?:[0-9]{8}|NA) - (.+) \\[[A-Za-z0-9_-]+\\]\$', stem)
print(m.group(1) if m else '')
" "$base_stem" 2>/dev/null || true)"

    # Sanitise the title
    title="$(sanitise "$title")"

    if [[ -z "$title" ]]; then
        echo "SKIP (could not parse title): $json_name" >&2
        (( errors++ )) || true
        continue
    fi

    # Build the new base name
    if [[ -n "$playlist_index" && "$playlist_index" =~ ^[0-9]+$ ]]; then
        new_stem="$(printf '%03d' "$playlist_index")-${title}"
    else
        # No playlist index -- just use the title
        new_stem="$title"
    fi

    # Find all files in the same directory sharing this base stem
    # (same stem = same video ID in the original name)
    # Extensions to handle: .mp4, .mkv, .webm, .m4a, .mp3, .jpg, .webp, .srt, .info.json
    any_renamed=false
    while IFS= read -r -d '' src_file; do
        src_name="$(basename "$src_file")"

        # Extract the extension(s) -- handle double extensions like .info.json
        if [[ "$src_name" == *.info.json ]]; then
            ext=".info.json"
        else
            ext=".${src_name##*.}"
        fi

        new_name="${new_stem}${ext}"
        new_path="${dir}/${new_name}"

        if [[ "$src_name" == "$new_name" ]]; then
            continue  # already correct name
        fi

        if [[ -e "$new_path" && "$new_path" != "$src_file" ]]; then
            echo "SKIP (collision): '$src_name' -> '$new_name' already exists" >&2
            (( errors++ )) || true
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            echo "WOULD RENAME: '$src_name'"
            echo "          -> '$new_name'"
        else
            mv -- "$src_file" "$new_path"
            echo "RENAMED: '$src_name'"
            echo "     ->  '$new_name'"
        fi
        any_renamed=true
        (( renamed++ )) || true

    done < <(find "$dir" -maxdepth 1 -name "*\[${video_id}\]*" -print0 | sort -z)

    if [[ "$any_renamed" == false ]]; then
        (( skipped++ )) || true
    fi

done < <(find "$TARGET_DIR" -name "* \[*\].info.json" -print0 | sort -z)

echo ""
if [[ "$DRY_RUN" == true ]]; then
    info "Done (dry run). Would rename: $renamed  |  Skipped: $skipped  |  Errors: $errors"
else
    info "Done. Renamed: $renamed  |  Skipped: $skipped  |  Errors: $errors"
fi