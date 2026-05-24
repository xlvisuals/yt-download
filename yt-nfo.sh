#!/usr/bin/env bash
# yt-nfo.sh -- Generate season.nfo files for Jellyfin in YouTube download folders
#
# Jellyfin's TV Show scanner infers season numbers from playlist_index in video
# info.json files, producing wrong "Season 44" etc. for channels with many playlists.
# This script writes a season.nfo in each playlist subfolder, explicitly setting
# the season number (sequential, based on folder order) and title (folder name).
# Also writes a tvshow.nfo in the channel/series root folder.
#
# Run after downloading a channel, or periodically to pick up new playlists.
# Safe to re-run -- only writes files that are missing or changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=yt-common.sh
source "${SCRIPT_DIR}/yt-common.sh"


# -- Parse arguments --

DRY_RUN=false
FORCE=false
ALL=false
LOG_DIR=""
TARGET_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Generate season.nfo files for Jellyfin in a YouTube channel download folder.

Each playlist subfolder gets a season.nfo with a sequential season number
and the playlist name as the season title. The root folder gets a tvshow.nfo.

Options:
  -n, --dry-run    Show what would be written without doing anything
  -f, --force      Overwrite existing .nfo files
  -a, --all        Process every subfolder in DIR as a separate channel
  -l, --log DIR    Write log to DIR/yt-nfo-TIMESTAMP.log (default: current dir)
  -h, --help       Show this help

Examples:
  $(basename "$0") ~/Videos/BedtimeHistory
  $(basename "$0") --dry-run ~/Videos/ChessKidOfficial
  $(basename "$0") --force ~/Videos/BedtimeHistory
  $(basename "$0") --all ~/Videos
  $(basename "$0") --all .                 # process all channels in current directory
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true;     shift ;;
        -f|--force)   FORCE=true;       shift ;;
        -a|--all)     ALL=true;         shift ;;
        -l|--log)     LOG_DIR="$2";     shift 2 ;;
        -h|--help)    usage 0 ;;
        -*)           echo "Unknown option: $1" >&2; usage 1 ;;
        *)            TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"


# -- Set up logging (after arg parse so --help is fast) --

if [[ -n "$LOG_DIR" ]]; then
    setup_logging "$LOG_DIR" "yt-nfo"
fi


# -- Write or preview a file --

write_file() {  # write_file <path> <content>
    local path="$1" content="$2"
    if [[ -f "$path" && "$FORCE" == false ]]; then
        echo "  SKIP (exists): $(basename "$path") -- use --force to overwrite"
        return
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD WRITE: $path"
        echo "$content" | sed 's/^/    /'
    else
        echo "$content" > "$path"
        echo "  WROTE: $path"
    fi
}


# -- Process one channel folder --

process_channel() {  # process_channel <channel_dir>
    local channel="$1"
    info "Processing: $channel"

    # tvshow.nfo at root -- title derived from folder name
    local show_title show_title_esc tvshow_nfo
    show_title="$(basename "$channel")"
    show_title_esc="$(xml_escape "$show_title")"
    tvshow_nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<tvshow>
  <title>${show_title_esc}</title>
</tvshow>"
    write_file "${channel}/tvshow.nfo" "$tvshow_nfo"

    # season.nfo for each playlist subfolder that contains media.
    # Sort alphabetically for consistent numbering; start at 1
    # (Jellyfin reserves 0 for "Specials").
    local season_num=0
    local found=0
    while IFS= read -r -d '' playlist_dir; do
        if ! has_media_files "$playlist_dir"; then
            echo "  SKIP (no media): $(basename "$playlist_dir")"
            continue
        fi

        (( season_num++ )) || true
        (( found++ )) || true

        local playlist_title playlist_title_esc nfo_path season_nfo
        playlist_title="$(basename "$playlist_dir")"
        playlist_title_esc="$(xml_escape "$playlist_title")"
        nfo_path="${playlist_dir}/season.nfo"
        season_nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<season>
  <title>${playlist_title_esc}</title>
  <seasonnumber>${season_num}</seasonnumber>
</season>"
        echo "Season ${season_num}: ${playlist_title}"
        write_file "$nfo_path" "$season_nfo"
    done < <(find "$channel" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    echo ""
    info "Done. ${found} season(s) processed."
    if [[ "$DRY_RUN" == false && "$found" -gt 0 ]]; then
        info "Refresh your Jellyfin library to apply the new season numbers."
    fi
}


# -- Main --

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be written"

if [[ "$ALL" == true ]]; then
    channels_found=0
    while IFS= read -r -d '' subdir; do
        process_channel "$subdir"
        echo ""
        (( channels_found++ )) || true
    done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ "$channels_found" -eq 0 ]] && die "No subdirectories found in $TARGET_DIR"
    info "All done. $channels_found channel(s) processed."
else
    process_channel "$TARGET_DIR"
fi
