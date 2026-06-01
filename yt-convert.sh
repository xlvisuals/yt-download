#!/usr/bin/env bash
# yt-convert.sh -- Re-encode downloaded videos above a bitrate threshold
#
# Version:   2026-06-01
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# Iterates over .mp4 and .mkv files in a directory tree and re-encodes those
# whose video stream bitrate exceeds a threshold. Useful for reducing the size
# of ZDF downloads (typically 5-6 Mbit h.264) while leaving already-small
# YouTube files untouched.
#
# DEFAULTS
#   Output codec   : HEVC/h.265  (override with --h264)
#   Target bitrate : 2.8 Mbit/s for HEVC output  (override with --bitrate)
#                    4.0 Mbit/s for h.264 output
#   Threshold      : 4 Mbit/s for HEVC output     (override with --threshold)
#                    6 Mbit/s for h.264 output
#   AV1            : converted if above threshold by default; use --convert-av1
#                    to convert regardless of bitrate (e.g. for devices without
#                    AV1 hardware decode, such as older iPads)
#
#   HEVC needs ~40% fewer bits than h.264 for equivalent quality at 1080p.
#   Calibrated so that ZDF downloads (5-8 Mbit) are converted, YouTube
#   (1-2 Mbit) and typical filesharing files (2-3 Mbit HEVC, 3-4 Mbit h.264)
#   are left untouched.
#
# ENCODER SELECTION
#   macOS            VideoToolbox is probed first (hevc_videotoolbox /
#                    h264_videotoolbox). Falls back to libx265 / libx264 if
#                    VideoToolbox is not compiled into the bundled ffmpeg.
#   Linux / Windows  NVENC is used when available (hevc_nvenc / h264_nvenc).
#                    Falls back to libx265 / libx264 if the GPU or driver does
#                    not support NVENC.
#
# CONVERSION STRATEGY (two-pass for even quality distribution)
#   NVENC            -multipass fullres: NVENC's native full-resolution two-pass
#                    mode. Single ffmpeg invocation; roughly 2x encode time but
#                    distributes bits evenly across the file.
#   VideoToolbox     No two-pass API available. Uses quality-based encoding
#                    (-q:v 65) instead of bitrate-based, which distributes
#                    quality evenly by design. The -b:v target is not used.
#   libx265/libx264  Classic two-pass: pass 1 analyses the file (output to
#                    /dev/null), pass 2 encodes using the complexity map. Stats
#                    file is written next to the temp output and deleted after.
#
# 10-BIT SOURCES
#   10-bit pixel formats (yuv420p10le etc.) are detected automatically.
#   NVENC encodes to p010le; software encoders use yuv420p10le.
#   For NVENC, -hwaccel cuda is disabled for 10-bit sources to avoid a
#   pixel format conflict between CUDA surface frames and CPU-side p010le.
#
# AUDIO
#   aac, mp3, and eac3 streams are copied unchanged.
#   All other codecs (opus, vorbis, ac3, etc.) are converted to AAC 192k.
#
# SAFETY
#   Encodes to a .converting.mp4/.mkv temp file alongside the original.
#   Original is replaced only after successful encode + ffprobe verification.
#   Safe to re-run -- files already at or below the threshold are skipped.
#   Interrupted encodes leave the original untouched; the temp file is cleaned
#   up on the next run.

set -euo pipefail

# Print the failing line and command if the script exits unexpectedly.
trap 'echo "Error: script aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=yt-common.sh
source "${SCRIPT_DIR}/yt-common.sh"


# ── Parse arguments ──────────────────────────────────────────────────────────

DRY_RUN=false
ALL=false
CODEC=hevc          # hevc | h264
CONVERT_AV1=false   # when true, convert AV1 regardless of bitrate threshold
TARGET_BITRATE=""   # set after arg parse
THRESHOLD_BITS=""   # set after arg parse
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
      --convert-av1        Convert AV1 files regardless of bitrate threshold
                           (default: convert AV1 only if above threshold, same as other codecs)
  -b, --bitrate RATE       Target bitrate, e.g. 2.8M or 1500K
                           (default: 2.8M for HEVC, 4M for h.264)
  -t, --threshold RATE     Only convert files above this bitrate
                           (default: 4M for HEVC output; 4M/6M for h.264 output)
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
        awk -v n="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", n * 1000000000 }'
    elif [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)M$ ]]; then
        awk -v n="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", n * 1000000 }'
    elif [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)K$ ]]; then
        awk -v n="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", n * 1000 }'
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
        --convert-av1)          CONVERT_AV1=true;                      shift ;;
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

