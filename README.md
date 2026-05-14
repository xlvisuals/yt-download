# yt-download suite

A set of bash scripts to download and organise YouTube videos, playlists, and channels — with sane filenames across all platforms.

## Scripts

- **`yt-download.sh`** — downloads videos, playlists, and channels
- **`yt-rename.sh`** — renames downloaded files using `.info.json` sidecar metadata

## Features

- Downloads single videos, playlists, or whole channels
- Automatically downloads and manages [yt-dlp](https://github.com/yt-dlp/yt-dlp) — no manual setup needed
- Embeds English subtitles as `.srt` into the video file
- Best available MP4 quality, with audio
- Audio-only MP3 download mode
- Flexible filename control — index, channel name, VideoID, all optional
- Saves `.info.json` and thumbnail sidecars for Jellyfin and similar media servers
- Filenames safe on Windows (NTFS/exFAT), macOS (APFS/HFS+), and Linux (ext4)
- Channel downloads are automatically organised into a named folder
- Bundles include ffmpeg and deno — no separate installs needed on macOS and Windows
- Detects and aborts on YouTube bot/sign-in errors with clear instructions
- Cookie-based authentication via browser profile or cookies.txt file
- Works on macOS, Linux, Windows (Git Bash and Cygwin)

## Requirements

- **bash** (macOS/Linux: built-in; Windows: [Git for Windows](https://git-scm.com/download/win))
- **curl** or **wget** to download yt-dlp on first run (only needed if not using a bundle)
  - macOS: `curl` is always present
  - Linux: one or both are usually present; if not: `sudo apt install curl`
  - Windows/Git Bash: `curl` ships with Windows 10 1803+ and is available in Git Bash

## Bundles vs Standalone

**Bundles** (recommended for most users) are available on the [releases page](../../releases) and include everything needed:

| Bundle | Includes |
|--------|----------|
| `yt-download_macos_x64.tar.gz` | yt-download.sh, yt-rename.sh, yt-dlp, ffmpeg, deno |
| `yt-download_macos_aarch64.tar.gz` | yt-download.sh, yt-rename.sh, yt-dlp, ffmpeg, deno (Apple Silicon) |
| `yt-download_linux_x64.tar.gz` | yt-download.sh, yt-rename.sh, yt-dlp, ffmpeg, deno |
| `yt-download_linux_aarch64.tar.gz` | yt-download.sh, yt-rename.sh, yt-dlp, ffmpeg, deno |
| `yt-download_windows.zip` | yt-download.sh, yt-rename.sh, yt-dlp, ffmpeg, deno |

Extract the archive for your platform and run the scripts from the extracted folder. No other setup required.

**Standalone** (`yt-download.sh` on its own): yt-dlp is downloaded automatically on first run to `~/.local/bin/`. ffmpeg and deno must be installed separately (see below).

---

## yt-download.sh

### Usage

```
./yt-download.sh [options] <URL>
```

### Options

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Download full playlists without prompting |
| `-u`, `--update` | Update yt-dlp and deno before running (URL optional) |
| `-a`, `--audio` | Download audio only as MP3 (no video, no subtitles) |
| `-s`, `--sidecar` | Save `.info.json` and thumbnail alongside each video |
| `--prefix-index` | Prefix playlist index to filename: `001 - Title.mp4` |
| `--postfix-index` | Postfix playlist index to filename: `Title - 001.mp4` |
| `--append-channel` | Append channel name to title: `Title - Channel.mp4` |
| `--keep-id` | Keep `[VideoID]` at end of filename |
| `-o`, `--output DIR` | Save files into `DIR` (default: current directory, or channel name for channel URLs) |
| `-c`, `--cookies FILE` | Use a Netscape `cookies.txt` file for authentication |
| `-b`, `--browser BROWSER` | Use cookies from browser: `chrome`, `firefox`, `safari`, `edge` |
| `-h`, `--help` | Show usage |

### Examples

**Download a single video:**
```bash
./yt-download.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

**Download a playlist:**
```bash
./yt-download.sh "https://www.youtube.com/playlist?list=PLxxxxxxx"
```

**Download a URL that contains both a video and a playlist ID** (script will ask which you want):
```bash
./yt-download.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxxxxxxx"
```

**Download an entire channel's playlists, without prompting:**
```bash
./yt-download.sh --yes "https://www.youtube.com/@BedtimeHistory/playlists"
```

**Download a channel into a specific directory:**
```bash
./yt-download.sh -o ~/Videos "https://www.youtube.com/@BedtimeHistory/playlists"
```

**Download audio only (MP3):**
```bash
./yt-download.sh --audio "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

**Download with sidecars for Jellyfin, keeping VideoID:**
```bash
./yt-download.sh --sidecar --keep-id --yes "https://www.youtube.com/@BedtimeHistory/playlists"
# -> Some Video Title [VideoID].mp4
#    Some Video Title [VideoID].info.json
#    Some Video Title [VideoID].jpg
```

**Download with channel name and VideoID appended:**
```bash
./yt-download.sh --sidecar --append-channel --keep-id --yes "https://..."
# -> Some Video Title - Bedtime History [VideoID].mp4
```

**Update yt-dlp and deno only:**
```bash
./yt-download.sh --update
```

### Output Structure

| URL type | Output path |
|----------|-------------|
| Single video | `Video Title.mp4` |
| Playlist | `Playlist Title/Video Title.mp4` |
| Playlist with `--prefix-index` | `Playlist Title/001 - Video Title.mp4` |
| Channel (no `-o` given) | `ChannelName/Playlist Title/Video Title.mp4` |
| With `--keep-id` | `Video Title [VideoID].mp4` |
| With `--append-channel --keep-id` | `Video Title - Channel [VideoID].mp4` |
| With `-a` | `Video Title.mp3` |

---

## yt-rename.sh

Renames files downloaded with `--sidecar`, stripping the `Channel - Date -` prefix and optionally adding index, channel name, and VideoID. Reads metadata from the `.info.json` sidecar. Renames all companion files (`.info.json`, `.jpg`, `.srt`) together.

### Usage

```
./yt-rename.sh [options] <directory>
```

### Options

| Flag | Description |
|------|-------------|
| `-n`, `--dry-run` | Show what would be renamed without doing anything |
| `--prefix-index` | Prefix episode number: `001 - Title.mp4` |
| `--postfix-index` | Postfix episode number: `Title - 001.mp4` |
| `--append-channel` | Append channel name if not already in title |
| `--keep-id` | Keep `[VideoID]` at end of filename |
| `-h`, `--help` | Show usage |

### Examples

```bash
# Preview what would change
./yt-rename.sh --dry-run ./BedtimeHistory

# Strip Channel/Date prefix, keep VideoID
./yt-rename.sh --keep-id ./BedtimeHistory
# "Bedtime History - 20251128 - Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"
# -> "Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"

# Full Jellyfin-friendly rename with channel appended
./yt-rename.sh --append-channel --keep-id ./BedtimeHistory
# -> "Henry Hudson's Journey Made Easy - Bedtime History [6748DOW_Xps].mp4"

# With episode index prefix
./yt-rename.sh --prefix-index --keep-id ./BedtimeHistory
# -> "001 - Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"
```

> **Note:** `--append-channel` skips appending if the channel name is already present in the title (case-insensitive).

### Typical Jellyfin workflow

```bash
# 1. Download with sidecars
./yt-download.sh --sidecar --keep-id --yes "https://www.youtube.com/@BedtimeHistory/playlists"

# 2. Rename for clean display in Jellyfin
./yt-rename.sh --append-channel --keep-id ./BedtimeHistory
```

---

## Authentication (Sign-in / Bot Detection)

Some videos or channels require sign-in, or YouTube may block downloads with a "Sign in to confirm you're not a bot" error. When this happens the script aborts immediately rather than continuing to fail on every subsequent video.

**From a browser (easiest):**
```bash
./yt-download.sh -b chrome "https://..."
./yt-download.sh -b firefox "https://..."
./yt-download.sh -b safari "https://..."
./yt-download.sh -b edge "https://..."
```

yt-dlp reads the cookies directly from your browser's profile. The browser must be installed on the same machine.

**From a cookies.txt file:**
```bash
./yt-download.sh -c ~/cookies.txt "https://..."
```

Export a Netscape-format `cookies.txt` using a browser extension such as [cookies.txt](https://chrome.google.com/webstore/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) (Chrome) or [cookies.txt](https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/) (Firefox).

> **Tip:** If you see bot errors regularly, running `-b chrome` (or your preferred browser) is the most reliable long-term fix. YouTube is more likely to trust cookies from a real browser session.

---

## JavaScript Runtime (deno)

yt-dlp uses a JavaScript runtime to access the full range of YouTube clients and video formats. All bundles include deno — no extra setup needed.

Without a JS runtime, the script automatically falls back to `mweb,ios` clients, which works well but may occasionally miss formats or show warnings.

**Priority order at startup:**
1. Bundled deno — used automatically via `--js-runtimes`
2. System deno/node/phantomjs on PATH — detected automatically
3. No runtime found — falls back to limited client list with an info message

**Installing deno manually** (if running the standalone script):

Linux:
```bash
curl -fsSL https://deno.land/install.sh | sh
```

macOS (if not using the bundle):
```bash
brew install deno
```

Windows (PowerShell, if not using the bundle):
```powershell
irm https://deno.land/install.ps1 | iex
```

> **Note:** All bundles include the full `deno` binary from the [official GitHub releases](https://github.com/denoland/deno/releases). This is distinct from `dl.deno.land` which ships `denort` (a slim compile-only runtime) for Linux.

---

## Keeping Everything Up to Date

YouTube changes frequently, and old versions of yt-dlp and deno can stop working. Run with `-u` periodically:

```bash
./yt-download.sh --update
```

This updates:
- **yt-dlp** — updated in place (bundled copy or `~/.local/bin/`)
- **deno** — updated in place if bundled; skipped if using a system install (use your package manager for that)

---

## Windows and Long File Paths

Windows has a 260-character path length limit (MAX_PATH) which can cause failures with deeply nested or long-titled downloads.

The script tests this automatically by creating a temporary file with a path longer than 260 characters. If the OS rejects it, filenames are trimmed to 200 characters. If it succeeds, filenames are left at full length.

**To enable long path support on Windows 10 1607+ (recommended):**

Option 1 — Registry (run as Administrator in CMD or Git Bash):
```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
```

Option 2 — Registry (run as Administrator in PowerShell):
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1
```

Option 3 — Group Policy: `Computer Configuration -> Administrative Templates -> System -> Filesystem -> Enable Win32 long paths`

A restart or sign-out may be required.

> **Tip:** When installing [Git for Windows](https://git-scm.com/download/win), the installer includes an option to enable long paths — make sure to tick it.
