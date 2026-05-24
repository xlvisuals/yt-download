#!/usr/bin/env bash
# yt-download.sh -- Download YouTube videos, playlists, and channels
#
# Version:   2026-05-24b
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# DESCRIPTION
#   Downloads YouTube and ZDF Mediathek content using yt-dlp. Handles single
#   videos, playlists, and entire channel/collection libraries. Automatically
#   downloads and manages yt-dlp, ffmpeg, and deno if bundled versions are
#   present in the same directory.
#
# USAGE
#   ./yt-download.sh [options] <URL>
#
# OPTIONS
#   -y, --yes          Download full playlists without prompting
#   -u, --update       Update yt-dlp and deno before running (URL optional)
#   -a, --audio        Download audio only as MP3
#   -s, --sidecar      Save .info.json and thumbnail alongside each video
#   -p, --posters-only Download folder poster images only (no videos)
#   --prefix-index     Prefix playlist index to filename: 001 - Title.mp4
#   --postfix-index    Postfix playlist index to filename: Title - 001.mp4
#   --append-channel   Append channel name to title: Title - Channel.mp4
#   --keep-id          Keep [VideoID] at end of filename
#   -j, --jellyfin     Shortcut for --sidecar --append-channel --keep-id --yes --cleanup --strip-emoji
#   -o, --output DIR   Save files into DIR (default: channel name from URL,
#                      or 'download/' if channel detection fails)
#   -m, --max N        Stop after N videos per playlist (useful for testing)
#   -l, --log DIR      Write log to DIR/yt-download-TIMESTAMP.log (default: current directory)
#   --cleanup          Remove playlist folders with no media files after download
#   --strip-emoji      After download, run yt-strip-emoji.sh to clean folder/file names
#                      and .nfo titles of emoji that Jellyfin renders as tofu boxes
#   -c, --cookies FILE Use a Netscape cookies.txt file for authentication
#   -b, --browser BR   Use cookies from browser (chrome, firefox, safari, edge)
#   -h, --help         Show usage
#
# EXAMPLES
#   ./yt-download.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
#   ./yt-download.sh --yes "https://www.youtube.com/@BedtimeHistory/playlists"
#   ./yt-download.sh --sidecar --yes "https://www.youtube.com/playlist?list=PLxxx"
#   ./yt-download.sh --sidecar --keep-id --append-channel --yes "https://..."
#   ./yt-download.sh -a -y "https://www.youtube.com/playlist?list=PLxxx"
#   ./yt-download.sh --jellyfin "https://www.zdf.de/reportagen/magic-pranks-100"
#   ./yt-download.sh -u
#
# OUTPUT STRUCTURE
#   Single video:           Video Title.mp4
#   Playlist:               Playlist Title/001-Video Title.mp4
#   Channel (no -o):        ChannelName/Playlist Title/001-Video Title.mp4
#   Jellyfin single:        Channel - 20231015 - Video Title [VideoID].mp4
#   Jellyfin playlist:      Playlist Title/Channel - 20231015 - Title [ID].mp4
#   Audio:                  Video Title.mp3
#
# DEPENDENCIES
#   Required:  bash, curl or wget (for initial yt-dlp download only)
#   Bundled:   yt-dlp, ffmpeg, deno (included in release bundles)
#   Optional:  deno or node (for best YouTube format support; auto-detected)
#
# PLATFORMS
#   macOS, Linux, Windows (Git Bash, Cygwin)
#
# NOTES
#   - On Windows, tests long path support by creating a test file. If the OS
#     rejects paths over 260 chars, filenames are trimmed to 200 chars.
#     To enable long paths, run as Administrator:
#     reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem"
#             /v LongPathsEnabled /t REG_DWORD /d 1 /f
#   - Jellyfin mode requires ffmpeg for thumbnail conversion and format merging.
#   - yt-dlp is downloaded automatically to ~/.local/bin if not bundled or on PATH.
#
# =============================================================================

# --- 0. Helpers ---
set -euo pipefail

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

need_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not found. Please install it."
}


# read_tty: prompt the user reliably after a process substitution.
# - /dev/tty works on macOS, Linux, and Cygwin
# - Git Bash (MINGW) has no /dev/tty -- reopen stdin from the console explicitly
read_tty() {   # read_tty <var> <prompt>
    local __var="$1" __prompt="$2" __val
    if [[ -e /dev/tty ]]; then
        read -rp "$__prompt" __val </dev/tty
    elif [[ -e /dev/con ]]; then
        # Git Bash / MINGW: /dev/con is the Windows console device
        read -rp "$__prompt" __val </dev/con
    else
        # Last resort: reopen fd 0 from the controlling terminal
        exec 3<>/dev/stdin
        read -rp "$__prompt" __val <&3
        exec 3>&-
    fi
    printf -v "$__var" "%s" "$__val"
}

# Check available disk space on the given path (in MB)
check_disk_space() {  # check_disk_space <path> <min_mb>
    local path="$1" min_mb="$2"
    # df -Pm: POSIX portable, output in MB; works on macOS, Linux, Git Bash, Cygwin
    local avail_mb device
    avail_mb="$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "$avail_mb" ]]; then
        die "Could not check disk space on '$path' -- is the path accessible?"
    fi
    if [[ "$avail_mb" -lt "$min_mb" ]]; then
        device="$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $1}')"
        die "Disk full on ${device} -- ${avail_mb}MB available, ${min_mb}MB required. Aborting."
    fi
}

# Sanitise a name component for use in filenames
# Replace NTFS-forbidden chars, collapse multiple spaces, trim trailing dots/spaces
sanitise() {
    echo "$1" \
        | sed 's/[\\/:*?"<>|]/_/g' \
        | sed 's/  */ /g' \
        | sed 's/[. ]*$//'
}

# Check whether a directory contains any downloaded media files (top-level only).
has_media_files() {  # has_media_files <dir>
    find "$1" -maxdepth 1 \
        \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \
           -o -name "*.m4a" -o -name "*.mp3" -o -name "*.opus" \) \
        -print -quit 2>/dev/null | grep -q .
}

# Download with curl (preferred) or wget fallback
fetch() {   # fetch <url> <dest>
    if command -v curl &>/dev/null; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget &>/dev/null; then
        wget -qO "$2" "$1"
    else
        case "$OS" in
            Darwin*)
                die "curl not found. This is unexpected on macOS -- your installation may be damaged." ;;
            MINGW*|MSYS*|CYGWIN*)
                die "curl not found. Install Git for Windows or enable curl via Windows Settings → Apps → Optional Features." ;;
            *)
                die "Neither curl nor wget found. Install one:  sudo apt install curl  (or your distro's equivalent)." ;;
        esac
    fi
}


