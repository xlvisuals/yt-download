#!/usr/bin/env bash
# yt-download.sh  –  Download YouTube videos / music / playlists

# --- 0. Helpers ---
set -euo pipefail

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

need_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not found. Please install it."
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
                die "curl not found. This is unexpected on macOS — your installation may be damaged." ;;
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

case "$OS" in
    Linux*)
        BINARY=$( [[ "$ARCH" == "aarch64" ]] && echo "yt-dlp_linux_aarch64" || echo "yt-dlp_linux" ) ;;
    Darwin*)
        BINARY="yt-dlp_macos" ;;
    MINGW*|MSYS*|CYGWIN*)
        BINARY=$( [[ "$ARCH" == "aarch64" ]] && echo "yt-dlp_arm64.exe" || echo "yt-dlp.exe" ) ;;
    *)
        die "Unsupported OS: $OS" ;;
esac

# Resolve install directory: prefer a dir already on PATH, otherwise ~/.local/bin
if command -v yt-dlp &>/dev/null; then
    YTDLP_BIN="$(command -v yt-dlp)"
else
    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"
    YTDLP_BIN="${INSTALL_DIR}/${BINARY}"
fi

# -- 2. Parse arguments --
FORCE_YES=false
DO_UPDATE=false
AUDIO_ONLY=false
OUTPUT_DIR=""
BASE_URL=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <URL>

Options:
  -y, --yes          Automatically download full playlists without asking
  -u, --update       Update yt-dlp to the latest release before running
  -o, --output DIR   Save files into DIR  (default: current directory)
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
        -y|--yes)    FORCE_YES=true;  shift ;;
        -u|--update) DO_UPDATE=true;  shift ;;
        -a|--audio)  AUDIO_ONLY=true; shift ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage 1 ;;
        *)           BASE_URL="$1"; shift ;;
    esac
done

[[ -z "$BASE_URL" ]] && usage 1

# -- 3. Check / download yt-dlp --
if [[ ! -x "$YTDLP_BIN" ]]; then
    info "yt-dlp not found. Downloading from GitHub…"
    DL_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/${BINARY}"
    fetch "$DL_URL" "$YTDLP_BIN"
    chmod +x "$YTDLP_BIN"
    info "Saved to $YTDLP_BIN"
fi

if [[ "$DO_UPDATE" == true ]]; then
    info "Updating yt-dlp…"
    "$YTDLP_BIN" -U
fi

# -- 4. Resolve output directory --
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
    OUT_PREFIX="${OUTPUT_DIR}/"
elif [[ "$BASE_URL" == *"/@"* || "$BASE_URL" == */channel/* || "$BASE_URL" == */user/* ]]; then
    # Looks like a channel page — try to extract the channel name
    CHANNEL_NAME=""

    if [[ "$BASE_URL" == *"/@"* ]]; then
        # /@ChannelName/... — name is right there in the URL, no extra yt-dlp call needed
        CHANNEL_NAME="$(echo "$BASE_URL" | sed 's|.*/@||; s|/.*||')"
    else
        # /channel/UCxxx or /user/Name — ask yt-dlp for the uploader name
        info "Detecting channel name..."
        CHANNEL_NAME="$("$YTDLP_BIN" --flat-playlist --playlist-items 1 --print uploader "$BASE_URL" 2>/dev/null | head -1)"
    fi

    if [[ -n "$CHANNEL_NAME" && "$CHANNEL_NAME" != "NA" ]]; then
        # Sanitise: replace only characters forbidden on NTFS/exFAT/APFS/ext4
        # then trim trailing dots or spaces (NTFS rejects those too)
        CHANNEL_NAME="$(echo "$CHANNEL_NAME" | sed 's/[\\/:*?"<>|]/_/g' | sed 's/[. ]*$//')"
        info "Using channel name as output directory: $CHANNEL_NAME"
        mkdir -p "$CHANNEL_NAME" || die "Cannot create output directory: $CHANNEL_NAME"
        OUT_PREFIX="${CHANNEL_NAME}/"
    else
        info "Could not detect channel name — saving to current directory"
        OUT_PREFIX=""
    fi
else
    OUT_PREFIX=""
fi

# -- 5. Fetch playlist list --
# Turns channel page into list of playlist URLs
info "Fetching content from $BASE_URL"

urls=()
stderr_tmp="$(mktemp)"

while IFS= read -r line; do
    [[ -n "$line" ]] && urls+=("$line")
done < <(
    "$YTDLP_BIN" \
        --flat-playlist \
        --print "https://www.youtube.com/playlist?list=%(id)s" \
        "$BASE_URL" 2>"$stderr_tmp"
)

# If nothing came back, check whether it was a real error or just a single video
if [[ ${#urls[@]} -eq 0 ]]; then
    if grep -qi "error\|failed\|unable" "$stderr_tmp" 2>/dev/null; then
        cat "$stderr_tmp" >&2
        rm -f "$stderr_tmp"
        die "yt-dlp reported an error while fetching '$BASE_URL'. Check the URL and your connection."
    fi
    # Likely a single video or direct playlist URL — proceed with the input as-is
    urls=("$BASE_URL")
fi

rm -f "$stderr_tmp"

[[ ${#urls[@]} -eq 0 || -z "${urls[0]}" ]] && die "No valid URLs found for '$BASE_URL'."


# -- 6. Confirm to proceed if more than one URL --

proceed=""
if [[ "$FORCE_YES" == true || ${#urls[@]} -eq 1 ]]; then
	echo "Found ${#urls[@]} urls."
	proceed="y"
else
	read -rp "Found ${#urls[@]} urls. Proceed? (y/n): " proceed
fi

if [[ ! "$proceed" =~ ^[yY]$ ]]; then
	echo "Bye"
	exit 0
fi


# -- 7. Process each URL --

# Common yt-dlp options (array – no word-splitting surprises)
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
        "-f" "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
    )
fi

for url in "${urls[@]}"; do
    OPTS=("${BASE_OPTS[@]}")
    confirm=""

    if [[ "$url" == *"watch?v="* && "$url" == *"list="* ]]; then
        # URL contains both a video ID and a playlist ID
        if [[ "$FORCE_YES" == true ]]; then
            confirm="y"
        else
            echo
            echo "Detected a video+playlist URL: $url"
            read -rp "Download the WHOLE playlist? (y/n): " confirm
        fi

        if [[ "$confirm" =~ ^[yY]$ ]]; then
            OPTS+=("--yes-playlist")
            OUT_TEMPLATE="${OUT_PREFIX}%(playlist_title)s/%(playlist_index)03d-%(title)s.%(ext)s"
        else
            OPTS+=("--no-playlist")
            OUT_TEMPLATE="${OUT_PREFIX}%(title)s.%(ext)s"
        fi

    elif [[ "$url" == *"list="* ]]; then
        OPTS+=("--yes-playlist")
        OUT_TEMPLATE="${OUT_PREFIX}%(playlist_title)s/%(playlist_index)03d-%(title)s.%(ext)s"

    else
        OPTS+=("--no-playlist")
        OUT_TEMPLATE="${OUT_PREFIX}%(title)s.%(ext)s"
    fi

    info "Processing: $url"
    "$YTDLP_BIN" "${OPTS[@]}" -o "$OUT_TEMPLATE" "$url"
done

