#!/usr/bin/env bash
# yt-strip-emoji.sh -- Strip emoji from folder names, file names, and .nfo titles
#
# Version:   2026-05-25
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# DESCRIPTION
#   Jellyfin renders many Unicode emoji and pictograph characters as tofu boxes
#   in its web UI, even when the underlying filenames are valid UTF-8. This
#   script post-processes a downloaded library to remove those characters from:
#     - Folder names (top-down)
#     - File names
#     - <title> elements inside .nfo files
#
#   When stripping would create a folder name that already exists, the script
#   MERGES the emoji folder into the existing one rather than refusing: files
#   are moved one at a time, skipping any that already exist at the destination
#   with identical contents (deleted from source) or different contents (left
#   in place, warned about). This matches the common case of re-downloading a
#   channel after a previous strip.
#
# USAGE
#   ./yt-strip-emoji.sh [options] <directory>
#
# OPTIONS
#   -n, --dry-run    Show what would change without doing anything
#   -a, --all        Process every subfolder in DIR as a separate channel
#   -l, --log DIR    Write log to DIR/yt-strip-emoji-TIMESTAMP.log
#   -h, --help       Show usage
#
# EXAMPLES
#   ./yt-strip-emoji.sh ~/Videos/BedtimeHistory
#   ./yt-strip-emoji.sh --dry-run ~/Videos/BedtimeHistory
#   ./yt-strip-emoji.sh --all ~/Videos
#
# WHAT GETS STRIPPED
#   Unicode ranges removed: U+1F000-1FFFF (emoji and pictographs),
#   U+2600-27BF (misc symbols + dingbats), U+2B00-2BFF (misc symbols/arrows),
#   U+FE00-FE0F (variation selectors), U+200D (zero-width joiner).
#   CJK characters (Chinese, Japanese, Korean) and accented Latin chars
#   are NOT touched -- those render fine in Jellyfin.
#
# DEPENDENCIES
#   Requires: bash, perl (ships by default on macOS, Linux, Git Bash).
#
# NOTES
#   Safe to re-run -- a folder with no emoji is a no-op.
#   File collisions during merge: identical files deleted from source,
#   different files left in place with a warning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=yt-common.sh
source "${SCRIPT_DIR}/yt-common.sh"

# -- Parse arguments --

DRY_RUN=false
ALL=false
LOG_DIR=""
TARGET_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Strip emoji from folder names, file names, and .nfo titles for Jellyfin.

Options:
  -n, --dry-run    Show what would change without doing anything
  -a, --all        Process every subfolder in DIR as a separate channel
  -l, --log DIR    Write log to DIR/yt-strip-emoji-TIMESTAMP.log
  -h, --help       Show this help

Examples:
  $(basename "$0") ~/Videos/BedtimeHistory
  $(basename "$0") --dry-run ~/Videos/BedtimeHistory
  $(basename "$0") --all ~/Videos
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true;     shift ;;
        -a|--all)     ALL=true;         shift ;;
        -l|--log)     LOG_DIR="$2";     shift 2 ;;
        -h|--help)    usage 0 ;;
        -*)           echo "Unknown option: $1" >&2; usage 1 ;;
        *)            TARGET_DIR="$1";  shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

command -v perl &>/dev/null || die "perl is required but not found."

# -- Set up logging (after arg parse so --help is fast) --

if [[ -n "$LOG_DIR" ]]; then
    setup_logging "$LOG_DIR" "yt-strip-emoji"
fi


# -- Core: strip emoji from a string --
#
# Reads input as a single argument, prints stripped version to stdout.
# Uses perl with explicit UTF-8 I/O so source code stays pure ASCII.
strip_emoji() {  # strip_emoji <string>
    perl -CSDA -e '
        my $s = $ARGV[0];
        $s =~ s/[\x{1F000}-\x{1FFFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE00}-\x{FE0F}\x{200D}]//g;
        $s =~ s/\s+/ /g;
        $s =~ s/^\s+|\s+$//g;
        $s =~ s/[\s\-_.]+$//;
        print $s;
    ' -- "$1"
}


# -- Dry-run-aware action wrapper --
#
# Usage: do_action <label> -- <command> [args...]
# Always prints "<label>" (prefixed with "WOULD: " in dry-run mode);
# executes the command only when not in dry-run mode.
do_action() {  # do_action <label> -- <cmd> [args...]
    local label="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD: $label"
    else
        echo "  $label"
        "$@"
    fi
}


# -- Merge files from src dir into dst dir, removing src if it ends up empty --
#
# Per-file logic:
#   - dst missing the file -> move it over
#   - dst has identical bytes -> delete source
#   - dst has different bytes -> leave both, warn
merge_dir() {  # merge_dir <src> <dst>
    local src="$1" dst="$2"
    local leftover=0

    # Iterate files (any type, including hidden) at top level of src
    while IFS= read -r -d '' src_file; do
        local fname dst_file
        fname="$(basename "$src_file")"
        dst_file="${dst}/${fname}"

        if [[ ! -e "$dst_file" ]]; then
            do_action "move:   $src_file -> $dst_file" -- mv "$src_file" "$dst_file"
        elif cmp -s "$src_file" "$dst_file"; then
            do_action "dedupe: $src_file (identical to dst, removing source)" -- rm "$src_file"
        else
            echo "  WARN:  $src_file differs from $dst_file -- leaving both in place"
            leftover=1
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -not -type d -print0)

    # Also merge subdirectories recursively (rare but possible)
    while IFS= read -r -d '' src_sub; do
        local sub_name dst_sub
        sub_name="$(basename "$src_sub")"
        dst_sub="${dst}/${sub_name}"
        if [[ ! -e "$dst_sub" ]]; then
            do_action "move dir: $src_sub -> $dst_sub" -- mv "$src_sub" "$dst_sub"
        else
            merge_dir "$src_sub" "$dst_sub" || leftover=1
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0)

    # Try to remove the now-empty source directory
    if [[ "$leftover" -eq 0 ]]; then
        # rmdir may fail if the dir isn't actually empty (race, hidden files);
        # tolerate that rather than aborting the whole script
        if [[ "$DRY_RUN" == true ]]; then
            echo "  WOULD: rmdir:  $src"
        else
            echo "  rmdir:  $src"
            rmdir "$src" 2>/dev/null || true
        fi
    else
        echo "  KEEP:  $src (not empty after merge, manual review needed)"
        return 1
    fi
}