# -- 1. Detect platform and binary name --

OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WINDOWS=false
case "$OS" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;; esac

case "$OS" in
    Linux*)
        BINARY=$( [[ "$ARCH" == "aarch64" ]] && echo "yt-dlp_linux_aarch64" || echo "yt-dlp_linux" ) ;;
    Darwin*)
        BINARY="yt-dlp_macos" ;;
    MINGW*|MSYS*|CYGWIN*)
        BINARY=$( [[ "$ARCH" == "aarch64" ]] && echo "yt-dlp_aarch64.exe" || echo "yt-dlp.exe" ) ;;
    *)
        die "Unsupported OS: $OS" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Look for a bundled binary next to this script. If found, chmod +x (zip does
# not preserve permissions) and echo the path. Otherwise echo nothing.
resolve_bundled() {  # resolve_bundled <filename>
    local path="${SCRIPT_DIR}/$1"
    if [[ -f "$path" ]]; then
        chmod +x "$path"
        echo "$path"
    fi
}

# Resolve yt-dlp binary: bundled copy first, then PATH, then download to ~/.local/bin
YTDLP_BIN="$(resolve_bundled "$BINARY")"
if [[ -z "$YTDLP_BIN" ]]; then
    if command -v yt-dlp &>/dev/null; then
        YTDLP_BIN="$(command -v yt-dlp)"
    else
        INSTALL_DIR="${HOME}/.local/bin"
        mkdir -p "$INSTALL_DIR"
        YTDLP_BIN="${INSTALL_DIR}/${BINARY}"
    fi
fi

# Resolve bundled ffmpeg and deno (empty if not bundled).
# *_LOCAL holds the filename for later Windows-path conversion.
if [[ "$IS_WINDOWS" == true ]]; then
    FFMPEG_LOCAL="ffmpeg.exe"
    DENO_LOCAL="deno.exe"
else
    FFMPEG_LOCAL="ffmpeg"
    DENO_LOCAL="deno"
fi
FFMPEG_BIN="$(resolve_bundled "$FFMPEG_LOCAL")"
DENO_BIN="$(resolve_bundled "$DENO_LOCAL")"

# On Cygwin/MSYS/MINGW, yt-dlp.exe is a native Windows binary so it needs
# Windows-style paths (C:\...) for its own arguments (e.g. --ffmpeg-location).
# However YTDLP_BIN itself must stay as a Unix path so bash can execute it.
SCRIPT_DIR_WIN=""
DENO_BIN_EXEC="$DENO_BIN"  # Cygwin/Unix path for executing deno directly in bash
if [[ "$IS_WINDOWS" == true ]] && command -v cygpath &>/dev/null; then
    SCRIPT_DIR_WIN="$(cygpath -w "$SCRIPT_DIR")"
    # FFMPEG_BIN and DENO_BIN are passed as arguments to yt-dlp.exe -- Windows paths needed
    [[ -n "$FFMPEG_BIN" ]] && FFMPEG_BIN="${SCRIPT_DIR_WIN}\\${FFMPEG_LOCAL}"
    [[ -n "$DENO_BIN" ]]   && DENO_BIN="${SCRIPT_DIR_WIN}\\${DENO_LOCAL}"
    # YTDLP_BIN and DENO_BIN_EXEC stay as Unix/Cygwin paths -- bash needs them to execute
fi


# -- 2. Parse arguments  (order-independent flags) --

FORCE_YES=false
DO_UPDATE=false
AUDIO_ONLY=false
SIDECAR=false
POSTERS_ONLY=false
INDEX_MODE="none"   # none | prefix | postfix
APPEND_CHANNEL=false
KEEP_ID=false
OUTPUT_DIR=""
COOKIES_FROM_BROWSER=""
COOKIES_FILE=""
MAX_DOWNLOADS=""
BASE_URL=""
ENDPOINTS=()
BASE_CHANNEL_URL=""
LOG_DIR=""
CLEANUP=false
STRIP_EMOJI=false
IS_ZDF=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <URL>

Options:
  -y, --yes          Automatically download full playlists without asking
  -u, --update       Update yt-dlp to the latest release before running
  -a, --audio        Download audio only, as MP3
  -s, --sidecar      Save .info.json and thumbnail alongside each video
  -p, --posters-only Download folder poster images only (no video download)
  --prefix-index     Prefix playlist index: 001 - Title.mp4
  --postfix-index    Postfix playlist index: Title - 001.mp4
  --append-channel   Append channel name to title (if not already present)
  --keep-id          Keep [VideoID] at end of filename
  -j, --jellyfin     Shortcut for --sidecar --append-channel --keep-id --yes --cleanup --strip-emoji
  -o, --output DIR   Save files into DIR  (default: channel name, or 'download/' if detection fails)
  -m, --max N        Stop after N videos per playlist (useful for testing)
  -l, --log DIR      Write log to DIR/yt-download-TIMESTAMP.log (default: current dir)
  --cleanup          Remove playlist folders containing no media files after download
  --strip-emoji      After download, run yt-strip-emoji.sh to clean folder/file names
  -c, --cookies FILE Use a cookies.txt file for authentication
  -b, --browser BROWSER  Use cookies from browser (chrome, firefox, safari, edge)
  -h, --help         Show this help

Examples:
  $(basename "$0") https://www.youtube.com/@ChannelName/playlists
  $(basename "$0") --yes https://www.youtube.com/watch?v=ID&list=ID
  $(basename "$0") -y -o ~/Videos "https://www.youtube.com/watch?v=ID&list=ID"
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)            FORCE_YES=true;                                                         shift ;;
        -u|--update)         DO_UPDATE=true;                                                         shift ;;
        -a|--audio)          AUDIO_ONLY=true;                                                        shift ;;
        -s|--sidecar)        SIDECAR=true;                                                           shift ;;
        -p|--posters-only)   POSTERS_ONLY=true;                                                      shift ;;
        -j|--jellyfin)       SIDECAR=true; APPEND_CHANNEL=true; KEEP_ID=true; FORCE_YES=true; CLEANUP=true; STRIP_EMOJI=true; shift ;;
        --prefix-index)      INDEX_MODE="prefix";                                                    shift ;;
        --postfix-index)     INDEX_MODE="postfix";                                                   shift ;;
        --append-channel)    APPEND_CHANNEL=true;                                                    shift ;;
        --keep-id)           KEEP_ID=true;                                                           shift ;;
        --cleanup)           CLEANUP=true;                                                           shift ;;
        --strip-emoji)       STRIP_EMOJI=true;                                                       shift ;;
        -o|--output)         OUTPUT_DIR="$2";                                                        shift 2 ;;
        -m|--max)            MAX_DOWNLOADS="$2";                                                     shift 2 ;;
        -l|--log)            LOG_DIR="$2";                                                           shift 2 ;;
        -c|--cookies)        COOKIES_FILE="$2";                                                      shift 2 ;;
        -b|--browser)        COOKIES_FROM_BROWSER="$2";                                              shift 2 ;;
        -h|--help)           usage 0 ;;
        -*)                  echo "Unknown option: $1" >&2; usage 1 ;;
        *)                   BASE_URL="$1";                                                          shift ;;
    esac
