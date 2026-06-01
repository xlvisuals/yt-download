#!/usr/bin/env bash
# build-release.sh -- Assemble yt-download release bundles for each platform
#
# Version:   2026-06-01
# License:   MIT <https://spdx.org/licenses/MIT.html>
# Copyright: 2026 Axel Busch
#
# Downloads the latest yt-dlp, ffmpeg, and ffplay binaries for each platform,
# packages them with yt-download.sh and README.md, and produces:
#
#   dist/yt-download_macos.tar.gz
#   dist/yt-download_linux.tar.gz
#   dist/yt-download_linux_aarch64.tar.gz
#   dist/yt-download_windows.zip        (Git Bash / x86_64)

set -euo pipefail

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


# ─────────────────────────────────────────────
# Directories
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
CACHE_DIR="${SCRIPT_DIR}/.build-cache"
mkdir -p "$DIST_DIR" "$CACHE_DIR"

info "Resolving latest deno release"
DENO_VERSION="$(fetch https://dl.deno.land/release-latest.txt - | tr -d "[:space:]")"
[[ -z "$DENO_VERSION" ]] && die "Could not resolve deno release version"
info "deno: $DENO_VERSION"

# ffmpeg has no reliable version API -- refresh it whenever yt-dlp updates
YTDLP_VERSION_FILE="${CACHE_DIR}/yt-dlp.version"
CACHED_YTDLP_TAG=""
[[ -f "$YTDLP_VERSION_FILE" ]] && CACHED_YTDLP_TAG="$(cat "$YTDLP_VERSION_FILE")"
if [[ -n "$CACHED_YTDLP_TAG" && "$CACHED_YTDLP_TAG" != "$YTDLP_TAG" ]]; then
    info "yt-dlp updated ($CACHED_YTDLP_TAG -> $YTDLP_TAG) -- clearing ffmpeg cache"
    rm -f "${CACHE_DIR}"/ffmpeg-* "${CACHE_DIR}"/ffmpeg_*
fi

# ─────────────────────────────────────────────
# Source files to include in every bundle
# ─────────────────────────────────────────────
SCRIPT_COMMON="${SCRIPT_DIR}/yt-common.sh"
SCRIPT_CONVERT="${SCRIPT_DIR}/yt-convert.sh"
SCRIPT_DOWNLOAD="${SCRIPT_DIR}/yt-download.sh"
SCRIPT_NFO="${SCRIPT_DIR}/yt-nfo.sh"
SCRIPT_RENAME="${SCRIPT_DIR}/yt-rename.sh"
SCRIPT_EMOJI="${SCRIPT_DIR}/yt-strip-emoji.sh"
README="${SCRIPT_DIR}/README.md"
[[ -f "$SCRIPT_CONVERT" ]]  || die "yt-convert.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_COMMON" ]]  || die "yt-common.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DOWNLOAD" ]]  || die "yt-download.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_NFO" ]]     || die "yt-nfo.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_RENAME" ]]  || die "yt-rename.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_EMOJI" ]]  || die "yt-strip-emoji.sh not found in $SCRIPT_DIR"
[[ -f "$README" ]]  || die "README.md not found in $SCRIPT_DIR"

# ─────────────────────────────────────────────
# ffmpeg binary sources
# yt-dlp/FFmpeg-Builds: Windows and Linux only (no macOS builds exist)
# macOS x64:  evermeet.cx (x86_64 static builds)
# macOS aarch64:  ffmpeg.martin-riedl.de (signed + notarized Apple Silicon builds)
# ─────────────────────────────────────────────
FFMPEG_YTDLP_BASE="https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download"
FFMPEG_LINUX_ARCHIVE="ffmpeg-master-latest-linux64-gpl.tar.xz"
FFMPEG_LINUX_AARCH64_ARCHIVE="ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
FFMPEG_WIN_ARCHIVE="ffmpeg-master-latest-win64-gpl.zip"

# evermeet.cx: /getrelease redirects to the latest release zip (x64 only)
FFMPEG_MACOS_X64_URL="https://evermeet.cx/ffmpeg/getrelease/zip"
FFPLAY_MACOS_X64_URL="https://evermeet.cx/ffmpeg/getrelease/ffplay/zip"
FFPROBE_MACOS_X64_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
# martin-riedl.de: static ARM64 build, signed and notarized
FFMPEG_MACOS_AARCH64_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
FFPLAY_MACOS_AARCH64_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffplay.zip"
FFPROBE_MACOS_AARCH64_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"

