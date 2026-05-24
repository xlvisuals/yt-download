#!/usr/bin/env bash
# yt-convert.sh -- Re-encode downloaded videos above a bitrate threshold
#
# Version:   2026-05-25
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# Iterates over video files in a directory tree and re-encodes those whose
# video stream bitrate exceeds a threshold. Useful for reducing the size of
# ZDF downloads (5-6 Mbit h.264) to a more manageable size (default 2 Mbit
# HEVC), while leaving already-small YouTube files untouched.
#
# Uses hardware-accelerated encoding when available:
#   macOS        -- VideoToolbox  (hevc_videotoolbox / h264_videotoolbox)
#   Linux/Win    -- NVENC         (hevc_nvenc / h264_nvenc)
#   Fallback     -- software      (libx265 / libx264)
#
# Safe to re-run -- already-converted files are skipped.
# Original files are deleted only after a successful encode and verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=yt-common.sh
source "${SCRIPT_DIR}/yt-common.sh"


# ── Parse arguments ──────────────────────────────────────────────────────────

DRY_RUN=false
ALL=false
CODEC=hevc          # hevc | h264
TARGET_BITRATE="2M"
THRESHOLD_BITS=3000000   # 3 Mbit/s default; overridden by --threshold
LOG_DIR=""
TARGET_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Re-encode video files whose bitrate exceeds a threshold.

Options:
  -n, --dry-run            Show what would be converted without doing anything
  -a, --all                Process every subfolder in DIR as a separate show
  -4, --h264               Output format h.264  (default: HEVC/h.265)
  -5, --h265, --hevc       Output format HEVC/h.265 (default)
  -b, --bitrate RATE       Target bitrate, e.g. 2M or 1500K  (default: 2M)
  -t, --threshold RATE     Only convert files above this bitrate  (default: 3M)
  -l, --log DIR            Write log to DIR/yt-convert-TIMESTAMP.log
  -h, --help               Show this help

Examples:
  $(basename "$0") ~/Videos/ZDF\ Reportagen
  $(basename "$0") --dry-run --threshold 4M ~/Videos
  $(basename "$0") --all --bitrate 1500K ~/Videos
  $(basename "$0") --h264 --bitrate 3M ~/Videos/BedtimeHistory
EOF
    exit "${1:-0}"
}

# Parse a human bitrate string (e.g. "3M", "1500K") to bits/s integer
parse_bitrate() {  # parse_bitrate <rate_string> -> echo bits/s
    local r="${1^^}"   # uppercase
    if [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)G$ ]]; then
        echo "$(python3 -c "print(int(${BASH_REMATCH[1]} * 1_000_000_000))")"
    elif [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)M$ ]]; then
        echo "$(python3 -c "print(int(${BASH_REMATCH[1]} * 1_000_000))")"
    elif [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)K$ ]]; then
        echo "$(python3 -c "print(int(${BASH_REMATCH[1]} * 1_000))")"
    elif [[ "$r" =~ ^[0-9]+$ ]]; then
        echo "$r"
    else
        die "Cannot parse bitrate: '$1' (expected e.g. 3M, 1500K, 500000)"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)           DRY_RUN=true;                         shift ;;
        -a|--all)               ALL=true;                              shift ;;
        -4|--h264)              CODEC=h264;                            shift ;;
        -5|--h265|--hevc)       CODEC=hevc;                            shift ;;
        -b|--bitrate)           TARGET_BITRATE="$2";                   shift 2 ;;
        -t|--threshold)         THRESHOLD_BITS="$(parse_bitrate "$2")"; shift 2 ;;
        -l|--log)               LOG_DIR="$2";                          shift 2 ;;
        -h|--help)              usage 0 ;;
        -*)                     echo "Unknown option: $1" >&2; usage 1 ;;
        *)                      TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Validate target bitrate string (used verbatim in ffmpeg -b:v)
[[ "$TARGET_BITRATE" =~ ^[0-9]+(\.[0-9]+)?[KMG]?$ ]] \
    || die "Invalid target bitrate: '$TARGET_BITRATE'"


# ── Set up logging ────────────────────────────────────────────────────────────

if [[ -n "$LOG_DIR" ]]; then
    setup_logging "$LOG_DIR" "yt-convert"
fi


# ── Locate ffmpeg / ffprobe ───────────────────────────────────────────────────