done

# Allow -u without a URL for update-only mode
if [[ -z "$BASE_URL" ]]; then
    [[ "$DO_UPDATE" == true ]] || usage 1
fi


# -- 3. Set up logging --

LOG_DIR="${LOG_DIR:-.}"
mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
LOG_FILE="${LOG_DIR}/yt-download-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to: $LOG_FILE"


# -- 4. Register exit trap for post-download tasks --

_POST_DOWNLOAD_DONE=false
post_download() {
    [[ "$_POST_DOWNLOAD_DONE" == true ]] && return
    _POST_DOWNLOAD_DONE=true
    [[ -z "${OUT_PREFIX:-}" ]] && return
    if [[ "${SIDECAR:-false}" == true ]]; then
        write_nfo_files "$OUT_PREFIX" "${SHOW_TITLE:-}" 2>/dev/null || true
        fetch_posters "$OUT_PREFIX" 2>/dev/null || true
    fi
    if [[ "${STRIP_EMOJI:-false}" == true ]]; then
        strip_emoji 2>/dev/null || true
    fi
}
trap post_download EXIT


# -- 5. Define Functions --

# Fetch playlist and channel poster images for Jellyfin.
# Called from --posters-only mode and after --sidecar downloads.
fetch_posters() {
    local out_prefix="$1"  # e.g. "ChannelName/" or ""

    # ZDF: derive posters from already-downloaded episode thumbnail sidecars.
    # ZDFChannelIE exposes no playlist-level thumbnail, but each episode's .jpg
    # sidecar is already on disk. Use the first episode's thumbnail for each
    # season folder, and the first season's poster for the show folder.
    if [[ "$IS_ZDF" == true ]]; then
        [[ -z "$out_prefix" || ! -d "${out_prefix%/}" ]] && return
        local zdf_root="${out_prefix%/}"
        # Walk show dirs (one level below root, e.g. ZDF Shows/Checkpoint/)
        while IFS= read -r -d "" show_dir; do
            [[ ! -d "$show_dir" ]] && continue
            local first_season_poster=""
            # Walk Staffel dirs inside this show, sorted numerically by staffel number
            while IFS= read -r staffel_dir; do
                [[ ! -d "$staffel_dir" ]] && continue
                local season_poster="${staffel_dir}/poster.jpg"
                if [[ ! -f "$season_poster" ]]; then
                    # Find the first .jpg sidecar (not already named poster.jpg)
                    local first_jpg
                    first_jpg="$(find "$staffel_dir" -maxdepth 1 -name "*.jpg"                         ! -name "poster.jpg" | sort | head -1)"
                    if [[ -n "$first_jpg" ]]; then
                        cp "$first_jpg" "$season_poster"
                        info "Written season poster: $season_poster"
                    fi
                fi
                # Track the poster from the lowest-numbered season for the show folder
                [[ -z "$first_season_poster" && -f "$season_poster" ]]                     && first_season_poster="$season_poster"
            done < <(find "$show_dir" -maxdepth 1 -type d -name "Staffel *"                         | sort -t" " -k2 -n)
            # Copy first-season poster to the show folder
            local show_poster="${show_dir}/poster.jpg"
            if [[ ! -f "$show_poster" && -n "$first_season_poster" ]]; then
                cp "$first_season_poster" "$show_poster"
                info "Written show poster: $show_poster"
            fi
        done < <(find "$zdf_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
        return
    fi

    # Fetch channel-level poster.jpg if we have a channel output directory
    if [[ -n "$out_prefix" ]]; then
        local channel_dir="${out_prefix%/}"
        [[ ! -d "$channel_dir" ]] && return  # skip if channel folder not yet created
        channel_dir="$(cd "$channel_dir" && pwd)"  # absolute path avoids yt-dlp appending channel name
        local channel_poster="${channel_dir}/poster.jpg"
        if [[ ! -f "$channel_poster" ]]; then
            # Only fetch channel poster if BASE_URL is a YouTube channel URL
            if [[ "$BASE_URL" != *"/@"* ]]; then
                info "Skipping channel poster (not a channel URL)"
                return
            fi
            info "Fetching channel poster..."
            local _tmp="${BASE_URL#*/@}"
            local _handle="${_tmp%%/*}"
            local channel_url="https://www.youtube.com/@${_handle}"
            set +e
            "$YTDLP_BIN" \
                "--skip-download" \
                "--write-thumbnail" \
                "--convert-thumbnails" "jpg" \
                "--playlist-items" "0" \
                "--quiet" \
                "-o" "${channel_poster}" \
                "$channel_url" 2>&1
            set -e
            if [[ -f "$channel_poster" ]]; then
                info "Written channel poster: $channel_poster"
            else
                info "Could not fetch channel poster for $channel_url. Attempted to write to '$channel_poster'"
            fi
        else
            info "Channel poster already present at '$channel_poster'."
        fi
    fi

    # Build a map of playlist_title -> playlist_url in one yt-dlp call,
    # then only fetch posters for playlists whose folder already exists locally.
    if [[ -n "$out_prefix" && -d "${out_prefix%/}" ]]; then

        # Build poster fetch opts
        local POSTER_OPTS=(
            "--flat-playlist"
            "--write-thumbnail"
            "--convert-thumbnails" "jpg"
            "--no-overwrites"
            "--no-post-overwrites"
            "--windows-filenames"
            "--no-part"
            "--quiet"
            "--no-warnings"
            "--extractor-args" "youtubetab:skip=authcheck"
            "-o" "thumbnail:"
            "-o" "pl_thumbnail:${out_prefix}%(playlist_title)s/poster.%(ext)s"
        )
        [[ -n "$COOKIES_FILE" ]]         && POSTER_OPTS+=("--cookies" "$COOKIES_FILE")
        [[ -n "$COOKIES_FROM_BROWSER" ]] && POSTER_OPTS+=("--cookies-from-browser" "$COOKIES_FROM_BROWSER")
        if [[ -n "${FFMPEG_BIN:-}" ]]; then
            if [[ -n "${SCRIPT_DIR_WIN:-}" ]]; then
                POSTER_OPTS+=("--ffmpeg-location" "$SCRIPT_DIR_WIN")
            else
                POSTER_OPTS+=("--ffmpeg-location" "$(dirname "$FFMPEG_BIN")")
            fi
        fi
        [[ -n "${DENO_BIN:-}" ]] && POSTER_OPTS+=("--js-runtimes" "deno:${DENO_BIN}")

        info "Building playlist map for posters..."
        local playlist_map
        playlist_map="$("$YTDLP_BIN" \
            --flat-playlist \
            --print "playlist_title=%(title)s ; playlist_url=%(url)s" \
            --quiet --no-warnings \
            "$BASE_URL" 2>/dev/null || true)"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pl_title pl_url
            pl_title="${line#playlist_title=}"
            pl_title="${pl_title% ; playlist_url=*}"
            pl_url="${line##*; playlist_url=}"
            # yt-dlp --windows-filenames replaces | with ｜ (U+FF5C fullwidth).
            # Normalise the title to match the actual folder name on disk.
            local pl_title_fs
            pl_title_fs="$(echo "$pl_title" \
                | sed 's/|/｜/g' \
                | sed 's/[\\/:*?"<>]/_/g' \
                | sed 's/  */ /g' \
                | sed 's/[. ]*$//')"
            local pl_dir="${out_prefix%/}/${pl_title_fs}"
            if [[ ! -d "$pl_dir" ]]; then
                echo "  Skipping $pl_title (playlist not downloaded)"
                continue
            fi
            if [[ -f "${pl_dir}/poster.jpg" ]]; then
                echo "  Skipping $pl_title (poster already downloaded)"
                continue
            fi
            echo "  Fetching poster for '$pl_title': ${pl_dir}/poster.jpg"
            set +e
            "$YTDLP_BIN" "${POSTER_OPTS[@]}" "$pl_url" 2>&1
            set -e
        done <<< "$playlist_map"
    else
        # No out_prefix -- iterate URLs directly
        for url in "${urls[@]}"; do
            info "Fetching poster: $url"
            set +e
            "$YTDLP_BIN" "${POSTER_OPTS[@]}" "$url" 2>&1
            set -e
        done
    fi

}