# -- Rename a folder, or merge it if the destination already exists --

rename_or_merge_dir() {  # rename_or_merge_dir <src_dir>
    local src="$1"
    local parent base stripped dst
    parent="$(dirname "$src")"
    base="$(basename "$src")"
    stripped="$(strip_emoji "$base")"

    # No change needed
    [[ "$base" == "$stripped" ]] && return 0

    # Stripping produced an empty string -- refuse
    if [[ -z "$stripped" ]]; then
        echo "  SKIP:  $src (would strip to empty name)"
        return 0
    fi

    dst="${parent}/${stripped}"

    if [[ ! -e "$dst" ]]; then
        do_action "rename: $src -> $dst" -- mv "$src" "$dst"
    else
        echo "  MERGE: $src -> $dst (destination exists)"
        merge_dir "$src" "$dst" || true
    fi
}


# -- Rename a file in place --

rename_file() {  # rename_file <path>
    local path="$1"
    local dir base stripped dst
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    stripped="$(strip_emoji "$base")"

    [[ "$base" == "$stripped" ]] && return 0

    if [[ -z "$stripped" ]]; then
        echo "  SKIP:  $path (would strip to empty name)"
        return 0
    fi

    dst="${dir}/${stripped}"

    if [[ ! -e "$dst" ]]; then
        do_action "rename: $path -> $dst" -- mv "$path" "$dst"
    elif cmp -s "$path" "$dst" 2>/dev/null; then
        do_action "dedupe: $path (identical to existing $dst, removing)" -- rm "$path"
    else
        echo "  WARN:  $path -> $dst conflict (different files) -- leaving as-is"
    fi
}


# -- Rewrite <title> inside an .nfo file if it contains stripped chars --
#
# Uses perl for the substitution since it already handles the Unicode logic.
# Touches only the FIRST <title>...</title> (which is the show/season title).
rewrite_nfo() {  # rewrite_nfo <path>
    local path="$1"
    # Read current title via grep + sed (safe ASCII operations on UTF-8 bytes)
    local current stripped
    current="$(perl -CSDA -ne 'if (/<title>(.*?)<\/title>/) { print $1; exit }' "$path")"
    [[ -z "$current" ]] && return 0

    stripped="$(strip_emoji "$current")"
    [[ "$current" == "$stripped" ]] && return 0

    if [[ -z "$stripped" ]]; then
        echo "  SKIP nfo: $path (title would strip to empty)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD: nfo title: $path: '$current' -> '$stripped'"
    else
        echo "  nfo title: $path: '$current' -> '$stripped'"
        # In-place rewrite of the first <title>...</title> only.
        # Pass the new value as ARGV[0] to avoid any shell-escaping issues.
        perl -CSDA -i -pe '
            BEGIN { $new = shift @ARGV; $done = 0 }
            if (!$done && s|<title>.*?</title>|<title>${\ ($new) }</title>|) { $done = 1 }
        ' "$stripped" "$path"
    fi
}


# -- Process one channel folder --

process_channel() {  # process_channel <channel_dir>
    local channel="$1"
    info "Processing: $channel"

    # Pass 1: rename/merge subdirectories (playlist folders), top-down
    while IFS= read -r -d '' dir; do
        rename_or_merge_dir "$dir"
    done < <(find "$channel" -mindepth 1 -maxdepth 2 -type d -print0)

    # Pass 2: rename media files inside the now-renamed tree
    while IFS= read -r -d '' file; do
        rename_file "$file"
    done < <(find "$channel" -mindepth 1 -type f \
                \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \
                   -o -name "*.m4a" -o -name "*.mp3" -o -name "*.opus" \
                   -o -name "*.jpg" -o -name "*.png" -o -name "*.webp" \
                   -o -name "*.srt" -o -name "*.vtt" -o -name "*.info.json" \) \
                -print0)

    # Pass 3: rewrite .nfo titles
    while IFS= read -r -d '' nfo; do
        rewrite_nfo "$nfo"
    done < <(find "$channel" -mindepth 1 -name "*.nfo" -print0)

    # Also rename the channel folder itself if it has emoji.
    # Do this last so all the inner work happens at the original path.
    #
    # In practice this is usually a no-op: YouTube enforces ASCII-only handles
    # (@name, 3-30 chars, [a-zA-Z0-9_]), so channel folders created from a
    # /@handle/... URL never contain emoji. This pass exists for two edge cases:
    #   1. Legacy /channel/UCxxx and /user/Name URLs, where the folder name
    #      comes from yt-dlp's `uploader` field (display name) -- can be emoji.
    #   2. User-supplied -o DIR paths containing emoji.
    rename_or_merge_dir "$channel"
}


# -- Main --

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be written"

if [[ "$ALL" == true ]]; then
    found=0
    while IFS= read -r -d '' subdir; do
        process_channel "$subdir"
        echo ""
        (( found++ )) || true
    done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ "$found" -eq 0 ]] && die "No subdirectories found in $TARGET_DIR"
    info "Done. $found channel(s) processed."
else
    process_channel "$TARGET_DIR"
    info "Done."
fi