# Look next to the script first (bundled), then fall back to PATH
find_tool() {  # find_tool <name>
    local name="$1"
    local bundled="${SCRIPT_DIR}/${name}"
    if [[ -x "$bundled" ]]; then
        echo "$bundled"
    elif command -v "$name" &>/dev/null; then
        echo "$(command -v "$name")"
    else
        die "Cannot find '$name'. Install it or place it next to this script."
    fi
}

FFMPEG_BIN="$(find_tool ffmpeg)"
FFPROBE_BIN="$(find_tool ffprobe)"
info "ffmpeg:  $FFMPEG_BIN"
info "ffprobe: $FFPROBE_BIN"


# ── Detect hardware acceleration ──────────────────────────────────────────────

# Returns the best available encoder name for the requested codec.
# Sets HW_ACCEL_FLAGS to any extra input flags needed (e.g. -hwaccel cuda).
HW_ACCEL_FLAGS=()

detect_encoder() {  # detect_encoder <codec: hevc|h264> -> echo encoder_name
    local codec="$1"
    local os; os="$(uname -s)"

    if [[ "$os" == "Darwin" ]]; then
        # macOS VideoToolbox -- available on all Apple Silicon and Intel Macs
        if [[ "$codec" == "hevc" ]]; then
            echo "hevc_videotoolbox"
        else
            echo "h264_videotoolbox"
        fi
        return
    fi

    # Linux / Windows (Git Bash / WSL): try NVENC first, fall back to software
    local nvenc_name
    if [[ "$codec" == "hevc" ]]; then
        nvenc_name="hevc_nvenc"
    else
        nvenc_name="h264_nvenc"
    fi

    # Test whether the NVENC encoder is available in this ffmpeg build
    if "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null | grep -q "$nvenc_name"; then
        HW_ACCEL_FLAGS=("-hwaccel" "cuda" "-hwaccel_output_format" "cuda")
        echo "$nvenc_name"
    else
        info "NVENC not available -- using software encoder"
        if [[ "$codec" == "hevc" ]]; then
            echo "libx265"
        else
            echo "libx264"
        fi
    fi
}

ENCODER="$(detect_encoder "$CODEC")"
info "Encoder: $ENCODER"
[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be converted"


# ── Get video stream bitrate ──────────────────────────────────────────────────

# Returns the video stream bitrate in bits/s, or 0 if it cannot be determined.
# For HLS-remuxed files the container bitrate is unreliable; we prefer the
# stream-level bitrate, falling back to the container overall bitrate.
get_video_bitrate() {  # get_video_bitrate <file> -> echo bits/s
    local file="$1"
    local bitrate

    # Try stream-level bitrate first
    bitrate="$("$FFPROBE_BIN" \
        -v quiet \
        -select_streams v:0 \
        -show_entries stream=bit_rate \
        -of csv=p=0 \
        "$file" 2>/dev/null | head -1)"

    # Fall back to container-level bitrate if stream reports N/A
    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        bitrate="$("$FFPROBE_BIN" \
            -v quiet \
            -show_entries format=bit_rate \
            -of csv=p=0 \
            "$file" 2>/dev/null | head -1)"
    fi

    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        echo 0
    else
        echo "$bitrate"
    fi
}

# Return the video codec name (e.g. "h264", "hevc")
get_video_codec() {  # get_video_codec <file> -> echo codec_name
    "$FFPROBE_BIN" \
        -v quiet \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of csv=p=0 \
        "$1" 2>/dev/null | head -1
}


# ── Convert one file ──────────────────────────────────────────────────────────

# Converts <file> in-place:
#   1. Encode to <file>.converting.mp4
#   2. Verify output with ffprobe
#   3. Replace original with converted file
convert_file() {  # convert_file <file>
    local src="$1"
    local dir; dir="$(dirname "$src")"
    local base; base="$(basename "$src" .mp4)"
    local tmp="${dir}/${base}.converting.mp4"

    local bitrate; bitrate="$(get_video_bitrate "$src")"
    local codec;   codec="$(get_video_codec "$src")"
    local bitrate_mbit
    bitrate_mbit="$(python3 -c "print(f'{${bitrate}/1_000_000:.1f}')" 2>/dev/null || echo "?")"

    # Skip if already at or below threshold
    if [[ "$bitrate" -gt 0 && "$bitrate" -le "$THRESHOLD_BITS" ]]; then
        echo "  SKIP (${bitrate_mbit} Mbit, under threshold): $(basename "$src")"
        return
    fi

    # Skip if already the target codec (and under threshold -- caught above)
    local target_codec_name
    [[ "$CODEC" == "hevc" ]] && target_codec_name="hevc" || target_codec_name="h264"
    if [[ "$codec" == "$target_codec_name" && "$bitrate" -le "$THRESHOLD_BITS" ]]; then
        echo "  SKIP (already ${codec}, ${bitrate_mbit} Mbit): $(basename "$src")"
        return
    fi

    echo "  CONVERT (${codec}, ${bitrate_mbit} Mbit -> ${CODEC} ${TARGET_BITRATE}): $(basename "$src")"

    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    # Clean up any leftover temp file from a previous interrupted run
    [[ -f "$tmp" ]] && rm -f "$tmp"

    local ffmpeg_opts=()
    # Hardware decode flags (empty on macOS/software)
    ffmpeg_opts+=("${HW_ACCEL_FLAGS[@]+"${HW_ACCEL_FLAGS[@]}"}")
    ffmpeg_opts+=(-i "$src")
    # Map ALL streams from the input: all audio tracks, all subtitle tracks,
    # all attachments. Without -map 0, ffmpeg picks only one audio stream
    # and silently drops the rest.
    ffmpeg_opts+=(-map 0)
    # Re-encode video; copy everything else by default.
    # -c copy sets the default for all streams, then we override as needed.
    ffmpeg_opts+=(-c copy)
    ffmpeg_opts+=(-c:v "$ENCODER")
    ffmpeg_opts+=(-b:v "$TARGET_BITRATE")
    # Audio: copy if already mp3/aac/eac3; otherwise convert to aac.
    # Check all audio streams in the file -- if any need conversion, use -c:a aac
    # for all (mixing codecs per-stream in MP4 is fragile).
    local audio_codecs
    audio_codecs="$("$FFPROBE_BIN"         -v quiet         -select_streams a         -show_entries stream=codec_name         -of csv=p=0         "$src" 2>/dev/null)"
    local needs_audio_convert=false
    while IFS= read -r acodec; do
        [[ -z "$acodec" ]] && continue
        case "$acodec" in
            mp3|aac|eac3) ;;  # compatible, keep as-is
            *) needs_audio_convert=true; break ;;
        esac
    done <<< "$audio_codecs"
    if [[ "$needs_audio_convert" == true ]]; then
        echo "  (audio codec(s) $(echo "$audio_codecs" | tr '
