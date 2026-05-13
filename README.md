# yt-download.sh

A bash script to download YouTube videos, playlists, and entire channels — with automatic subtitle embedding and sane filenames across all platforms.

## Features

- Downloads single videos, playlists, or whole channels
- Automatically downloads and manages [yt-dlp](https://github.com/yt-dlp/yt-dlp) — no manual setup needed
- Embeds English subtitles as `.srt` into the video file
- Best available MP4 quality, with audio
- Audio-only MP3 download mode
- Filenames safe on Windows (NTFS/exFAT), macOS (APFS/HFS+), and Linux (ext4)
- Channel downloads are automatically organised into a named folder
- Jellyfin-compatible download mode with `info.json` and thumbnail sidecars
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
| `yt-download_macos_x64.tar.gz` | yt-dlp, ffmpeg, deno |
| `yt-download_macos_aarch64.tar.gz` | yt-dlp, ffmpeg, deno (Apple Silicon) |
| `yt-download_linux_x64.tar.gz` | yt-dlp, ffmpeg, deno |
| `yt-download_linux_aarch64.tar.gz` | yt-dlp, ffmpeg, deno |
| `yt-download_windows.zip` | yt-dlp, ffmpeg, deno |

Extract the archive for your platform and run `yt-download.sh` from the extracted folder. No other setup required.

**Standalone** (`yt-download.sh` on its own): yt-dlp is downloaded automatically on first run to `~/.local/bin/`. ffmpeg and deno must be installed separately (see below).

## Usage

```
./yt-download.sh [options] <URL>
```

### Options

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Download full playlists without prompting |
| `-u`, `--update` | Update yt-dlp and deno to their latest releases before running |
| `-a`, `--audio` | Download audio only as MP3 (no video, no subtitles) |
| `-j`, `--jellyfin` | Jellyfin-compatible filenames + save `info.json` and thumbnail sidecar |
| `-o`, `--output DIR` | Save files into `DIR` (default: current directory, or channel name for channel URLs) |
| `-c`, `--cookies FILE` | Use a Netscape `cookies.txt` file for authentication |
| `-b`, `--browser BROWSER` | Use cookies from browser: `chrome`, `firefox`, `safari`, `edge` |
| `-h`, `--help` | Show usage |

## Examples

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

**Download a whole playlist as MP3:**
```bash
./yt-download.sh -a -y "https://www.youtube.com/playlist?list=PLxxxxxxx"
```

**Download a channel for Jellyfin:**
```bash
./yt-download.sh --jellyfin --yes "https://www.youtube.com/@BedtimeHistory/playlists"
```

**Update yt-dlp and deno, then download:**
```bash
./yt-download.sh --update "https://www.youtube.com/@BedtimeHistory/playlists"
```

## Authentication (Sign-in / Bot Detection)

Some videos or channels require sign-in, or YouTube may block downloads with a "Sign in to confirm you're not a bot" error. When this happens the script aborts immediately rather than continuing to fail on every subsequent video.

Pass your browser cookies to authenticate:

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

Export a Netscape-format `cookies.txt` using a browser extension such as [cookies.txt](https://chrome.google.com/webstore/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) (Chrome) or [cookies.txt](https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/) (Firefox). Useful for server or headless setups where no browser is available.

> **Tip:** If you see bot errors regularly, running `-b chrome` (or your preferred browser) is the most reliable long-term fix. YouTube is more likely to trust cookies from a real browser session.

## Output Structure


| URL type | Output path |
|----------|-------------|
| Single video | `Video Title.mp4` |
| Playlist | `Playlist Title/001-Video Title.mp4` |
| Channel (no `-o` given) | `ChannelName/Playlist Title/001-Video Title.mp4` |
| Any URL with `-o ~/Videos` | `~/Videos/Playlist Title/001-Video Title.mp4` |
| Single video with `-a` | `Video Title.mp3` |
| Playlist with `-a` | `Playlist Title/001-Video Title.mp3` |
| Single video with `-j` | `Channel - 20211023 - Video Title [VideoID].mp4` |
| Playlist with `-j` | `Playlist Title/Channel - 20211023 - Video Title [VideoID].mp4` |

## Jellyfin Integration

The `--jellyfin` / `-j` flag produces filenames compatible with the [jellyfin-youtube-metadata-plugin](https://github.com/ankenyr/jellyfin-youtube-metadata-plugin).

**What changes with `-j`:**

- Filenames follow the required `Channel - YYYYMMDD - Title [VideoID].ext` format
- An `info.json` sidecar is saved alongside each video — Jellyfin reads this for metadata (title, description, upload date, channel)
- A `.jpg` thumbnail is saved with the same base filename — Jellyfin uses this as the poster image

**Example output for a playlist:**
```
BedtimeHistory/
  Bedtime History - 20231015 - The History of Rome [abc123XYZ].mp4
  Bedtime History - 20231015 - The History of Rome [abc123XYZ].info.json
  Bedtime History - 20231015 - The History of Rome [abc123XYZ].jpg
```

> **Note:** Jellyfin mode requires ffmpeg for thumbnail conversion to `.jpg`. This is included in the macOS and Windows bundles. Linux users: `sudo apt install ffmpeg`.

## JavaScript Runtime (deno)

yt-dlp uses a JavaScript runtime to access the full range of YouTube clients and video formats. The macOS and Windows bundles include deno — no extra setup needed.

Without a JS runtime, the script automatically falls back to `tv_embedded,ios,web` clients, which works well but may occasionally miss formats or show warnings.

**Priority order at startup:**
1. Bundled deno (macOS and Windows bundles) — used automatically via `--js-runtimes`
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

## Keeping Everything Up to Date

YouTube changes frequently, and old versions of yt-dlp and deno can stop working. Run with `-u` periodically to update both at once:

```bash
./yt-download.sh --update "https://..."
```

This updates:
- **yt-dlp** — updated in place (bundled copy or `~/.local/bin/`)
- **deno** — updated in place if bundled; skipped if using a system install (use your package manager for that)

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

Option 3 — Group Policy: `Computer Configuration → Administrative Templates → System → Filesystem → Enable Win32 long paths`

A restart or sign-out may be required.

> **Tip:** When installing [Git for Windows](https://git-scm.com/download/win), the installer includes an option to enable long paths — make sure to tick it.