# Escape special XML characters for safe embedding in NFO file elements.
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</'&lt;'}"
    s="${s//>/'&gt;'}"
    s="${s//'"'/'&quot;'}"
    echo "$s"
}

# Build the output filename template from the naming flags.
# yt-dlp supports %(channel)s, %(title)s, %(id)s, %(playlist_index)s etc.
# We compose a title portion and wrap it with optional index and [id].
# Write tvshow.nfo and season.nfo files for Jellyfin.
# Called once after all downloads complete when --sidecar is set.
#
# If show_title is empty, falls back to the basename of the output directory.
# Use this override when the human-readable channel display name differs from
# the folder name (e.g. user passed -o, or channel name detection succeeded).
write_nfo_files() {  # write_nfo_files <out_prefix> [<show_title>]
    info "Writing .nfo files..."
    local out_prefix="$1"
    local show_title_arg="${2:-}"
    local root_dir="${out_prefix%/}"
    [[ -z "$root_dir" ]] && root_dir="."

    # tvshow.nfo in the root (channel) folder
    local tvshow_nfo="${root_dir}/tvshow.nfo"
    if [[ ! -f "$tvshow_nfo" ]]; then
        local show_title
        if [[ -n "$show_title_arg" ]]; then
            show_title="$show_title_arg"
        else
            show_title="$(basename "$root_dir")"
        fi
        printf '<?xml version="1.0" encoding="utf-8"?>\n<tvshow>\n  <title>%s</title>\n</tvshow>\n' \
            "$(xml_escape "$show_title")" > "$tvshow_nfo"
        echo "Written: $tvshow_nfo"
    fi


    # season.nfo in each playlist subfolder that contains media.
    # For ZDF shows the subfolders are named "Staffel N" where N is either an ordinal
    # (1, 2, 3...) or a year (2023, 2024, 2025...). Jellyfin expects small ordinals in
    # <seasonnumber>, so year-based seasons are remapped to 1, 2, 3... in sort order
    # while keeping the original "Staffel 2025" as the display title.
    # For YouTube (non-Staffel folders) we assign sequentially as before.

    # Pass 1: collect Staffel numbers for all dirs with media to detect year-based seasons
    local -a _staffel_dirs=()
    local -a _staffel_nums=()
    local _has_year_season=false
    while IFS= read -r -d "" playlist_dir; do
        has_media_files "$playlist_dir" || continue
        local _t
        _t="$(basename "$playlist_dir")"
        if [[ "$_t" =~ ^Staffel[[:space:]]+([0-9]+)$ ]]; then
            _staffel_dirs+=("$playlist_dir")
            _staffel_nums+=("${BASH_REMATCH[1]}")
            [[ "${BASH_REMATCH[1]}" -ge 1900 ]] && _has_year_season=true
        fi
    done < <(find "$root_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    # If any Staffel number looks like a year, remap all of them to ordinals (sorted)
    # Build an associative array: raw_number -> ordinal
    local -A _staffel_ordinal=()
    if [[ "$_has_year_season" == true && ${#_staffel_nums[@]} -gt 0 ]]; then
        local _ordinal=0
        # Sort the raw numbers numerically, assign ordinals in that order
        while IFS= read -r _n; do
            (( _ordinal++ )) || true
            _staffel_ordinal["$_n"]="$_ordinal"
        done < <(printf '%s
' "${_staffel_nums[@]}" | sort -n)
    fi

    # Pass 2: write season.nfo for every subdir with media
    local season_num=0
    while IFS= read -r -d "" playlist_dir; do
        has_media_files "$playlist_dir" || continue
        local playlist_title
        playlist_title="$(basename "$playlist_dir")"
        if [[ "$playlist_title" =~ ^Staffel[[:space:]]+([0-9]+)$ ]]; then
            local _raw="${BASH_REMATCH[1]}"
            if [[ -n "${_staffel_ordinal[$_raw]+x}" ]]; then
                season_num="${_staffel_ordinal[$_raw]}"   # year remapped to ordinal
            else
                season_num="$_raw"                        # plain ordinal, use as-is
            fi
        else
            (( season_num++ )) || true                    # YouTube: sequential
        fi
        printf '<?xml version="1.0" encoding="utf-8"?>\n<season>\n  <title>%s</title>\n  <seasonnumber>%d</seasonnumber>\n</season>\n' \
            "$(xml_escape "$playlist_title")" "$season_num" > "${playlist_dir}/season.nfo"
        echo "Written: ${playlist_dir}/season.nfo (Season ${season_num}: ${playlist_title})"
    done < <(find "$root_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

# Run yt-strip-emoji.sh on the output prefix to clean folder/file names
# and .nfo titles. Called from post_download() when --strip-emoji is set.
# Quietly skipped if the script isn't alongside this one.
strip_emoji() {
    local strip_script="${SCRIPT_DIR}/yt-strip-emoji.sh"
    if [[ ! -x "$strip_script" ]]; then
        info "--strip-emoji set but ${strip_script} not found or not executable -- skipping"
        return
    fi
    # Refuse to run on the current working directory -- that would walk every
    # sibling folder the user happens to have here. Only run when we have an
    # explicit output dir (from -o DIR or a detected channel folder).
    if [[ -z "${OUT_PREFIX:-}" ]]; then
        info "--strip-emoji skipped: no explicit output directory (use -o DIR or a /@channel/ URL)"
        return
    fi
    local strip_target="${OUT_PREFIX%/}"
    info "Running yt-strip-emoji.sh on ${strip_target}..."
    "$strip_script" "$strip_target" || info "yt-strip-emoji.sh exited non-zero -- check output above"
}

build_template() {  # build_template <in_playlist: true|false>
    local in_playlist="$1"
    local title_part="%(title)s"

    # Append channel name if requested.
    # %(channel,series)s: use channel for YouTube, fall back to series for ZDF
    # (ZDF videos have no channel but always have a series name).
    # Note: yt-dlp templates cannot check if the channel name is already
    # in the video title, so duplication is possible for videos that include
    # the channel name in their title. Use dejellyfin --append-channel instead
    # if you want deduplication after the fact.
    if [[ "$APPEND_CHANNEL" == true ]]; then
        title_part="${title_part} - %(channel,series)s"
    fi

    # Wrap with index
    local stem
    case "$INDEX_MODE" in
        prefix)  stem="%(playlist_index)03d - ${title_part}" ;;
        postfix) stem="${title_part} - %(playlist_index)03d" ;;
        *)       stem="${title_part}" ;;
    esac

    # Append [VideoID] if requested
    [[ "$KEEP_ID" == true ]] && stem="${stem} [%(id)s]"

    # Prepend playlist folder(s) for playlist downloads.
    # For ZDF: series/Staffel N/ -- season_number is always populated by yt-dlp's
    # ZDF extractor, so this works for both single- and multi-season shows.
    # For YouTube: playlist_title/ with series fallback (no season subfolder).
    if [[ "$in_playlist" == true ]]; then
        if [[ "$IS_ZDF" == true ]]; then
            echo "%(series)s/Staffel %(season_number)s/${stem}.%(ext)s"
        else
            echo "%(playlist_title,series)s/${stem}.%(ext)s"
        fi
    else
        echo "${stem}.%(ext)s"
    fi
}

# Decide whether to treat a URL as a playlist or single video. Echoes
# "playlist" or "video". May prompt the user for ambiguous video+playlist URLs.
classify_url() {  # classify_url <url>
    local url="$1"
    if [[ "$url" == *"watch?v="* && "$url" == *"list="* ]]; then
        local confirm=""
        if [[ "$FORCE_YES" == true ]]; then
            confirm="y"
        else
            read_tty confirm "Detected video+playlist URL. Download WHOLE playlist? (y/n): "
        fi
        [[ "$confirm" =~ ^[yY]$ ]] && echo playlist || echo video
    elif [[ "$url" == *"list="* || "$url" == *"/videos" || "$url" == *"/shorts" ]]; then
        echo playlist
    # ZDF URLs fall into three types:
    #   video  -- matches yt-dlp's ZDFIE patterns (single episode):
    #               /video/... or /play/... paths, or legacy .html suffix
    #   season -- URL has ?staffel=N    (one season, treated as a playlist)
    #   show   -- everything else on zdf.de (all seasons; expanded in section 8)
    # This mirrors exactly how yt-dlp routes ZDF URLs between ZDFIE and ZDFChannelIE.
    elif [[ "$url" == *"zdf.de/"* ]]; then
        local _url_no_qs="${url%%\?*}"
        if [[ "$_url_no_qs" == *"zdf.de/video/"* || \
              "$_url_no_qs" == *"zdf.de/play/"*  || \
              "$_url_no_qs" == *".html" ]]; then
            echo video
        elif [[ "$url" == *"?staffel="* ]]; then
            echo playlist
        else
            echo show
        fi
    else
        echo video
    fi
}

# Run the full download+sidecar process for a given URL list and prefix
# Run the full download+sidecar process for a list of URLs and a prefix.
# Bash 3.2 compatible -- no namerefs. URLs passed as positional args after prefix.
run_download() {  # run_download <out_prefix> <url1> [<url2> ...]
    info "Starting download ..."
    local _prefix="$1"
    shift
    for url in "$@"; do
        OUT_PREFIX="$_prefix"
        OPTS=("${BASE_OPTS[@]}")
        case "$(classify_url "$url")" in
            playlist|show) OPTS+=("--yes-playlist"); OUT_TEMPLATE="${_prefix}$(build_template true)"  ;;
            video)         OPTS+=("--no-playlist");  OUT_TEMPLATE="${_prefix}$(build_template false)" ;;
        esac
        check_dir="${_prefix:-.}"
        check_dir="${check_dir%/}"
        [[ -z "$check_dir" ]] && check_dir="."
        # Fall back to current dir if output dir doesn't exist yet
        [[ ! -d "$check_dir" ]] && check_dir="."
        check_disk_space "$check_dir" 100

        info "Processing: $url"
        local ytdlp_out ytdlp_exit
        ytdlp_out="$(mktemp)"
        set +e
        "$YTDLP_BIN" "${OPTS[@]}" --ignore-errors -o "$OUT_TEMPLATE" "$url" 2>&1 \
            | tee "$ytdlp_out"
        ytdlp_exit="${PIPESTATUS[0]}"
        set -e
        # Exit code 1: some videos skipped (private/unavailable) -- continue
        # Exit code 101: --max-downloads reached -- continue
        # Exit code > 1 and not 101: serious error -- check for auth issues first
        if [[ "$ytdlp_exit" -gt 1 && "$ytdlp_exit" != 101 ]]; then
            if grep -q "cookies are no longer valid" "$ytdlp_out" 2>/dev/null; then
                rm -f "$ytdlp_out"
                die "YouTube authentication failed -- your cookies have expired. Re-export them with -b BROWSER or -c cookies.txt"
            fi
            if grep -q "Sign in to confirm" "$ytdlp_out" 2>/dev/null; then
                rm -f "$ytdlp_out"
                die "YouTube requires sign-in. Use -b BROWSER or -c cookies.txt"
            fi
            rm -f "$ytdlp_out"
            die "yt-dlp exited with error code $ytdlp_exit -- aborting"
        fi
        rm -f "$ytdlp_out"
    done
}


# -- 6. Check / download yt-dlp --

if [[ ! -x "$YTDLP_BIN" ]]; then
    info "yt-dlp not found. Downloading from GitHub..."
    DL_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/${BINARY}"
    fetch "$DL_URL" "$YTDLP_BIN"
    chmod +x "$YTDLP_BIN"
    info "Saved to $YTDLP_BIN"
fi

if [[ "$DO_UPDATE" == true ]]; then
    info "Updating yt-dlp at ${YTDLP_BIN}..."
    if [[ -w "$YTDLP_BIN" ]]; then
        "$YTDLP_BIN" -U
    else
        die "Cannot update: $YTDLP_BIN is not writable. Try running with sudo, or update the bundle manually."
    fi

    # Update bundled deno if present; skip if deno is a system install on PATH
    # (system deno should be updated via its own package manager)
    if [[ -n "$DENO_BIN_EXEC" && -f "$DENO_BIN_EXEC" ]]; then
        info "Updating bundled deno at ${DENO_BIN_EXEC}..."
        if [[ -w "$DENO_BIN_EXEC" ]]; then
            # deno upgrade replaces itself in-place by default
            "$DENO_BIN_EXEC" upgrade --output "$DENO_BIN_EXEC" || true
        else
            info "Cannot update deno: $DENO_BIN_EXEC is not writable -- skipping"
        fi
    fi

    # If no URL was given, update-only mode -- exit cleanly after updating
    [[ -z "$BASE_URL" ]] && exit 0
fi


# -- 7. Resolve output directory --
#
# Priority for naming the output folder:
#   1. -o DIR (explicit user choice -- always wins)
#   2. Channel display name from yt-dlp (e.g. "BBC Earth Kids")
#   3. Channel handle from URL (e.g. "BBCEarthKids" from /@BBCEarthKids/...)
#   4. Fallback to "download/" with a warning -- we never want OUT_PREFIX empty,
#      because --cleanup and --strip-emoji refuse to run on the current directory.
#
# Note: step 2 always runs (even for /@Handle/ URLs) because the display name
# tends to be more readable and matches what users see in Jellyfin.

CHANNEL_NAME=""
URL_HANDLE=""  # fallback for /@Handle/ URLs if yt-dlp can't return a display name
SHOW_TITLE=""  # what to write to tvshow.nfo; defaults to folder basename if empty

if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
    OUT_PREFIX="${OUTPUT_DIR}/"
    # User chose the folder name explicitly -- respect it for the nfo title too
else
    # If this is a /@Handle/ URL, capture the handle as a fallback first
    if [[ "$BASE_URL" == *"/@"* ]]; then
        URL_HANDLE="$(echo "$BASE_URL" | sed 's|.*/@||; s|/.*||')"

        # If URL has no path after the channel handle, prompt for what to download
        if [[ "$BASE_URL" =~ ^https://www\.youtube\.com/@[^/]+/?$ ]]; then
            CHANNEL_HANDLE="${BASE_URL%/}"
            CHANNEL_HANDLE="${CHANNEL_HANDLE##*/}"  # just @Name
            BASE_CHANNEL_URL="${BASE_URL%/}"
            # Build list of endpoints to download
            ENDPOINTS=()
            if [[ "$FORCE_YES" == true ]]; then
                ENDPOINTS=("playlists" "videos" "shorts")
            else
                for endpoint in playlists videos shorts; do
                    read_tty _ans "Download ${endpoint} from ${CHANNEL_HANDLE}? (y/n): "
                    [[ "$_ans" =~ ^[yY]$ ]] && ENDPOINTS+=("$endpoint")
                done
            fi
            [[ ${#ENDPOINTS[@]} -eq 0 ]] && { echo "Nothing selected. Bye."; exit 0; }
            # Set BASE_URL to first endpoint; remaining handled after main loop
            BASE_URL="${BASE_CHANNEL_URL}/${ENDPOINTS[0]}"
            info "Will download: ${ENDPOINTS[*]}"
        fi
    fi

    # For ZDF URLs derive the root folder directly from the URL category segment --
    # e.g. https://www.zdf.de/reportagen/magic-pranks-100 -> "ZDF Reportagen".
    # This must run before the yt-dlp metadata lookup because playlist_title returns
    # the show name ("Magic Pranks"), which is correct for the subfolder but not the
    # root. The show name reaches the subfolder via %(series)s in the output template.
    if [[ "$BASE_URL" == *"zdf.de/"* ]]; then
        IS_ZDF=true
        _zdf_path="${BASE_URL#*zdf.de/}"  # strip scheme+host
        _zdf_path="${_zdf_path%%\?*}"     # strip query string
        _zdf_path="${_zdf_path%/}"        # strip trailing slash
        _zdf_category="${_zdf_path%%/*}"  # first path segment = category
        _zdf_category_title="$(echo "$_zdf_category" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')"
        CHANNEL_NAME="ZDF ${_zdf_category_title}"
        SHOW_TITLE="$CHANNEL_NAME"
        CHANNEL_NAME="$(sanitise "$CHANNEL_NAME")"
        info "Output directory from ZDF URL category: $CHANNEL_NAME"
    else
        # For YouTube and others, ask yt-dlp for the channel/uploader display name.
        info "Detecting channel name from URL metadata..."
        CHANNEL_NAME="$("$YTDLP_BIN" --flat-playlist --playlist-items 1 --print uploader "$BASE_URL" 2>/dev/null | head -1)"

        if [[ -n "$CHANNEL_NAME" && "$CHANNEL_NAME" != "NA" ]]; then
            SHOW_TITLE="$CHANNEL_NAME"
            CHANNEL_NAME="$(sanitise "$CHANNEL_NAME")"
            info "Using channel display name as output directory: $CHANNEL_NAME"
        elif [[ -n "$URL_HANDLE" ]]; then
            CHANNEL_NAME="$(sanitise "$URL_HANDLE")"
            info "Could not detect channel display name -- using URL handle: $CHANNEL_NAME"
        else
            CHANNEL_NAME="download"
            info "WARNING: Could not detect channel name -- using fallback 'download/'"
            info "         (use -o DIR to pick a specific output directory)"
        fi
    fi
    mkdir -p "$CHANNEL_NAME" || die "Cannot create output directory: $CHANNEL_NAME"
    OUT_PREFIX="${CHANNEL_NAME}/"
fi


# -- 8. Fetch playlist list --

# For channel pages, expand into individual playlist URLs.
# For direct playlist or video URLs, use as-is -- the flat-playlist
# expansion would incorrectly treat video IDs as playlist IDs.
info "Fetching content from $BASE_URL"

urls=()

if [[ "$BASE_URL" == *"youtube.com/playlist?list="* || \
      "$BASE_URL" == *"youtube.com/watch?"* || \
      "$BASE_URL" == *"youtu.be/"* || \
      "$BASE_URL" == *"/@"*"/videos" || \
      "$BASE_URL" == *"/@"*"/shorts" ]] || \
   [[ "$IS_ZDF" == true && ( "$BASE_URL" == *"?staffel="* || \
                              "$BASE_URL" == *"zdf.de/video/"* || \
                              "$BASE_URL" == *"zdf.de/play/"* || \
                              "$BASE_URL" == *".html" ) ]]; then
    # Direct playlist, video, /videos or /shorts URL -- use as-is, no expansion needed.
    # For ZDF: ?staffel= (single season) and individual video URLs are also used as-is.
    urls=("$BASE_URL")

elif [[ "$IS_ZDF" == true && "$BASE_URL" != *"?staffel="* && "$BASE_URL" != *"/play/"* ]]; then
    # ZDF show URL (no ?staffel, no /play/) -- discover all seasons.
    # yt-dlp's ZDFChannelIE fetches ALL seasons from the GraphQL API when no
    # ?staffel is given, so --flat-playlist returns episodes from every season,
    # each tagged with season_number. We collect the unique season_number values
    # and construct ?staffel=N URLs (one per season) so each season is downloaded
    # as its own playlist with the correct Staffel N subfolder.
    info "Discovering seasons for $BASE_URL ..."
    _show_base="${BASE_URL%%\?*}"  # strip any stray query string
    stderr_tmp="$(mktemp)"
    declare -A _seen_seasons=()
    while IFS= read -r _snum; do
        [[ -z "$_snum" || "$_snum" == "NA" ]] && continue
        if [[ -z "${_seen_seasons[$_snum]+x}" ]]; then
            _seen_seasons["$_snum"]=1
            urls+=("${_show_base}?staffel=${_snum}")
        fi
    done < <(
        "$YTDLP_BIN" \
            --flat-playlist \
            --print "%(season_number)s" \
            "$BASE_URL" 2>"$stderr_tmp"
    )

    if [[ ${#urls[@]} -eq 0 ]]; then
        if grep -qi "error\|failed\|unable" "$stderr_tmp" 2>/dev/null; then
            cat "$stderr_tmp" >&2
            rm -f "$stderr_tmp"
            die "yt-dlp reported an error while fetching '$BASE_URL'. Check the URL and your connection."
        fi
        # No seasons found -- fall back to the show URL directly
        info "Could not enumerate seasons -- downloading show URL directly"
        urls=("$BASE_URL")
    fi
    rm -f "$stderr_tmp"

    # Sort season URLs numerically by their staffel= value so they are presented
    # and downloaded in chronological order
    IFS=$'\n' urls=($(printf '%s\n' "${urls[@]}" | sort -t= -k2 -n)); unset IFS

else
    # YouTube channel page or other -- expand into individual playlist URLs.
    if [[ "$BASE_URL" == *"youtube.com"* || "$BASE_URL" == *"youtu.be"* ]]; then
        _url_print_template="https://www.youtube.com/playlist?list=%(id)s"
    else
        _url_print_template="%(url)s"
    fi

    stderr_tmp="$(mktemp)"
    while IFS= read -r line; do
        [[ -n "$line" ]] && urls+=("$line")
    done < <(
        "$YTDLP_BIN" \
            --flat-playlist \
            --print "$_url_print_template" \
            "$BASE_URL" 2>"$stderr_tmp"
    )

    if [[ ${#urls[@]} -eq 0 ]]; then
        if grep -qi "error\|failed\|unable" "$stderr_tmp" 2>/dev/null; then
            cat "$stderr_tmp" >&2
            rm -f "$stderr_tmp"
            die "yt-dlp reported an error while fetching '$BASE_URL'. Check the URL and your connection."
        fi
        urls=("$BASE_URL")
    fi
    rm -f "$stderr_tmp"
fi

[[ ${#urls[@]} -eq 0 || -z "${urls[0]}" ]] && die "No valid URLs found for '$BASE_URL'."


# -- 9. Confirm to proceed if more than one URL --

proceed=""
if [[ "$FORCE_YES" == true || ${#urls[@]} -eq 1 ]]; then
    echo "Found ${#urls[@]} url(s)."
    proceed="y"
else
    read_tty proceed "Found ${#urls[@]} urls. Proceed? (y/n): "
fi

if [[ ! "$proceed" =~ ^[yY]$ ]]; then
    _POST_DOWNLOAD_DONE=true  # suppress exit trap -- nothing was downloaded
    echo "Bye"
    exit 0
fi


# -- 10. Handle Download posters only --

# --posters-only mode: completely independent — build its own opts and skip
# all other flag processing (naming, sidecar, audio, format selection etc.)
if [[ "$POSTERS_ONLY" == true ]]; then
    fetch_posters "$OUT_PREFIX"
    info "Done fetching posters"
    exit 0
fi


# -- 11. Build video download options --

# Common yt-dlp options (array - no word-splitting surprises)
if [[ "$AUDIO_ONLY" == true ]]; then
    BASE_OPTS=(
        "--windows-filenames"
        "-x"
        "--audio-format" "mp3"
        "--audio-quality" "0"
    )
else
    BASE_OPTS=(
        "--write-subs"
        "--sub-lang" "en"
        "--convert-subs" "srt"
        "--embed-subs"
        "--windows-filenames"
        # Format selector tries in order:
        # 1. YouTube: best mp4 video + m4a audio merged by ffmpeg (split streams)
        # 2. ZDF / other muxed sources: best mp4 HLS at 1080p (~950MB/24min)
        #    To save space, swap height<=1080 for height<=720 (~450MB/24min, 720p)
        # 3. Any mp4, then anything as last resort
        "-f" "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4][height<=1080]/best[ext=mp4]/best"
    )
fi

# Pass bundled ffmpeg location to yt-dlp if we found one.
# FFMPEG_BIN is already a Windows path on Cygwin/MSYS/MINGW (converted above).
if [[ -n "$FFMPEG_BIN" ]]; then
    if [[ "$IS_WINDOWS" == true ]] && [[ -n "${SCRIPT_DIR_WIN:-}" ]]; then
        # Use the already-converted Windows path directly
        BASE_OPTS+=("--ffmpeg-location" "$SCRIPT_DIR_WIN")
    else
        BASE_OPTS+=("--ffmpeg-location" "$(dirname "$FFMPEG_BIN")")
    fi
fi

# On Windows, test whether long path support is active by actually trying to
# create a file with a path longer than 260 characters. This is more reliable
# than reading the registry, which may not reflect reality until after a reboot.
if [[ "$IS_WINDOWS" == true ]]; then
    LONG_PATH_OK=false
    test_dir="$(mktemp -d 2>/dev/null || echo "")"
    if [[ -n "$test_dir" ]]; then
        # Build a filename that exceeds 260 chars on its own
        long_name="$(printf '%0.s x' {1..140} | tr -d ' ')"
        if touch "${test_dir}/${long_name}" 2>/dev/null; then
            LONG_PATH_OK=true
            rm -f "${test_dir}/${long_name}"
        fi
        rmdir "$test_dir" 2>/dev/null || true
    fi
    if [[ "$LONG_PATH_OK" == false ]]; then
        info "Windows long path support not enabled -- trimming filenames to 200 chars"
        info "To enable, run as Administrator:"
        info 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f'
        # 200 chars keeps the [VideoID] intact in Jellyfin filenames
        # while still safely under the 260-char MAX_PATH with typical base paths
        BASE_OPTS+=("--trim-filenames" "200")
    fi
fi

# Cookies for authenticated access
if [[ -n "$COOKIES_FILE" ]]; then
    [[ -f "$COOKIES_FILE" ]] || die "Cookies file not found: $COOKIES_FILE"
    BASE_OPTS+=("--cookies" "$COOKIES_FILE")
elif [[ -n "$COOKIES_FROM_BROWSER" ]]; then
    BASE_OPTS+=("--cookies-from-browser" "$COOKIES_FROM_BROWSER")
fi

# If a supported JS runtime is available, let yt-dlp use its full default client
# list (which includes JS-dependent clients for best quality).
# Prefer bundled deno, then system deno/node/phantomjs, then fall back to limited clients.
if [[ -n "$DENO_BIN_EXEC" ]]; then
    info "Using bundled deno for yt-dlp JS support"
    BASE_OPTS+=("--js-runtimes" "deno:${DENO_BIN}")
elif command -v deno &>/dev/null || command -v node &>/dev/null || command -v phantomjs &>/dev/null; then
    if   command -v deno      &>/dev/null; then JS_RT=deno
    elif command -v node      &>/dev/null; then JS_RT=node
    else                                        JS_RT=phantomjs
    fi
    info "JS runtime found ($JS_RT) -- using default yt-dlp clients"
else
    info "No JS runtime found -- using mweb,ios clients (install deno for best quality)"
    BASE_OPTS+=("--extractor-args" "youtube:player_client=mweb,ios")
fi

# Jellyfin-compatible output template:
# --sidecar: save .info.json and thumbnail alongside each video,
# plus poster.jpg in each playlist/channel folder for Jellyfin series/season images
if [[ "$SIDECAR" == true ]]; then
    BASE_OPTS+=(
        "--write-info-json"
        "--write-thumbnail"
        "--convert-thumbnails" "jpg"
        "--no-write-playlist-metafiles"
        "--no-overwrites"
    )
fi

# Avoid .part files -- write directly to final filename
BASE_OPTS+=("--no-part")

# Suppress download progress bars in output (cleaner logs)
BASE_OPTS+=("--no-progress")

# Skip files that already exist
BASE_OPTS+=("--no-overwrites")

# Limit downloads per playlist if requested (useful for testing)
[[ -n "$MAX_DOWNLOADS" ]] && BASE_OPTS+=("--max-downloads" "$MAX_DOWNLOADS")


# -- 12. Run main download --

run_download "$OUT_PREFIX" "${urls[@]}"

# If a bare channel URL was given, process remaining endpoints
if [[ -n "${ENDPOINTS[*]+x}" && ${#ENDPOINTS[@]} -gt 1 ]]; then
    for endpoint in "${ENDPOINTS[@]:1}"; do
        ep_url="${BASE_CHANNEL_URL}/${endpoint}"
        info "Fetching content from $ep_url"
        run_download "$OUT_PREFIX" "$ep_url"
    done
fi


# -- 13. Cleanup: remove playlist folders with no media files and under size threshold --

# IMPORTANT: cleanup only runs when we have an explicit output directory.
# Running cleanup against the current working directory is dangerous -- it would
# scan any sibling channel folders the user happens to have in cwd, and could
# delete them if they're under the size threshold. This guard prevents that
# for bare playlist URLs (no -o, no /@channel/), where OUT_PREFIX is empty.
if [[ "$CLEANUP" == true && -n "$OUT_PREFIX" ]]; then
    info "Running cleanup -- removing folders with no media files (must be < 2MB)..."
    cleanup_dir="${OUT_PREFIX%/}"
    [[ -z "$cleanup_dir" ]] && cleanup_dir="."
    CLEANUP_SIZE_LIMIT=2097152  # 2MB in bytes -- safety net against accidental deletion
    removed=0
    while IFS= read -r -d "" dir; do
        [[ ! -d "$dir" ]] && continue
        # Safety check: skip if folder exceeds size limit OR if size couldn't be determined.
        # An empty/failed du output means we don't know the size, so we MUST NOT delete.
        dir_size="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')"
        if [[ -z "$dir_size" || ! "$dir_size" =~ ^[0-9]+$ ]]; then
            info "Skipping (could not determine size): $dir"
            continue
        fi
        if [[ "$dir_size" -ge "$CLEANUP_SIZE_LIMIT" ]]; then
            continue
        fi
        # Check for any media files
        if ! has_media_files "$dir"; then
            info "Removing folder (no media, $(numfmt --to=iec "$dir_size" 2>/dev/null || echo "${dir_size}B")): $dir"
            rm -rf "$dir"
            (( removed++ )) || true
        fi
    done < <(find "$cleanup_dir" -mindepth 1 -maxdepth 2 -type d -print0 | sort -rz)
    info "Cleanup done. Removed $removed folder(s)."
elif [[ "$CLEANUP" == true ]]; then
    info "Cleanup skipped: no explicit output directory (use -o DIR or a /@channel/ URL to enable cleanup)"
fi

# -- 14. Run post-download tasks (nfo files + posters + strip emoji) --

# Also called by the exit trap on error, so always runs.
post_download