# Apply codec-dependent defaults if not overridden by --bitrate / --threshold.
# HEVC is ~40% more efficient than h.264 so needs fewer bits for equal quality.
if [[ "$CODEC" == "hevc" ]]; then
    [[ -z "$TARGET_BITRATE" ]] && TARGET_BITRATE="2.8M"
    [[ -z "$THRESHOLD_BITS" ]] && THRESHOLD_BITS="$(parse_bitrate 4M)"
else
    # h.264 output: higher threshold when the source is already h.264,
    # lower when converting from a more efficient codec (HEVC, AV1).
    # Use 6M when outputting h.264 (source likely h.264); 4M otherwise.
    [[ -z "$TARGET_BITRATE" ]] && TARGET_BITRATE="4M"
    [[ -z "$THRESHOLD_BITS" ]] && THRESHOLD_BITS="$(parse_bitrate 6M)"
fi

# Validate target bitrate string (used verbatim in ffmpeg -b:v)
[[ "$TARGET_BITRATE" =~ ^[0-9]+(\.[0-9]+)?[KMG]?$ ]] \
    || die "Invalid target bitrate: '$TARGET_BITRATE'"


# ── Set up logging ────────────────────────────────────────────────────────────

if [[ -n "$LOG_DIR" ]]; then
    setup_logging "$LOG_DIR" "yt-convert"
fi


# ── Locate ffmpeg / ffprobe ───────────────────────────────────────────────────

