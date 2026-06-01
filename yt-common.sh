# yt-common.sh -- Shared helpers for yt-download.sh, yt-nfo.sh, yt-strip-emoji.sh
# shellcheck shell=bash
#
# Source this from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/yt-common.sh"
#
# This file is sourced, not executed -- do not set -euo pipefail here
# (the caller controls its own shell options).

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

# Logging setup -- redirects stdout/stderr to a tee'd log file
setup_logging() {  # setup_logging <log_dir> <script_name>
    local log_dir="${1:-.}"
    local script_name="$2"
    mkdir -p "$log_dir" || die "Cannot create log directory: $log_dir"
    local log_file="${log_dir}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$log_file") 2>&1
    # Export so callers can redirect noisy stderr (e.g. ffmpeg progress) to
    # the terminal directly, bypassing tee to avoid cluttering the log file.
    export YT_LOG_FILE="$log_file"
    info "Logging to: $log_file"
}

# Check if a directory contains downloaded media files (top-level only).
has_media_files() {  # has_media_files <dir>
    find "$1" -maxdepth 1 \
        \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \
           -o -name "*.m4a" -o -name "*.mp3" -o -name "*.opus" \) \
        -print -quit 2>/dev/null | grep -q .
}

# Escape characters that are special in XML content: & < >
# (single/double quotes are only special inside attribute values, which we don't use)
#
# Bash 5.2+ treats unquoted '&' in the replacement string as the matched text
# (sed-style backreference) when the patsub_replacement shopt is on (default).
# Backslash-escaping it forces a literal '&' across all bash versions.
xml_escape() {  # xml_escape <string>
    local s="$1"
    s="${s//&/\&amp;}"   # MUST be first -- the others insert & themselves
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    echo "$s"
}