# ─────────────────────────────────────────────
# deno binary sources (GitHub releases)
# Full deno binary for all platforms, single file inside a zip
# Note: dl.deno.land only has "denort" for Linux which cannot run standalone
# ─────────────────────────────────────────────
DENO_BASE="https://github.com/denoland/deno/releases/download/${DENO_VERSION}"
DENO_MACOS_X64_ARCHIVE="deno-x86_64-apple-darwin.zip"
DENO_MACOS_AARCH64_ARCHIVE="deno-aarch64-apple-darwin.zip"
DENO_LINUX_X64_ARCHIVE="deno-x86_64-unknown-linux-gnu.zip"
DENO_LINUX_AARCH64_ARCHIVE="deno-aarch64-unknown-linux-gnu.zip"
DENO_WIN_ARCHIVE="deno-x86_64-pc-windows-msvc.zip"

# ─────────────────────────────────────────────
# Helper: download and cache a file, re-downloading if version changed
# ─────────────────────────────────────────────
cached_fetch() {    # cached_fetch <url> <local-filename> [version]
    local url="$1" dest="${CACHE_DIR}/$2" version="${3:-}"
    local version_file="${dest}.version"
    local cached_version=""
    [[ -f "$version_file" ]] && cached_version="$(cat "$version_file")"

    if [[ -f "$dest" && ( -z "$version" || "$cached_version" == "$version" ) ]]; then
        echo "  (cached) $2${version:+ @ $cached_version}" >&2
    else
        if [[ -f "$dest" && -n "$version" && "$cached_version" != "$version" ]]; then
            echo "  (update) $2: $cached_version -> $version" >&2
        else
            echo "  Downloading $2${version:+ @ $version} ..." >&2
        fi
        fetch "$url" "$dest"
        [[ -n "$version" ]] && echo "$version" > "$version_file"
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
    # Args: <bundle_name> <archive_type: tar|zip> <ytdlp_binary> <ffmpeg_src_path> <ffplay_src_path> <ffprobe_src_path> [deno_src_path]
    local name="$1" arc_type="$2" ytdlp_src="$3" ffmpeg_src="$4" ffplay_src="$5" ffprobe_src="$6" deno_src="${7:-}"
    local stage_dir="${CACHE_DIR}/stage/${name}"

    info "Building $name"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    cp "$SCRIPT_CONVERT"    "$stage_dir/yt-convert.sh"
    cp "$SCRIPT_COMMON"     "$stage_dir/yt-common.sh"
    cp "$SCRIPT_DOWNLOAD"   "$stage_dir/yt-download.sh"
    cp "$SCRIPT_NFO"        "$stage_dir/yt-nfo.sh"
    cp "$SCRIPT_RENAME"     "$stage_dir/yt-rename.sh"
    cp "$SCRIPT_EMOJI"      "$stage_dir/yt-strip-emoji.sh"
    cp "$README"            "$stage_dir/README.md"
    cp "$ytdlp_src"         "$stage_dir/$(basename "$ytdlp_src")"
    # Always name ffmpeg/ffplay binaries consistently in the bundle
    local ffmpeg_name ffplay_name ffprobe_name
    [[ "$ffmpeg_src"  == *.exe ]] && ffmpeg_name="ffmpeg.exe"   || ffmpeg_name="ffmpeg"
    [[ "$ffplay_src"  == *.exe ]] && ffplay_name="ffplay.exe"   || ffplay_name="ffplay"
    [[ "$ffprobe_src" == *.exe ]] && ffprobe_name="ffprobe.exe" || ffprobe_name="ffprobe"
    cp "$ffmpeg_src"  "$stage_dir/$ffmpeg_name"
    cp "$ffplay_src"  "$stage_dir/$ffplay_name"
    cp "$ffprobe_src" "$stage_dir/$ffprobe_name"
    if [[ -n "$deno_src" ]]; then
        # Always name the binary "deno" (or "deno.exe") in the bundle
        local deno_name
        [[ "$deno_src" == *.exe ]] && deno_name="deno.exe" || deno_name="deno"
        cp "$deno_src" "$stage_dir/$deno_name"
        chmod +x "$stage_dir/$deno_name"
    fi

    chmod +x "$stage_dir/$(basename "$ytdlp_src")"
    chmod +x "$stage_dir/$ffmpeg_name"
    chmod +x "$stage_dir/$ffplay_name"
    chmod +x "$stage_dir/$ffprobe_name"
    chmod +x "$stage_dir/yt-convert.sh"
    chmod +x "$stage_dir/yt-download.sh"
    chmod +x "$stage_dir/yt-rename.sh"
    chmod +x "$stage_dir/yt-nfo.sh"
    chmod +x "$stage_dir/yt-strip-emoji.sh"

    local out_file
    if [[ "$arc_type" == "tar" ]]; then
        out_file="${DIST_DIR}/${name}.tar.gz"
        # -C to the parent so the archive contains yt-download/<files>
        # Strip macOS extended attributes (quarantine, origin metadata) to avoid
        # "unknown extended header" warnings when extracting on Linux
        if command -v xattr &>/dev/null; then
            xattr -cr "${CACHE_DIR}/stage/${name}"
        fi
        COPYFILE_DISABLE=1 tar -czf "$out_file" -C "${CACHE_DIR}/stage" "$name"
        echo "  -> $out_file"
    else
        out_file="${DIST_DIR}/${name}.zip"
        (cd "${CACHE_DIR}/stage" && zip -qr "$out_file" "$name")
        echo "  -> $out_file"
    fi
}

