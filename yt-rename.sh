#!/usr/bin/env bash
set -euo pipefail

# yt-rename.sh -- Rename YouTube sidecar-style filenames using info.json metadata.
#
# Jellyfin style:  Channel - 20231015 - Some Video Title [VideoID].mp4
# Normal style:    001-Some Video Title.mp4
#
# Reads the companion .info.json sidecar to get the playlist index.
# Requires only bash, grep, and sed -- no Python or other dependencies.
# Part of the yt-download suite.
# Renames all sidecar files (.info.json, .jpg, .webp, .srt) to match.
# Does not change folder structure.

# --- Helpers ---
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }



usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Rename YouTube files downloaded with --sidecar, using metadata from .info.json.
Strips the Channel - Date - prefix, and optionally adds index, channel name,
and VideoID. Renames all sidecar files (.info.json, .jpg, .webp, .srt) together.

Options:
  -n, --dry-run       Show what would be renamed without doing anything
  -a, --all           Process every subfolder in DIR as a separate channel
  --prefix-index      Prefix episode number: 001 - Title.mp4
  --postfix-index     Postfix episode number: Title - 001.mp4
  --keep-id           Keep the [VideoID] at the end of the filename
  --append-channel    Append channel name: Title - Channel [VideoID].mp4
  --jellyfin          Shortcut for --append-channel --keep-id (clears any index flags)
  -h, --help          Show this help

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
        | sed 's/  */ /g' \
        | sed 's/[. ]*$//'
}

# --- Parse arguments ---
DRY_RUN=false
ALL=false
INDEX_MODE="none"   # none | prefix | postfix
KEEP_ID=false
APPEND_CHANNEL=false
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)      DRY_RUN=true;             shift ;;
        -a|--all)          ALL=true;                 shift ;;
        --prefix-index)    INDEX_MODE="prefix";       shift ;;
        --postfix-index)   INDEX_MODE="postfix";      shift ;;
        --keep-id)         KEEP_ID=true;              shift ;;
        --append-channel)  APPEND_CHANNEL=true;       shift ;;
        --jellyfin)        APPEND_CHANNEL=true; KEEP_ID=true; INDEX_MODE="none"; shift ;;
        -h|--help)         usage 0 ;;
        -*)                echo "Unknown option: $1" >&2; usage 1 ;;
        *)                 TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# --all: run on every subdirectory of TARGET_DIR
if [[ "$ALL" == true ]]; then
    found=0
    while IFS= read -r -d "" subdir; do
        info "Processing: $(basename "$subdir")"
        extra_flags=""
        [[ "$DRY_RUN"        == true ]]    && extra_flags="$extra_flags --dry-run"
        [[ "$KEEP_ID"        == true ]]    && extra_flags="$extra_flags --keep-id"
        [[ "$APPEND_CHANNEL" == true ]]    && extra_flags="$extra_flags --append-channel"
        [[ "$INDEX_MODE"     == "prefix" ]] && extra_flags="$extra_flags --prefix-index"
        [[ "$INDEX_MODE"     == "postfix" ]] && extra_flags="$extra_flags --postfix-index"
        # shellcheck disable=SC2086
        bash "$0" $extra_flags "$subdir"
        echo ""
        (( found++ )) || true
    done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ "$found" -eq 0 ]] && die "No subdirectories found in $TARGET_DIR"
    exit 0
fi

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be renamed"
info "Scanning: $TARGET_DIR"

renamed=0
skipped=0
errors=0
current_dir=""

