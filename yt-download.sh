#!/usr/bin/env bash
# yt-download.sh  -  Download YouTube videos / music / playlists

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

# Resolve yt-dlp binary: bundled copy first, then PATH, then download to ~/.local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_BIN=""

if [[ -f "${SCRIPT_DIR}/${BINARY}" ]]; then
    # Bundled -- ensure executable bit is set (zip does not preserve permissions)
    chmod +x "${SCRIPT_DIR}/${BINARY}"
    YTDLP_BIN="${SCRIPT_DIR}/${BINARY}"
elif command -v yt-dlp &>/dev/null; then
    YTDLP_BIN="$(command -v yt-dlp)"
else
    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"
    YTDLP_BIN="${INSTALL_DIR}/${BINARY}"
fi

# Resolve ffmpeg: bundled copy first, then leave empty (yt-dlp will search PATH)
case "$OS" in
    MINGW*|MSYS*|CYGWIN*) FFMPEG_LOCAL="ffmpeg.exe" ;;
    *)                     FFMPEG_LOCAL="ffmpeg" ;;
esac

if [[ -f "${SCRIPT_DIR}/${FFMPEG_LOCAL}" ]]; then
    chmod +x "${SCRIPT_DIR}/${FFMPEG_LOCAL}"
    FFMPEG_BIN="${SCRIPT_DIR}/${FFMPEG_LOCAL}"
fi

# Resolve bundled deno if present
case "$OS" in
    MINGW*|MSYS*|CYGWIN*) DENO_LOCAL="deno.exe" ;;
    *)                     DENO_LOCAL="deno" ;;
esac
DENO_BIN=""
if [[ -f "${SCRIPT_DIR}/${DENO_LOCAL}" ]]; then
    chmod +x "${SCRIPT_DIR}/${DENO_LOCAL}"
    DENO_BIN="${SCRIPT_DIR}/${DENO_LOCAL}"
fi

# On Cygwin/MSYS/MINGW, yt-dlp.exe is a native Windows binary so it needs
# Windows-style paths (C:\...) for its own arguments (e.g. --ffmpeg-location).
# However YTDLP_BIN itself must stay as a Unix path so bash can execute it.
SCRIPT_DIR_WIN=""
if [[ "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]] && command -v cygpath &>/dev/null; then
    SCRIPT_DIR_WIN="$(cygpath -w "$SCRIPT_DIR")"
    # FFMPEG_BIN and DENO_BIN are passed as arguments to yt-dlp.exe -- Windows paths needed
    [[ -n "$FFMPEG_BIN" ]] && FFMPEG_BIN="${SCRIPT_DIR_WIN}\\${FFMPEG_LOCAL}"
    [[ -n "$DENO_BIN" ]]   && DENO_BIN="${SCRIPT_DIR_WIN}\\${DENO_LOCAL}"
    # YTDLP_BIN stays as a Unix/Cygwin path -- bash needs it that way to execute it
fi

# ─────────────────────────────────────────────
# 2. Parse arguments  (order-independent flags)
# ─────────────────────────────────────────────
FORCE_YES=false
DO_UPDATE=false
AUDIO_ONLY=false
JELLYFIN=false
OUTPUT_DIR=""
BASE_URL=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <URL>

Options:
  -y, --yes          Automatically download full playlists without asking
  -u, --update       Update yt-dlp to the latest release before running
  -a, --audio        Download audio only, as MP3
  -j, --jellyfin     Jellyfin-compatible filenames and save info.json sidecar
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
        -j|--jellyfin) JELLYFIN=true; shift ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage 1 ;;
        *)           BASE_URL="$1"; shift ;;
    esac
done

# Allow -u without a URL for update-only mode
if [[ -z "$BASE_URL" ]]; then
    [[ "$DO_UPDATE" == true ]] || usage 1
fi

# -- 3. Check / download yt-dlp --
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
    if [[ -n "$DENO_BIN" && -f "$DENO_BIN" ]]; then
        info "Updating bundled deno at ${DENO_BIN}..."
        if [[ -w "$DENO_BIN" ]]; then
            # deno upgrade replaces itself in-place by default
            "$DENO_BIN" upgrade --output "$DENO_BIN" || true
        else
            info "Cannot update deno: $DENO_BIN is not writable -- skipping"
        fi
    fi

    # If no URL was given, update-only mode -- exit cleanly after updating
    [[ -z "$BASE_URL" ]] && exit 0
fi

# -- 4. Resolve output directory --
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
    OUT_PREFIX="${OUTPUT_DIR}/"