# ─────────────────────────────────────────────
# Download yt-dlp binaries
# ─────────────────────────────────────────────
YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_TAG}"

info "Fetching yt-dlp binaries"
YTDLP_MACOS="$(    cached_fetch "${YTDLP_BASE}/yt-dlp_macos"           "yt-dlp_macos"           "$YTDLP_TAG")"
YTDLP_LINUX="$(    cached_fetch "${YTDLP_BASE}/yt-dlp_linux"           "yt-dlp_linux"           "$YTDLP_TAG")"
YTDLP_AARCH64="$(  cached_fetch "${YTDLP_BASE}/yt-dlp_linux_aarch64"   "yt-dlp_linux_aarch64"   "$YTDLP_TAG")"
YTDLP_WIN="$(      cached_fetch "${YTDLP_BASE}/yt-dlp.exe"             "yt-dlp.exe"             "$YTDLP_TAG")"
echo "$YTDLP_TAG" > "$YTDLP_VERSION_FILE"

# ─────────────────────────────────────────────
# Download and extract ffmpeg binaries
# ─────────────────────────────────────────────
info "Fetching ffmpeg binaries"

FFMPEG_MACOS_X64_ARCHIVE_PATH="$(     cached_fetch "$FFMPEG_MACOS_X64_URL"                                  "ffmpeg-macos-x64.zip")"
FFMPEG_MACOS_AARCH64_ARCHIVE_PATH="$( cached_fetch "$FFMPEG_MACOS_AARCH64_URL"                              "ffmpeg-macos-aarch64.zip")"
FFPLAY_MACOS_X64_ARCHIVE_PATH="$(     cached_fetch "$FFPLAY_MACOS_X64_URL"                                   "ffplay-macos-x64.zip")"
FFPLAY_MACOS_AARCH64_ARCHIVE_PATH="$( cached_fetch "$FFPLAY_MACOS_AARCH64_URL"                               "ffplay-macos-aarch64.zip")"
FFPROBE_MACOS_X64_ARCHIVE_PATH="$(    cached_fetch "$FFPROBE_MACOS_X64_URL"                                  "ffprobe-macos-x64.zip")"
FFPROBE_MACOS_AARCH64_ARCHIVE_PATH="$(cached_fetch "$FFPROBE_MACOS_AARCH64_URL"                              "ffprobe-macos-aarch64.zip")"
FFMPEG_LINUX_ARCHIVE_PATH="$(         cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_LINUX_ARCHIVE}"           "$FFMPEG_LINUX_ARCHIVE")"
FFMPEG_LINUX_AARCH64_ARCHIVE_PATH="$( cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_LINUX_AARCH64_ARCHIVE}"   "$FFMPEG_LINUX_AARCH64_ARCHIVE")"
FFMPEG_WIN_ARCHIVE_PATH="$(           cached_fetch "${FFMPEG_YTDLP_BASE}/${FFMPEG_WIN_ARCHIVE}"             "$FFMPEG_WIN_ARCHIVE")"