# Look next to the script first (bundled), then fall back to PATH.
# On Windows (Cygwin/Git Bash) also check for .exe variants, and always
# prefer the bundled binary over any system install to avoid picking up
# the wrong version (e.g. Cygwin's ffprobe instead of the Windows build).
find_tool() {  # find_tool <name>
    local name="$1"
    local bundled="${SCRIPT_DIR}/${name}"
    local bundled_exe="${SCRIPT_DIR}/${name}.exe"
    if [[ -x "$bundled_exe" ]]; then
        echo "$bundled_exe"
    elif [[ -x "$bundled" ]]; then
        echo "$bundled"
    elif command -v "${name}.exe" &>/dev/null; then
        echo "$(command -v "${name}.exe")"
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

# Convert a path to the native format expected by the ffmpeg/ffprobe binary.
# On Cygwin, Windows .exe binaries cannot handle /cygdrive/f/... paths --
# they need Windows-style F:\... paths. cygpath -w does the conversion.
# On all other systems the path is returned unchanged.
native_path() {  # native_path <path> -> echo native_path
    if command -v cygpath &>/dev/null; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}


# ── Detect hardware acceleration ──────────────────────────────────────────────

# Returns the best available encoder name for the requested codec.
# Sets HW_ACCEL_FLAGS (extra input flags, e.g. -hwaccel cuda) and
# ENCODER_FLAGS (extra output flags specific to the chosen encoder).
HW_ACCEL_FLAGS=()
ENCODER_FLAGS=()

# Check whether an encoder is listed in this ffmpeg build's encoder list.
encoder_available() {  # encoder_available <encoder_name> -> 0=yes 1=no
    "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null | grep -q "^ V.*$1"
}

detect_encoder() {  # detect_encoder <codec: hevc|h264> -> echo encoder_name
    local codec="$1"
    local os; os="$(uname -s)"

    if [[ "$os" == "Darwin" ]]; then
        # Prefer VideoToolbox (hardware) when available in this ffmpeg build.
        # evermeet.cx static builds may omit VideoToolbox (--disable-videotoolbox),
        # in which case we fall back to libx265/libx264.
        # -tag:v hvc1 is required for HEVC-in-MP4 compatibility with Apple devices.
        if [[ "$codec" == "hevc" ]]; then
            if encoder_available "hevc_videotoolbox"; then
                ENCODER_FLAGS=("-tag:v" "hvc1")
                echo "hevc_videotoolbox"
            else
                info "hevc_videotoolbox not in this ffmpeg build -- using libx265"
                echo "libx265"
            fi
        else
            if encoder_available "h264_videotoolbox"; then
                echo "h264_videotoolbox"
            else
                info "h264_videotoolbox not in this ffmpeg build -- using libx264"
                echo "libx264"
            fi
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
    local file; file="$(native_path "$1")"
    local bitrate

    # Try stream-level bitrate first
    bitrate="$("$FFPROBE_BIN" \
        -v quiet \
        -select_streams v:0 \
        -show_entries stream=bit_rate \
        -of csv=p=0 \
        "$file" 2>/dev/null | head -1 | tr -d '\r')"

    # Fall back to container-level bitrate if stream reports N/A
    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        bitrate="$("$FFPROBE_BIN" \
            -v quiet \
            -show_entries format=bit_rate \
            -of csv=p=0 \
            "$file" 2>/dev/null | head -1 | tr -d '\r')"
    fi

    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        echo 0
    else
        echo "$bitrate"
    fi
}

# Return the video codec name (e.g. "h264", "hevc")
get_video_codec() {  # get_video_codec <file> -> echo codec_name
    local file; file="$(native_path "$1")"
    "$FFPROBE_BIN" \
        -v quiet \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of csv=p=0 \
        "$file" 2>/dev/null | head -1 | tr -d '\r' 
}


# ── Convert one file ──────────────────────────────────────────────────────────

# Converts <file> in-place:
#   1. Encode to <file>.converting.mp4
#   2. Verify output with ffprobe
#   3. Replace original with converted file
convert_file() {  # convert_file <file>
    local src="$1"
    local dir; dir="$(dirname "$src")"
    local ext="${src##*.}"
    local base; base="$(basename "$src" ".${ext}")"
    local tmp="${dir}/${base}.converting.${ext}"
    local src_native; src_native="$(native_path "$src")"
    local tmp_native; tmp_native="$(native_path "$tmp")"

    local bitrate; bitrate="$(get_video_bitrate "$src")"
    local codec;   codec="$(get_video_codec "$src")"
    # Guard arithmetic against empty or non-numeric bitrate values
    bitrate="${bitrate//[$'\r\n 	']/}"  # strip CRLF/whitespace from Windows ffprobe output
    [[ "$bitrate" =~ ^[0-9]+$ ]] || bitrate=0
    local bitrate_mbit
    local _bm_int=$(( bitrate / 1000000 ))
    local _bm_dec=$(( (bitrate % 1000000) / 100000 ))
    bitrate_mbit="${_bm_int}.${_bm_dec}"

    # Skip if already at or below threshold.
    # If bitrate is 0 (unreadable -- e.g. ffprobe can't parse the file or the
    # stream has no bitrate metadata) convert anyway rather than silently skipping.
    if [[ "$bitrate" -gt 0 && "$bitrate" -le "$THRESHOLD_BITS" ]]; then
        echo "  SKIP (${bitrate_mbit} Mbit, under threshold): $(basename "$src")"
        return
    fi
    if [[ "$bitrate" -eq 0 ]]; then
        echo "  WARN: cannot read bitrate for $(basename "$src") -- converting anyway"
    fi

    # Skip if already the target codec and under threshold
    local target_codec_name
    [[ "$CODEC" == "hevc" ]] && target_codec_name="hevc" || target_codec_name="h264"
    if [[ "$codec" == "$target_codec_name" && "$bitrate" -le "$THRESHOLD_BITS" ]]; then
        echo "  SKIP (already ${codec}, ${bitrate_mbit} Mbit): $(basename "$src")"
        return
    fi

    # AV1: with --convert-av1, bypass the threshold check and always convert
    # (useful for devices without AV1 hardware decode, e.g. older iPads).
    # Without the flag, AV1 follows the same threshold logic as any other codec.
    if [[ "$codec" == "av1" && "$CONVERT_AV1" == true ]]; then
        echo "  CONVERT (av1, ${bitrate_mbit} Mbit -> ${CODEC} ${TARGET_BITRATE}, forced): $(basename "$src")"
        [[ "$DRY_RUN" == true ]] && return
    else
        echo "  CONVERT (${codec}, ${bitrate_mbit} Mbit -> ${CODEC} ${TARGET_BITRATE}): $(basename "$src")"
        [[ "$DRY_RUN" == true ]] && return
    fi

    # Clean up any leftover temp file from a previous interrupted run
    [[ -f "$tmp" ]] && rm -f "$tmp"

    local ffmpeg_opts=()
    # Hardware decode flags (empty on macOS/software)
    ffmpeg_opts+=("${HW_ACCEL_FLAGS[@]+"${HW_ACCEL_FLAGS[@]}"}")
    ffmpeg_opts+=(-nostdin)   # prevent ffmpeg waiting for interactive input
    ffmpeg_opts+=(-i "$src_native")
    # Map streams explicitly. Capital V selects video EXCLUDING attached pictures.
    # Only add each map if that stream type actually exists in the file -- ffmpeg
    # treats a -map to a non-existent stream type as a fatal error.
    ffmpeg_opts+=(-map 0:V)   # video (excluding attached pictures)
    # Check each stream type and only map if present. wc -l output is trimmed
    # because Cygwin's wc pads with leading spaces which confuses [[ -gt 0 ]].
    local _count
    _count="$("$FFPROBE_BIN" -v quiet -select_streams a         -show_entries stream=index -of csv=p=0 "$src_native" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${_count:-0}" -gt 0 ]] && ffmpeg_opts+=(-map 0:a)
    _count="$("$FFPROBE_BIN" -v quiet -select_streams s         -show_entries stream=index -of csv=p=0 "$src_native" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${_count:-0}" -gt 0 ]] && ffmpeg_opts+=(-map 0:s)
    _count="$("$FFPROBE_BIN" -v quiet -select_streams d         -show_entries stream=index -of csv=p=0 "$src_native" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${_count:-0}" -gt 0 ]] && ffmpeg_opts+=(-map 0:d)
    # Attachments (-map 0:t) intentionally skipped -- streams with unknown
    # codecs (e.g. kodi XML metadata) cause ffmpeg to corrupt the output.
    # Be explicit about each stream type -- avoids the "Multiple -codec options"
    # warning that occurs when -c copy and -c:v <encoder> are combined, and
    # ensures encoder-specific AVOptions (-allow_sw, -tag:v) apply correctly.
    ffmpeg_opts+=(-c:v "$ENCODER")
    ffmpeg_opts+=(-b:v "$TARGET_BITRATE")
    # Encoder-specific flags (e.g. -allow_sw 1 -tag:v hvc1 for VideoToolbox HEVC)
    ffmpeg_opts+=("${ENCODER_FLAGS[@]+"${ENCODER_FLAGS[@]}"}")
    # Preserve 10-bit pixel format for 10-bit sources (e.g. yuv420p10le).
    # Without explicit -pix_fmt, NVENC and some other HW encoders silently
    # encode only a handful of frames then stall on 10-bit input.
    local _pix_fmt
    _pix_fmt="$("$FFPROBE_BIN" -v quiet -select_streams v:0         -show_entries stream=pix_fmt -of csv=p=0         "$src_native" 2>/dev/null | head -1)"
    case "${_pix_fmt:-}" in
        *10le|*10be|*10*)
            # 10-bit source: NVENC needs p010le but -hwaccel cuda conflicts with it
            # (cuda surface format is incompatible with CPU-side p010le frames).
            # Solution: remove hwaccel input flags so CPU decodes, then NVENC
            # receives p010le frames directly.
            case "$ENCODER" in
                *nvenc*)
                    HW_ACCEL_FLAGS=()   # CPU decode for 10-bit NVENC
                    ffmpeg_opts+=(-pix_fmt p010le)
                    ;;
                *videotoolbox*)
                    ffmpeg_opts+=(-pix_fmt p010le)
                    ;;
                *)
                    ffmpeg_opts+=(-pix_fmt yuv420p10le)
                    ;;
            esac
            ;;
    esac
    ffmpeg_opts+=(-c:s copy)
    ffmpeg_opts+=(-c:d copy)
    # Audio: copy if already mp3/aac/eac3; otherwise convert to aac.
    # Check all audio streams in the file -- if any need conversion, use -c:a aac
    # for all (mixing codecs per-stream in MP4 is fragile).
    local audio_codecs
    audio_codecs="$("$FFPROBE_BIN" \
        -v quiet \
        -select_streams a \
        -show_entries stream=codec_name \
        -of csv=p=0 \
        "$src_native" 2>/dev/null)"
    local needs_audio_convert=false
    while IFS= read -r acodec; do
        [[ -z "$acodec" ]] && continue
        case "$acodec" in
            mp3|aac|eac3) ;;  # compatible, keep as-is
            *) needs_audio_convert=true; break ;;
        esac
    done <<< "$audio_codecs"
    if [[ "$needs_audio_convert" == true ]]; then
        echo "  (audio codec(s) $(echo "$audio_codecs" | tr '\n' ',' | sed 's/,$//') -> aac)"
        ffmpeg_opts+=(-c:a aac)
        ffmpeg_opts+=(-b:a 192k)
    else
        ffmpeg_opts+=(-c:a copy)
    fi
    # -movflags +faststart moves the moov atom for fast streaming in mp4.
    # Not applicable to mkv (ignored but harmless -- skip it for cleanliness).
    [[ "$ext" == "mp4" ]] && ffmpeg_opts+=(-movflags +faststart)

    # Two-pass encoding for better bitrate distribution across the file.
    # Single-pass VBR starts low and ramps up as the encoder learns complexity,
    # leaving the first part of the file with worse quality than the rest.
    #
    # Strategy by encoder:
    #   NVENC          -- -multipass fullres (native two-pass in one invocation)
    #   VideoToolbox   -- no two-pass support; quality-based (-q:v) is used instead
    #   libx265/libx264 -- classic two-pass: pass 1 to /dev/null, pass 2 to output
    local ffmpeg_exit=0

    case "$ENCODER" in
        *nvenc*)
            # NVENC multipass: single invocation, full-resolution first pass
            ffmpeg_opts+=(-multipass fullres)
            ffmpeg_opts+=(-y "$tmp_native")
            echo "  (pass 1+2 via NVENC multipass)"
            if [[ -n "${YT_LOG_FILE:-}" ]]; then
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${ffmpeg_opts[@]}" 2>/dev/tty || ffmpeg_exit=$?
            else
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${ffmpeg_opts[@]}" || ffmpeg_exit=$?
            fi
            ;;
        *videotoolbox*)
            # VideoToolbox has no two-pass; replace -b:v with quality-based encoding
            # which distributes quality more evenly than single-pass VBR
            local _opts_nobitrate=()
            local _skip_next=false
            for _o in "${ffmpeg_opts[@]}"; do
                if [[ "$_skip_next" == true ]]; then _skip_next=false; continue; fi
                if [[ "$_o" == "-b:v" ]]; then _skip_next=true; continue; fi
                _opts_nobitrate+=("$_o")
            done
            _opts_nobitrate+=(-q:v 60)   # VideoToolbox quality 0-100, ~60 ≈ 2Mbit
            _opts_nobitrate+=(-y "$tmp_native")
            if [[ -n "${YT_LOG_FILE:-}" ]]; then
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${_opts_nobitrate[@]}" 2>/dev/tty || ffmpeg_exit=$?
            else
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${_opts_nobitrate[@]}" || ffmpeg_exit=$?
            fi
            ;;
        *)
            # libx265/libx264: classic two-pass with stats file
            local _stats="${tmp}.stats"
            local _null_out
            [[ "$(uname -s)" == *MINGW* || "$(uname -s)" == *CYGWIN* ]]                 && _null_out="NUL" || _null_out="/dev/null"
            # Pass 1: analyse only, output to null
            local _pass1_opts=("${ffmpeg_opts[@]}")
            _pass1_opts+=(-pass 1 -passlogfile "$_stats" -f null "$_null_out")
            echo "  (pass 1/2: analysing...)"
            if [[ -n "${YT_LOG_FILE:-}" ]]; then
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${_pass1_opts[@]}" 2>/dev/tty || ffmpeg_exit=$?
            else
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${_pass1_opts[@]}" || ffmpeg_exit=$?
            fi
            # Pass 2: encode using stats from pass 1
            if [[ "$ffmpeg_exit" -eq 0 ]]; then
                ffmpeg_opts+=(-pass 2 -passlogfile "$_stats")
                ffmpeg_opts+=(-y "$tmp_native")
                echo "  (pass 2/2: encoding...)"
            if [[ -n "${YT_LOG_FILE:-}" ]]; then
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${ffmpeg_opts[@]}" 2>/dev/tty || ffmpeg_exit=$?
            else
                "$FFMPEG_BIN" -hide_banner -loglevel warning -stats "${ffmpeg_opts[@]}" || ffmpeg_exit=$?
            fi
            fi
            rm -f "${_stats}" "${_stats}-0.log" "${_stats}-0.log.mbtree" 2>/dev/null
            ;;
    esac

    if [[ "$ffmpeg_exit" -eq 0 ]]; then
        # Verify the output file is readable
        if "$FFPROBE_BIN" -v quiet "$tmp_native" 2>/dev/null; then
            # Sanity-check: output must be at least 50% of the theoretically expected
            # size based on the target/source bitrate ratio. This correctly handles
            # high-compression cases (e.g. 12 Mbit -> 2 Mbit = ~17% expected size).
            # A fixed percentage would wrongly reject these legitimate results.
            local src_size tmp_size
            src_size="$(wc -c < "$src" | tr -d ' ')"
            tmp_size="$(wc -c < "$tmp" | tr -d ' ')"
            # target_bits / source_bits * 0.5 = minimum acceptable size ratio
            # Use integer arithmetic: min = src_size * target_kbits / src_kbits / 2
            local _target_kbits _src_kbits _min_size
            _target_kbits="$(parse_bitrate "$TARGET_BITRATE")"
            _target_kbits=$(( _target_kbits / 1000 ))
            _src_kbits=$(( bitrate / 1000 ))
            if [[ "$_src_kbits" -gt 0 ]]; then
                _min_size=$(( src_size * _target_kbits / _src_kbits / 2 ))
            else
                _min_size=$(( src_size / 10 ))   # fallback: 10% if src bitrate unknown
            fi
            if [[ "$tmp_size" -lt "$_min_size" ]]; then
                echo "  ERROR: output is only $(( tmp_size * 100 / src_size ))% the size of the original (expected ~$(( _target_kbits * 100 / (_src_kbits > 0 ? _src_kbits : 1) ))%) -- likely corrupt, original kept, converted file left as $(basename "$tmp")"
            else
                local new_bitrate new_mbit
                new_bitrate="$(get_video_bitrate "$tmp")"
                local _nm_int=$(( new_bitrate / 1000000 ))
                local _nm_dec=$(( (new_bitrate % 1000000) / 100000 ))
                new_mbit="${_nm_int}.${_nm_dec}"
                mv -f "$tmp" "$src"
                echo "  OK: $(basename "$src") -> ${new_mbit} Mbit"
            fi
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

    # Collect files into an array first -- avoids pipefail interaction with
    # sort -z in Cygwin where a null-delimited sort may exit non-zero on
    # empty input, silently killing the loop under set -euo pipefail.
    local -a files=()
    while IFS= read -r -d "" file; do
        files+=("$file")
    done < <(/usr/bin/find "$dir" -type f \
                \( -name "*.mp4" -o -name "*.mkv" \) \
                ! -name "*.converting.mp4" \
                ! -name "*.converting.mkv" \
                -print0 2>/dev/null | sort -z || true)

    if [[ "${#files[@]}" -eq 0 ]]; then
        info "No .mp4 or .mkv files found in $dir"
        return
    fi

    for file in "${files[@]}"; do
        convert_file "$file"
        (( found++ )) || true
    done

    info "Done. $found file(s) checked."
}


# ── Main ─────────────────────────────────────────────────────────────────────

# --all is an alias for processing TARGET_DIR recursively; process_dir already
# uses find with no depth limit so it handles Channel/Season and
# Channel/Show/Season equally. Kept for interface consistency with yt-nfo.sh.
process_dir "$TARGET_DIR"