# Process only .info.json files -- they anchor each video's rename
# Using -maxdepth 3 to handle channel/playlist/file nesting without going too deep
while IFS= read -r -d '' json_file; do
    dir="$(dirname "$json_file")"
    json_name="$(basename "$json_file")"

    # Print a header when we enter a new folder
    if [[ "$dir" != "$current_dir" ]]; then
        current_dir="$dir"
        info "Folder: $dir"
    fi

    # Try Jellyfin pattern first: Channel - YYYYMMDD - Title [VideoID].info.json
    # Fall back to clean pattern: Title [VideoID].info.json
    IS_JELLYFIN=false
    if [[ "$json_name" =~ ^(.+)\ -\ ([0-9]{8}|NA)\ -\ (.+)\ \[([A-Za-z0-9_-]+)\]\.info\.json$ ]]; then
        IS_JELLYFIN=true
        video_id="${BASH_REMATCH[4]}"
    elif [[ "$json_name" =~ ^(.+)\ \[([A-Za-z0-9_-]+)\]\.info\.json$ ]]; then
        video_id="${BASH_REMATCH[2]}"
    else
        (( skipped++ )) || true
        continue
    fi

    base_stem="${json_name%.info.json}"   # everything before .info.json

    # Extract playlist index from info.json using grep+sed -- no Python needed
    # playlist_index is always a plain integer so grep is reliable here
    playlist_index="$(grep -o '"playlist_index":[^,}]*' "$json_file" \
        | grep -o '[0-9]*' | head -1 || true)"
    # Also try playlist_autonumber if playlist_index is absent
    if [[ -z "$playlist_index" ]]; then
        playlist_index="$(grep -o '"playlist_autonumber":[^,}]*' "$json_file" \
            | grep -o '[0-9]*' | head -1 || true)"
    fi

    # Read channel name from info.json (used by --append-channel)
    channel_name=""
    if [[ "$APPEND_CHANNEL" == true ]]; then
        channel_name="$(grep -o '"channel": *"[^"]*"' "$json_file" \
            | sed 's/^"channel": *"//;s/"$//' | head -1 || true)"
        # Fall back to uploader if channel is absent
        if [[ -z "$channel_name" ]]; then
            channel_name="$(grep -o '"uploader": *"[^"]*"' "$json_file" \
                | sed 's/^"uploader": *"//;s/"$//' | head -1 || true)"
        fi
        # Sanitise the channel name
        channel_name="$(sanitise "$channel_name")"
    fi

    # Extract title depending on which pattern matched
    if [[ "$IS_JELLYFIN" == true ]]; then
        # Strip "Channel - YYYYMMDD - " prefix and " [VideoID]" suffix
        after_channel="${base_stem#* - }"        # remove "Channel - "
        after_date="${after_channel#* - }"       # remove "YYYYMMDD - " or "NA - "
        title="${after_date% \[${video_id}\]}"  # remove trailing " [VideoID]"
    else
        # Clean format: just strip trailing " [VideoID]"
        title="${base_stem% \[${video_id}\]}"
    fi

    # Sanitise the title
    title="$(sanitise "$title")"

    if [[ -z "$title" ]]; then
        echo "SKIP (could not parse title): $json_name" >&2
        (( errors++ )) || true
        continue
    fi

    # Build the new base name according to INDEX_MODE
    idx_fmt=""
    if [[ -n "$playlist_index" && "$playlist_index" =~ ^[0-9]+$ ]]; then
        idx_fmt="$(printf '%03d' "$playlist_index")"
    fi

    case "$INDEX_MODE" in
        prefix)  [[ -n "$idx_fmt" ]] && new_stem="${idx_fmt} - ${title}" || new_stem="$title" ;;
        postfix) [[ -n "$idx_fmt" ]] && new_stem="${title} - ${idx_fmt}" || new_stem="$title" ;;
        *)       new_stem="$title" ;;
    esac

    # Append channel name if requested and not already present in the title
    # (case-insensitive check to avoid "Some Title - BBC | BBC [id].mp4")
    if [[ "$APPEND_CHANNEL" == true && -n "$channel_name" ]]; then
        title_lower="$(echo "$new_stem" | tr "[:upper:]" "[:lower:]")"
        channel_lower="$(echo "$channel_name" | tr "[:upper:]" "[:lower:]")"
        if [[ "$title_lower" != *"$channel_lower"* ]]; then
            new_stem="${new_stem} - ${channel_name}"
        fi
    fi

    [[ "$KEEP_ID" == true ]] && new_stem="${new_stem} [${video_id}]"

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
