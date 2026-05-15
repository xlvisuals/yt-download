#!/usr/bin/env bash
set -euo pipefail

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
# Requires only bash and standard Unix tools.

# --- Helpers ---
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

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

# --- Parse arguments ---
DRY_RUN=false
FORCE=false
ALL=false
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true;  shift ;;
        -f|--force)   FORCE=true;    shift ;;
        -a|--all)     ALL=true;      shift ;;
        -h|--help)    usage 0 ;;
        -*)           echo "Unknown option: $1" >&2; usage 1 ;;
        *)            TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# --all: run on every subdirectory of TARGET_DIR as a separate channel
if [[ "$ALL" == true ]]; then
    found=0
    while IFS= read -r -d "" subdir; do
        info "Processing channel: $(basename "$subdir")"
        extra_flags=""
        [[ "$DRY_RUN" == true ]] && extra_flags="$extra_flags --dry-run"
        [[ "$FORCE"   == true ]] && extra_flags="$extra_flags --force"
        # shellcheck disable=SC2086
        bash "$0" $extra_flags "$subdir"
        echo ""
        (( found++ )) || true
    done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ "$found" -eq 0 ]] && die "No subdirectories found in $TARGET_DIR"
    exit 0
fi

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be written"
info "Processing: $TARGET_DIR"

# --- Write or preview a file ---
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

# --- Generate tvshow.nfo in the root (channel) folder ---
# Derive the show title from the folder name
show_title="$(basename "$TARGET_DIR")"

tvshow_nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<tvshow>
  <title>${show_title}</title>
</tvshow>"

write_file "${TARGET_DIR}/tvshow.nfo" "$tvshow_nfo"

# --- Generate season.nfo in each playlist subfolder ---
# Sort folders alphabetically for consistent season numbering.
# Season 0 is reserved by Jellyfin for specials, so we start at 1.
season_num=0
found=0

while IFS= read -r -d '' playlist_dir; do
    # Skip if no video files inside -- empty or non-playlist folders
    if ! find "$playlist_dir" -maxdepth 1 \
            \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" -o -name "*.m4a" -o -name "*.mp3" \) \
            -print -quit 2>/dev/null | grep -q .; then
        echo "  SKIP (no media): $(basename "$playlist_dir")"
        continue
    fi

    (( season_num++ )) || true
    (( found++ )) || true

    playlist_title="$(basename "$playlist_dir")"
    nfo_path="${playlist_dir}/season.nfo"

    season_nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<season>
  <title>${playlist_title}</title>
  <seasonnumber>${season_num}</seasonnumber>
</season>"

    echo "Season ${season_num}: ${playlist_title}"
    write_file "$nfo_path" "$season_nfo"

done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

echo ""
info "Done. ${found} season(s) processed."
if [[ "$DRY_RUN" == false && "$found" -gt 0 ]]; then
    info "Refresh your Jellyfin library to apply the new season numbers."
fi