elif [[ "$BASE_URL" == *"/@"* || "$BASE_URL" == */channel/* || "$BASE_URL" == */user/* ]]; then
    # Looks like a channel page -- try to extract the channel name
    CHANNEL_NAME=""

    if [[ "$BASE_URL" == *"/@"* ]]; then
        # /@ChannelName/... -- name is right there in the URL, no extra yt-dlp call needed
        CHANNEL_NAME="$(echo "$BASE_URL" | sed 's|.*/@||; s|/.*||')"
    else
        # /channel/UCxxx or /user/Name -- ask yt-dlp for the uploader name
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
        info "Could not detect channel name -- saving to current directory"
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
    # Likely a single video or direct playlist URL -- proceed with the input as-is
    urls=("$BASE_URL")
fi

rm -f "$stderr_tmp"

[[ ${#urls[@]} -eq 0 || -z "${urls[0]}" ]] && die "No valid URLs found for '$BASE_URL'."


# -- 6. Confirm to proceed if more than one URL --

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

proceed=""
if [[ "$FORCE_YES" == true || ${#urls[@]} -eq 1 ]]; then
    echo "Found ${#urls[@]} url(s)."
    proceed="y"
else
    read_tty proceed "Found ${#urls[@]} urls. Proceed? (y/n): "
fi

if [[ ! "$proceed" =~ ^[yY]$ ]]; then
    echo "Bye"
    exit 0
fi


# -- 7. Process each URL --

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
        "-f" "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
    )
fi

# Pass bundled ffmpeg location to yt-dlp if we found one.
# FFMPEG_BIN is already a Windows path on Cygwin/MSYS/MINGW (converted above).
if [[ -n "$FFMPEG_BIN" ]]; then
    if [[ "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]] && [[ -n "${SCRIPT_DIR_WIN:-}" ]]; then
        # Use the already-converted Windows path directly
        BASE_OPTS+=("--ffmpeg-location" "$SCRIPT_DIR_WIN")
    else
        BASE_OPTS+=("--ffmpeg-location" "$(dirname "$FFMPEG_BIN")")
    fi
fi

# On Windows, guard against the 260-character MAX_PATH limit.
# Read LongPathsEnabled from the registry; only trim if it is not set.
if [[ "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]]; then
    # || true prevents set -e from killing the script if reg query or grep returns non-zero
    LONG_PATHS_ENABLED="$(reg query \
        "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" \
        /v LongPathsEnabled 2>/dev/null \
        | grep -i "LongPathsEnabled" \
        | awk '{print $NF}' || true)"
    if [[ "$LONG_PATHS_ENABLED" != "0x1" ]]; then
        info "Windows long path support not enabled -- trimming filenames to 120 chars"
        info "To enable, run as Administrator:"
        info 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f'
        # 200 chars keeps the [VideoID] intact in Jellyfin filenames
        # while still safely under the 260-char MAX_PATH with typical base paths
        BASE_OPTS+=("--trim-filenames" "200")
    fi
fi

# If a supported JS runtime is available, let yt-dlp use its full default client
# list (which includes JS-dependent clients for best quality).
# Prefer bundled deno, then system deno/node/phantomjs, then fall back to limited clients.
if [[ -n "$DENO_BIN" ]]; then
    info "Using bundled deno for yt-dlp JS support"
    BASE_OPTS+=("--js-runtimes" "deno:${DENO_BIN}")
elif command -v deno &>/dev/null || command -v node &>/dev/null || command -v phantomjs &>/dev/null; then
    JS_RT="$(command -v deno &>/dev/null && echo deno || command -v node &>/dev/null && echo node || echo phantomjs)"
    info "JS runtime found ($JS_RT) -- using default yt-dlp clients"
else
    info "No JS runtime found -- using mweb,ios clients (install deno for best quality)"
    BASE_OPTS+=("--extractor-args" "youtube:player_client=mweb,ios")
fi

# Jellyfin-compatible output template:
# Channel - YYYYMMDD - Title [VideoID].ext
# info.json and thumbnail share the same base name so Jellyfin can match them.
if [[ "$JELLYFIN" == true ]]; then
    JELLYFIN_TEMPLATE="%(channel)s - %(upload_date)s - %(title)s [%(id)s].%(ext)s"
    JELLYFIN_PLAYLIST_TEMPLATE="%(playlist_title)s/%(channel)s - %(upload_date)s - %(title)s [%(id)s].%(ext)s"
    BASE_OPTS+=(
        "--write-info-json"
        "--write-thumbnail"
        "--convert-thumbnails" "jpg"
        "--no-write-playlist-metafiles"  # skip playlist-level info.json/thumbnail (has NA date)
    )
fi

# Avoid .part files -- write directly to final filename
BASE_OPTS+=("--no-part")

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
            read_tty confirm "Download the WHOLE playlist? (y/n): "
        fi

        if [[ "$confirm" =~ ^[yY]$ ]]; then
            OPTS+=("--yes-playlist")
            if [[ "$JELLYFIN" == true ]]; then
                OUT_TEMPLATE="${OUT_PREFIX}${JELLYFIN_PLAYLIST_TEMPLATE}"
            else
                OUT_TEMPLATE="${OUT_PREFIX}%(playlist_title)s/%(playlist_index)03d-%(title)s.%(ext)s"
            fi
        else
            OPTS+=("--no-playlist")
            if [[ "$JELLYFIN" == true ]]; then
                OUT_TEMPLATE="${OUT_PREFIX}${JELLYFIN_TEMPLATE}"
            else
                OUT_TEMPLATE="${OUT_PREFIX}%(title)s.%(ext)s"
            fi
        fi

    elif [[ "$url" == *"list="* ]]; then
        OPTS+=("--yes-playlist")
        if [[ "$JELLYFIN" == true ]]; then
            OUT_TEMPLATE="${OUT_PREFIX}${JELLYFIN_PLAYLIST_TEMPLATE}"
        else
            OUT_TEMPLATE="${OUT_PREFIX}%(playlist_title)s/%(playlist_index)03d-%(title)s.%(ext)s"
        fi

    else
        OPTS+=("--no-playlist")
        if [[ "$JELLYFIN" == true ]]; then
            OUT_TEMPLATE="${OUT_PREFIX}${JELLYFIN_TEMPLATE}"
        else
            OUT_TEMPLATE="${OUT_PREFIX}%(title)s.%(ext)s"
        fi
    fi

    info "Processing: $url"
    "$YTDLP_BIN" "${OPTS[@]}" -o "$OUT_TEMPLATE" "$url"
done
