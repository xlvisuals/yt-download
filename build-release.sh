#!/usr/bin/env bash
set -euo pipefail

# build-release.sh — Assemble yt-download release bundles for each platform
#
# Downloads the latest yt-dlp and ffmpeg binaries for each platform,
# packages them with yt-download.sh and README.md, and produces:
#
#   dist/yt-download_macos_x64.tar.gz
#   dist/yt-download_macos_arm64.tar.gz
#   dist/yt-download_linux_x64.tar.gz
#   dist/yt-download_linux_arm64.tar.gz
#   dist/yt-download_windows_x64.zip        (Git Bash / x86_64)

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }
need_cmd() { command -v "$1" &>/dev/null || die "'$1' is required. Install it and try again."; }

fetch() {   # fetch <url> <dest>
    if command -v curl &>/dev/null; then
        curl -fsSL --max-redirs 10 --progress-bar "$1" -o "$2"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$2" "$1"
    else
        die "Neither curl nor wget found."
    fi
}

need_cmd uname
need_cmd chmod
need_cmd tar
need_cmd zip
need_cmd unzip

# ─────────────────────────────────────────────
# Resolve latest release tags
# ─────────────────────────────────────────────
info "Resolving latest yt-dlp release tag"
YTDLP_TAG="$(
    fetch https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest - \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/'
)"
[[ -z "$YTDLP_TAG" ]] && die "Could not resolve yt-dlp release tag"
info "yt-dlp: $YTDLP_TAG"

# yt-dlp/FFmpeg-Builds uses a rolling "latest" release, no versioned tags
info "Using yt-dlp/FFmpeg-Builds latest release"

# ─────────────────────────────────────────────
# Directories
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "$DIST_DIR" "$BUILD_DIR"

# ─────────────────────────────────────────────
# Source files to include in every bundle
# ─────────────────────────────────────────────
SCRIPT="${SCRIPT_DIR}/yt-download.sh"
README="${SCRIPT_DIR}/README.md"
[[ -f "$SCRIPT" ]] || die "yt-download.sh not found in $SCRIPT_DIR"
[[ -f "$README" ]] || die "README.md not found in $SCRIPT_DIR"

# ─────────────────────────────────────────────
# ffmpeg binary sources
# yt-dlp/FFmpeg-Builds: Windows and Linux only (no macOS builds exist)
# macOS Intel:  evermeet.cx (x86_64 static builds)
# macOS ARM64:  ffmpeg.martin-riedl.de (signed + notarized Apple Silicon builds)
# ─────────────────────────────────────────────
FFMPEG_YTDLP_BASE="https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download"
FFMPEG_LINUX_ARCHIVE="ffmpeg-master-latest-linux64-gpl.tar.xz"
FFMPEG_LINUX_ARM64_ARCHIVE="ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
FFMPEG_WIN_ARCHIVE="ffmpeg-master-latest-win64-gpl.zip"

# evermeet.cx: /getrelease redirects to the latest release zip (Intel only)
FFMPEG_MACOS_INTEL_URL="https://evermeet.cx/ffmpeg/getrelease/zip"
# martin-riedl.de: static ARM64 build, signed and notarized
FFMPEG_MACOS_ARM64_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"

# ─────────────────────────────────────────────
# Helper: download and cache a file
# ─────────────────────────────────────────────
cached_fetch() {    # cached_fetch <url> <local-filename>
    local url="$1" dest="${BUILD_DIR}/$2"
    if [[ -f "$dest" ]]; then
        echo "  (cached) $2" >&2
    else
        echo "  Downloading $2 ..." >&2
        fetch "$url" "$dest"
    fi
    echo "$dest"
}

# ─────────────────────────────────────────────
# Helper: extract ffmpeg binary from archive
# Output: writes binary to <dest_path>
# ─────────────────────────────────────────────
extract_ffmpeg() {  # extract_ffmpeg <archive> <binary_name_in_archive> <dest_path>
    local archive="$1" binary="$2" dest="$3"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    case "$archive" in
        *.tar.xz) tar -xJf "$archive" -C "$tmp_dir" ;;
        *.zip)    unzip -q "$archive" -d "$tmp_dir" ;;
        *)        die "Unknown archive format: $archive" ;;
    esac

    # Find the binary anywhere in the extracted tree
    local found
    found="$(find "$tmp_dir" -type f -name "$binary" | head -1)"
    [[ -z "$found" ]] && die "Could not find '$binary' in $(basename "$archive")"
    cp "$found" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"
}