info "Fetching deno binaries"
DENO_MACOS_X64_PATH="$(     cached_fetch "${DENO_BASE}/${DENO_MACOS_X64_ARCHIVE}"       "$DENO_MACOS_X64_ARCHIVE"       "$DENO_VERSION")"
DENO_MACOS_AARCH64_PATH="$( cached_fetch "${DENO_BASE}/${DENO_MACOS_AARCH64_ARCHIVE}"   "$DENO_MACOS_AARCH64_ARCHIVE"   "$DENO_VERSION")"
DENO_LINUX_X64_PATH="$(      cached_fetch "${DENO_BASE}/${DENO_LINUX_X64_ARCHIVE}"       "$DENO_LINUX_X64_ARCHIVE"       "$DENO_VERSION")"
DENO_LINUX_AARCH64_PATH="$( cached_fetch "${DENO_BASE}/${DENO_LINUX_AARCH64_ARCHIVE}"   "$DENO_LINUX_AARCH64_ARCHIVE"   "$DENO_VERSION")"
DENO_WIN_PATH="$(            cached_fetch "${DENO_BASE}/${DENO_WIN_ARCHIVE}"             "$DENO_WIN_ARCHIVE"             "$DENO_VERSION")"

# extract_if_needed: only re-extract if archive is newer than the binary
extract_if_needed() {  # extract_if_needed <archive> <binary_in_archive> <dest> <version>
    local archive="$1" binary="$2" dest="$3" version="$4"
    local version_file="${dest}.version"
    local cached_version=""
    [[ -f "$version_file" ]] && cached_version="$(cat "$version_file")"
    if [[ -f "$dest" && "$cached_version" == "$version" ]]; then
        echo "  (cached) $(basename "$dest") @ $cached_version" >&2
    else
        extract_ffmpeg "$archive" "$binary" "$dest"
        echo "$version" > "$version_file"
    fi
}

info "Extracting ffmpeg binaries"
FFMPEG_MACOS_X64="${CACHE_DIR}/ffmpeg_macos_x64";         extract_ffmpeg "$FFMPEG_MACOS_X64_ARCHIVE_PATH"         "ffmpeg"     "$FFMPEG_MACOS_X64"
FFMPEG_MACOS_AARCH64="${CACHE_DIR}/ffmpeg_macos_aarch64"; extract_ffmpeg "$FFMPEG_MACOS_AARCH64_ARCHIVE_PATH"     "ffmpeg"     "$FFMPEG_MACOS_AARCH64"
FFMPEG_LINUX="${CACHE_DIR}/ffmpeg_linux";                 extract_ffmpeg "$FFMPEG_LINUX_ARCHIVE_PATH"             "ffmpeg"     "$FFMPEG_LINUX"
FFMPEG_LINUX_AARCH64="${CACHE_DIR}/ffmpeg_linux_aarch64"; extract_ffmpeg "$FFMPEG_LINUX_AARCH64_ARCHIVE_PATH"     "ffmpeg"     "$FFMPEG_LINUX_AARCH64"
FFMPEG_WIN="${CACHE_DIR}/ffmpeg.exe";                     extract_ffmpeg "$FFMPEG_WIN_ARCHIVE_PATH"               "ffmpeg.exe" "$FFMPEG_WIN"

info "Extracting ffplay binaries"
# macOS: ffplay is distributed as a separate zip from the same sources as ffmpeg
FFPLAY_MACOS_X64="${CACHE_DIR}/ffplay_macos_x64";         extract_ffmpeg "$FFPLAY_MACOS_X64_ARCHIVE_PATH"         "ffplay"     "$FFPLAY_MACOS_X64"
FFPLAY_MACOS_AARCH64="${CACHE_DIR}/ffplay_macos_aarch64"; extract_ffmpeg "$FFPLAY_MACOS_AARCH64_ARCHIVE_PATH"     "ffplay"     "$FFPLAY_MACOS_AARCH64"
# Linux/Win: ffplay is included in the same archive as ffmpeg
FFPLAY_LINUX="${CACHE_DIR}/ffplay_linux";                 extract_ffmpeg "$FFMPEG_LINUX_ARCHIVE_PATH"             "ffplay"     "$FFPLAY_LINUX"
FFPLAY_LINUX_AARCH64="${CACHE_DIR}/ffplay_linux_aarch64"; extract_ffmpeg "$FFMPEG_LINUX_AARCH64_ARCHIVE_PATH"     "ffplay"     "$FFPLAY_LINUX_AARCH64"
FFPLAY_WIN="${CACHE_DIR}/ffplay.exe";                     extract_ffmpeg "$FFMPEG_WIN_ARCHIVE_PATH"               "ffplay.exe" "$FFPLAY_WIN"