' ',' | sed 's/,$//') -> aac)"
        ffmpeg_opts+=(-c:a aac)
        ffmpeg_opts+=(-b:a 192k)
    fi
    # Move moov atom to front for fast streaming
    ffmpeg_opts+=(-movflags +faststart)
    ffmpeg_opts+=(-y "$tmp")

    if "$FFMPEG_BIN" -hide_banner "${ffmpeg_opts[@]}" 2>&1; then
        # Verify the output file is readable
        if "$FFPROBE_BIN" -v quiet "$tmp" 2>/dev/null; then
            local new_bitrate new_mbit
            new_bitrate="$(get_video_bitrate "$tmp")"
            new_mbit="$(python3 -c "print(f'{${new_bitrate}/1_000_000:.1f}')" 2>/dev/null || echo "?")"
            mv -f "$tmp" "$src"
            echo "  OK: $(basename "$src") -> ${new_mbit} Mbit"
        else
            rm -f "$tmp"
            echo "  ERROR: output verification failed for $(basename "$src") -- original kept"
        fi
    else
        rm -f "$tmp"
        echo "  ERROR: ffmpeg failed for $(basename "$src") -- original kept"
    fi
}


# ── Process one directory ─────────────────────────────────────────────────────

process_dir() {  # process_dir <dir>
    local dir="$1"
    info "Processing: $dir"
    local found=0

    while IFS= read -r -d "" file; do
        convert_file "$file"
        (( found++ )) || true
    done < <(find "$dir" -type f -name "*.mp4" \
                ! -name "*.converting.mp4" \
                -print0 | sort -z)

    if [[ "$found" -eq 0 ]]; then
        info "No .mp4 files found in $dir"
    else
        info "Done. $found file(s) checked."
    fi
}


# ── Main ─────────────────────────────────────────────────────────────────────

# --all is an alias for processing TARGET_DIR recursively; process_dir already
# uses find with no depth limit so it handles Channel/Season and
# Channel/Show/Season equally. Kept for interface consistency with yt-nfo.sh.
process_dir "$TARGET_DIR"
