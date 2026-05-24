#!/usr/bin/env bash
# yt-nfo.sh -- Generate season.nfo and tvshow.nfo files for Jellyfin
#
# Version:   2026-05-25
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# Jellyfin's TV Show scanner infers season numbers from playlist_index in video
# info.json files, producing wrong "Season 44" etc. for channels with many playlists.
# This script writes a season.nfo in each playlist subfolder, explicitly setting
# the season number and title (folder name). Also writes a tvshow.nfo in the root.
#
# Supports both YouTube channel folders and ZDF Mediathek show folders.
# ZDF folders are detected automatically via extractor_key in the .info.json files.
# ZDF structure: ZDF Shows/ -> Checkpoint/ -> Staffel 1/ (one extra level vs YouTube).
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

Generate season.nfo and tvshow.nfo files for Jellyfin.

YouTube: each playlist subfolder gets a season.nfo with a sequential season
number. The root folder gets a tvshow.nfo.

ZDF: detected automatically. The root folder is the category (e.g. ZDF Shows/);
each show subfolder (e.g. Checkpoint/) gets a tvshow.nfo; each Staffel subfolder
gets a season.nfo with the number read from the .info.json metadata.

Options:
  -n, --dry-run    Show what would be written without doing anything
  -f, --force      Overwrite existing .nfo files
  -a, --all        Process every subfolder in DIR as a separate channel/show
  -l, --log DIR    Write log to DIR/yt-nfo-TIMESTAMP.log (default: current dir)
  -h, --help       Show this help

Examples:
  $(basename "$0") ~/Videos/BedtimeHistory
  $(basename "$0") ~/Videos/ZDF\ Shows
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


# -- Helper: detect whether a directory tree contains ZDF downloads --

# Returns 0 (true) if any .info.json in the tree has extractor_key "ZDF"
is_zdf_tree() {  # is_zdf_tree <dir>
    local dir="$1"
    local f
    while IFS= read -r f; do
        if grep -q '"extractor_key": "ZDF"' "$f" 2>/dev/null; then
            return 0
        fi
    done < <(find "$dir" -name "*.info.json" | head -5)
    return 1
}


# -- Process one ZDF show folder (e.g. Checkpoint/) --
# tvshow.nfo title from series field in info.json; season.nfo from Staffel dirs.

process_zdf_show() {  # process_zdf_show <show_dir>
    local show_dir="$1"
    info "Processing ZDF show: $show_dir"

    # Read series name from the first info.json found in the tree
    local series_name
    local _first_json
    _first_json="$(find "$show_dir" -name "*.info.json" | head -1)"
    if [[ -n "$_first_json" ]]; then
        series_name="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('series',''))"             "$_first_json" 2>/dev/null)"
    fi
    [[ -z "$series_name" ]] && series_name="$(basename "$show_dir")"

    # tvshow.nfo
    local show_title_esc tvshow_content
    show_title_esc="$(xml_escape "$series_name")"
    tvshow_content="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<tvshow>
  <title>${show_title_esc}</title>
</tvshow>"
    write_file "${show_dir}/tvshow.nfo" "$tvshow_content"

    # Collect Staffel dirs to detect year-based seasons (needs remapping to ordinals)
    local -a _staffel_nums=()
    local _has_year_season=false
    local staffel_dir
    while IFS= read -r staffel_dir; do
        [[ -d "$staffel_dir" ]] && has_media_files "$staffel_dir" || continue
        local _t; _t="$(basename "$staffel_dir")"
        if [[ "$_t" =~ ^Staffel[[:space:]]+([0-9]+)$ ]]; then
            _staffel_nums+=("${BASH_REMATCH[1]}")
            [[ "${BASH_REMATCH[1]}" -ge 1900 ]] && _has_year_season=true
        fi
    done < <(find "$show_dir" -maxdepth 1 -type d -name "Staffel *" | sort -t" " -k2 -n)

    local -A _staffel_ordinal=()
    if [[ "$_has_year_season" == true && ${#_staffel_nums[@]} -gt 0 ]]; then
        local _o=0
        while IFS= read -r _n; do
            (( _o++ )) || true
            _staffel_ordinal["$_n"]="$_o"
        done < <(printf '%s\n' "${_staffel_nums[@]}" | sort -n)
    fi

    local found=0
    while IFS= read -r staffel_dir; do
        [[ -d "$staffel_dir" ]] || continue
        if ! has_media_files "$staffel_dir"; then
            echo "  SKIP (no media): $(basename "$staffel_dir")"
            continue
        fi

        local staffel_title season_num
        staffel_title="$(basename "$staffel_dir")"
        if [[ "$staffel_title" =~ ^Staffel[[:space:]]+([0-9]+)$ ]]; then
            local _raw="${BASH_REMATCH[1]}"
            if [[ -n "${_staffel_ordinal[$_raw]+x}" ]]; then
                season_num="${_staffel_ordinal[$_raw]}"
            else
                season_num="$_raw"
            fi
        else
            # Unexpected folder name -- fall back to reading season_number from info.json
            local _sj
            _sj="$(find "$staffel_dir" -name "*.info.json" | head -1)"
            if [[ -n "$_sj" ]]; then
                season_num="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('season_number',1))"                     "$_sj" 2>/dev/null)"
            fi
            [[ -z "$season_num" ]] && season_num=1
        fi

        local staffel_esc season_content
        staffel_esc="$(xml_escape "$staffel_title")"
        season_content="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<season>
  <title>${staffel_esc}</title>
  <seasonnumber>${season_num}</seasonnumber>
</season>"
        echo "Season ${season_num}: ${staffel_title}"
        write_file "${staffel_dir}/season.nfo" "$season_content"
        (( found++ )) || true
    done < <(find "$show_dir" -maxdepth 1 -type d -name "Staffel *" | sort -t" " -k2 -n)

    echo ""
    info "Done. ${found} season(s) processed."
}


# -- Process one ZDF category root (e.g. ZDF Shows/) --
# Walks immediate subdirs as show dirs and calls process_zdf_show on each.

process_zdf_category() {  # process_zdf_category <category_dir>
    local category="$1"
    info "Detected ZDF category directory: $category"
    local show_found=0
    while IFS= read -r -d "" show_dir; do
        [[ -d "$show_dir" ]] || continue
        process_zdf_show "$show_dir"
        echo ""
        (( show_found++ )) || true
    done < <(find "$category" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ "$show_found" -gt 0 ]] && info "All done. ${show_found} show(s) processed."
}


# -- Process one YouTube channel folder --
# Channel dir contains playlist subdirs directly; seasons are numbered sequentially.

process_youtube_channel() {  # process_youtube_channel <channel_dir>
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


# -- Dispatcher: detect source and route to the right handler --

process_channel() {  # process_channel <dir>
    local channel="$1"
    if is_zdf_tree "$channel"; then
        if find "$channel" -mindepth 1 -maxdepth 1 -type d -name "Staffel *" | grep -q .; then
            process_zdf_show "$channel"       # pointed at a show dir directly
        else
            process_zdf_category "$channel"   # pointed at a category root
        fi
    else
        process_youtube_channel "$channel"
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