# ─────────────────────────────────────────────
# Helper: assemble one bundle
# ─────────────────────────────────────────────
make_bundle() {
    # Args: <bundle_name> <archive_type: tar|zip> <ytdlp_binary> <ffmpeg_src_path>
    local name="$1" arc_type="$2" ytdlp_src="$3" ffmpeg_src="$4"
    local stage_dir="${BUILD_DIR}/stage/${name}"

    info "Building $name"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    cp "$SCRIPT"     "$stage_dir/yt-download.sh"
    cp "$README"     "$stage_dir/README.md"
    cp "$ytdlp_src"  "$stage_dir/$(basename "$ytdlp_src")"
    cp "$ffmpeg_src" "$stage_dir/$(basename "$ffmpeg_src")"

    chmod +x "$stage_dir/$(basename "$ytdlp_src")"
    chmod +x "$stage_dir/$(basename "$ffmpeg_src")"
    chmod +x "$stage_dir/yt-download.sh"

    local out_file
    if [[ "$arc_type" == "tar" ]]; then
        out_file="${DIST_DIR}/${name}.tar.gz"
        # -C to the parent so the archive contains yt-download/<files>
        # Strip macOS extended attributes (quarantine, origin metadata) to avoid
        # "unknown extended header" warnings when extracting on Linux
        if command -v xattr &>/dev/null; then
            xattr -cr "${BUILD_DIR}/stage/${name}"
        fi
        COPYFILE_DISABLE=1 tar -czf "$out_file" -C "${BUILD_DIR}/stage" "$name"
        echo "  -> $out_file"
    else
        out_file="${DIST_DIR}/${name}.zip"
        (cd "${BUILD_DIR}/stage" && zip -qr "$out_file" "$name")
        echo "  -> $out_file"
    fi
}

# ─────────────────────────────────────────────
# Download yt-dlp binaries
# ─────────────────────────────────────────────
YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_TAG}"

info "Fetching yt-dlp binaries"
YTDLP_MACOS="$(    cached_fetch "${YTDLP_BASE}/yt-dlp_macos"           "yt-dlp_macos")"
YTDLP_LINUX="$(    cached_fetch "${YTDLP_BASE}/yt-dlp_linux"           "yt-dlp_linux")"
YTDLP_ARM64="$(    cached_fetch "${YTDLP_BASE}/yt-dlp_linux_aarch64"   "yt-dlp_linux_aarch64")"
YTDLP_WIN="$(      cached_fetch "${YTDLP_BASE}/yt-dlp.exe"             "yt-dlp.exe")"

# ─────────────────────────────────────────────
# Download and extract ffmpeg binaries
# ─────────────────────────────────────────────
info "Fetching ffmpeg binaries"

FFMPEG_MACOS_INTEL_ARCHIVE_PATH="$( cached_fetch "$FFMPEG_MACOS_INTEL_URL"                          "ffmpeg-macos-intel.zip")"
FFMPEG_MACOS_ARM64_ARCHIVE_PATH="$( cached_fetch "$FFMPEG_MACOS_ARM64_URL"                          "ffmpeg-macos-arm64.zip")"
FFMPEG_LINUX_ARCHIVE_PATH="$(       cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_LINUX_ARCHIVE}"     "$FFMPEG_LINUX_ARCHIVE")"
FFMPEG_LINUX_ARM64_ARCHIVE_PATH="$( cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_LINUX_ARM64_ARCHIVE}" "$FFMPEG_LINUX_ARM64_ARCHIVE")"
FFMPEG_WIN_ARCHIVE_PATH="$(         cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_WIN_ARCHIVE}"       "$FFMPEG_WIN_ARCHIVE")"

info "Extracting ffmpeg binaries"
FFMPEG_MACOS_INTEL="${BUILD_DIR}/ffmpeg_macos_intel"; extract_ffmpeg "$FFMPEG_MACOS_INTEL_ARCHIVE_PATH" "ffmpeg"     "$FFMPEG_MACOS_INTEL"
FFMPEG_MACOS_ARM64="${BUILD_DIR}/ffmpeg_macos_arm64"; extract_ffmpeg "$FFMPEG_MACOS_ARM64_ARCHIVE_PATH" "ffmpeg"     "$FFMPEG_MACOS_ARM64"
FFMPEG_LINUX="${BUILD_DIR}/ffmpeg_linux";             extract_ffmpeg "$FFMPEG_LINUX_ARCHIVE_PATH"       "ffmpeg"     "$FFMPEG_LINUX"
FFMPEG_LINUX_ARM64="${BUILD_DIR}/ffmpeg_linux_arm64"; extract_ffmpeg "$FFMPEG_LINUX_ARM64_ARCHIVE_PATH" "ffmpeg"     "$FFMPEG_LINUX_ARM64"
FFMPEG_WIN="${BUILD_DIR}/ffmpeg.exe";                 extract_ffmpeg "$FFMPEG_WIN_ARCHIVE_PATH"         "ffmpeg.exe" "$FFMPEG_WIN"

# ─────────────────────────────────────────────
# Assemble bundles
# ─────────────────────────────────────────────
# macOS and Linux use tar.gz (preserves executable bits natively)
# Windows uses zip (Git Bash users expect it)

make_bundle "yt-download_macos_x64"    tar  "$YTDLP_MACOS" "$FFMPEG_MACOS_INTEL"
make_bundle "yt-download_macos_arm64"  tar  "$YTDLP_MACOS" "$FFMPEG_MACOS_ARM64"
make_bundle "yt-download_linux_x64"    tar  "$YTDLP_LINUX" "$FFMPEG_LINUX"
make_bundle "yt-download_linux_arm64"  tar  "$YTDLP_ARM64" "$FFMPEG_LINUX_ARM64"
make_bundle "yt-download_windows_x64"  zip  "$YTDLP_WIN"   "$FFMPEG_WIN"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
info "All bundles ready in dist/"
ls -lh "$DIST_DIR"