info "Extracting ffprobe binaries"
# macOS: ffprobe is distributed as a separate zip
FFPROBE_MACOS_X64="${CACHE_DIR}/ffprobe_macos_x64";         extract_ffmpeg "$FFPROBE_MACOS_X64_ARCHIVE_PATH"       "ffprobe"     "$FFPROBE_MACOS_X64"
FFPROBE_MACOS_AARCH64="${CACHE_DIR}/ffprobe_macos_aarch64"; extract_ffmpeg "$FFPROBE_MACOS_AARCH64_ARCHIVE_PATH"   "ffprobe"     "$FFPROBE_MACOS_AARCH64"
# Linux/Win: ffprobe is included in the same archive as ffmpeg
FFPROBE_LINUX="${CACHE_DIR}/ffprobe_linux";                 extract_ffmpeg "$FFMPEG_LINUX_ARCHIVE_PATH"             "ffprobe"     "$FFPROBE_LINUX"
FFPROBE_LINUX_AARCH64="${CACHE_DIR}/ffprobe_linux_aarch64"; extract_ffmpeg "$FFMPEG_LINUX_AARCH64_ARCHIVE_PATH"     "ffprobe"     "$FFPROBE_LINUX_AARCH64"
FFPROBE_WIN="${CACHE_DIR}/ffprobe.exe";                     extract_ffmpeg "$FFMPEG_WIN_ARCHIVE_PATH"               "ffprobe.exe" "$FFPROBE_WIN"

info "Extracting deno binaries"
DENO_MACOS_X64="${CACHE_DIR}/deno_macos_x64";         extract_if_needed "$DENO_MACOS_X64_PATH"       "deno"     "$DENO_MACOS_X64"         "$DENO_VERSION"
DENO_MACOS_AARCH64="${CACHE_DIR}/deno_macos_aarch64"; extract_if_needed "$DENO_MACOS_AARCH64_PATH"   "deno"     "$DENO_MACOS_AARCH64"     "$DENO_VERSION"
DENO_LINUX_X64="${CACHE_DIR}/deno_linux_x64";         extract_if_needed "$DENO_LINUX_X64_PATH"       "deno"     "$DENO_LINUX_X64"         "$DENO_VERSION"
DENO_LINUX_AARCH64="${CACHE_DIR}/deno_linux_aarch64"; extract_if_needed "$DENO_LINUX_AARCH64_PATH"   "deno"     "$DENO_LINUX_AARCH64"     "$DENO_VERSION"
DENO_WIN="${CACHE_DIR}/deno.exe";                     extract_if_needed "$DENO_WIN_PATH"             "deno.exe" "$DENO_WIN"               "$DENO_VERSION"

# ─────────────────────────────────────────────
# Assemble bundles
# ─────────────────────────────────────────────
# macOS and Linux use tar.gz (preserves executable bits natively)
# Windows uses zip (Git Bash users expect it)

# deno bundled for all platforms -- full binary from GitHub releases
make_bundle "yt-download_macos_x64"     tar  "$YTDLP_MACOS"   "$FFMPEG_MACOS_X64"     "$FFPLAY_MACOS_X64"     "$FFPROBE_MACOS_X64"     "$DENO_MACOS_X64"
make_bundle "yt-download_macos_aarch64" tar  "$YTDLP_MACOS"   "$FFMPEG_MACOS_AARCH64" "$FFPLAY_MACOS_AARCH64" "$FFPROBE_MACOS_AARCH64" "$DENO_MACOS_AARCH64"
make_bundle "yt-download_linux_x64"     tar  "$YTDLP_LINUX"   "$FFMPEG_LINUX"         "$FFPLAY_LINUX"         "$FFPROBE_LINUX"         "$DENO_LINUX_X64"
make_bundle "yt-download_linux_aarch64" tar  "$YTDLP_AARCH64" "$FFMPEG_LINUX_AARCH64" "$FFPLAY_LINUX_AARCH64" "$FFPROBE_LINUX_AARCH64" "$DENO_LINUX_AARCH64"
make_bundle "yt-download_windows"       zip  "$YTDLP_WIN"     "$FFMPEG_WIN"           "$FFPLAY_WIN"           "$FFPROBE_WIN"           "$DENO_WIN"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
info "All bundles ready in dist/"
ls -lh "$DIST_DIR"
