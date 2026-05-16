# yt-download suite

A set of bash scripts to download and organise YouTube videos, playlists, and channels — with sane filenames across all platforms.

## Scripts

- **`yt-download.sh`** — downloads video, videos, shorts, playlists, or whole channel - including artwork
- **`yt-rename.sh`** — renames downloaded files using `.info.json` sidecar metadata
- **`yt-nfo.sh`** — generates Jellyfin `season.nfo` and `tvshow.nfo` files to fix season numbering

## Features

- Downloads single videos, playlists, or whole channels
- Downloads are compatible with [jellyfin-youtube-metadata-plugin](https://github.com/ankenyr/jellyfin-youtube-metadata-plugin) and [jf-ytdlp-info-reader-plugin](https://github.com/ArabCoders/jf-ytdlp-info-reader-plugin/)
- Automatically downloads and manages [yt-dlp](https://github.com/yt-dlp/yt-dlp) — no manual setup needed
- Embeds English subtitles as `.srt` into the video file
- Best available MP4 quality, with audio
- Audio-only MP3 download mode
- Flexible filename control — index, channel name, VideoID, all optional
- `--jellyfin` shortcut for a complete Jellyfin-ready download in one flag
- Downloads channel playlists, videos, and shorts -- separately or all at once
- Saves `.info.json` and thumbnail sidecars for Jellyfin and similar media servers
- Generates Jellyfin `season.nfo` files to fix incorrect season numbering
- Saves `poster.jpg` in channel and playlist folders for series/season artwork
- Skips private or unavailable videos and continues the playlist
- Filenames safe on Windows (NTFS/exFAT), macOS (APFS/HFS+), and Linux (ext4)
- Channel downloads are automatically organised into a named folder
- Bundles include ffmpeg and deno — no separate installs needed on macOS and Windows
- Detects and aborts on YouTube bot/sign-in errors with clear instructions
- Cookie-based authentication via browser profile or cookies.txt file
- Writes timestamped log files for easy debugging
- `--cleanup` removes playlist folders with no media files after download
- Works on macOS, Linux, Windows (Git Bash, Cygwin, and WSL)

## Requirements

- **bash** (macOS/Linux: built-in; Windows: [Git for Windows](https://git-scm.com/download/win) or WSL)
- **curl** or **wget** to download yt-dlp on first run (only needed if not using a bundle)
  - macOS: `curl` is always present
  - Linux / WSL: one or both are usually present; if not: `sudo apt install curl`
  - Windows/Git Bash: `curl` ships with Windows 10 1803+ and is available in Git Bash

## Bundles vs Standalone

**Bundles** (recommended for most users) are available on the [releases page](../../releases) and include everything needed:

| Bundle | Includes |
|--------|----------|
| `yt-download_macos_x64.tar.gz` | yt-download.sh, yt-rename.sh, yt-nfo.sh, yt-dlp, ffmpeg, deno |
| `yt-download_macos_aarch64.tar.gz` | yt-download.sh, yt-rename.sh, yt-nfo.sh, yt-dlp, ffmpeg, deno (Apple Silicon) |
| `yt-download_linux_x64.tar.gz` | yt-download.sh, yt-rename.sh, yt-nfo.sh, yt-dlp, ffmpeg, deno |
| `yt-download_linux_aarch64.tar.gz` | yt-download.sh, yt-rename.sh, yt-nfo.sh, yt-dlp, ffmpeg, deno |
| `yt-download_windows.zip` | yt-download.sh, yt-rename.sh, yt-nfo.sh, yt-dlp, ffmpeg, deno |

Extract the archive for your platform and run the scripts from the extracted folder. No other setup required.

**Standalone** (`yt-download.sh` on its own): yt-dlp is downloaded automatically on first run to `~/.local/bin/`. ffmpeg and deno must be installed separately (see below).

> **WSL users:** Use the Linux bundle (`yt-download_linux_x64.tar.gz` or `yt-download_linux_aarch64.tar.gz`). WSL is essentially Ubuntu and works identically to native Linux.

---

## yt-download.sh

### Usage

```
./yt-download.sh [options] <URL>
```

### Options

| Flag                      | Description                                                                                            |
|---------------------------|--------------------------------------------------------------------------------------------------------|
| `-y`, `--yes`             | Download without prompting; downloads all (playlists, videos, shorts) when a bare channel URL is given |
| `-u`, `--update`          | Update yt-dlp and deno before running (URL optional)                                                   |
| `-a`, `--audio`           | Download audio only as MP3 (no video, no subtitles)                                                    |
| `-j`, `--jellyfin`        | Shortcut for `--sidecar --append-channel --keep-id --yes --cleanup`                                    |
| `-s`, `--sidecar`         | Save `.info.json` and thumbnail alongside each video                                                   |
| `-p`, `--posters-only`    | Download folder poster images only, no videos                                                          |
| `-m`, `--max N`           | Stop after N videos per playlist (useful for testing)                                                  |
| `--prefix-index`          | Prefix playlist index to filename: `001 - Title.mp4`                                                   |
| `--postfix-index`         | Postfix playlist index to filename: `Title - 001.mp4`                                                  |
| `--append-channel`        | Append channel name to title (if not already present)                                                  |
| `--keep-id`               | Keep `[VideoID]` at end of filename                                                                    |
| `-o`, `--output DIR`      | Save files into `DIR` (default: current directory, or channel name for channel URLs)                   |
| `-l`, `--log DIR`         | Write log to `DIR/yt-download-TIMESTAMP.log` (default: current directory)                              |
| `--cleanup`               | Remove empty playlist folders after download (no media files AND under 2MB)                            |
| `-c`, `--cookies FILE`    | Use a Netscape `cookies.txt` file for authentication                                                   |
| `-b`, `--browser BROWSER` | Use cookies from browser: `chrome`, `firefox`, `safari`, `edge`                                        |
| `-h`, `--help`            | Show usage                                                                                             |

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

**Download a channel's playlists:**
```bash
./yt-download.sh --yes "https://www.youtube.com/@BedtimeHistory/playlists"
```

**Download a channel's videos or shorts:**
```bash
./yt-download.sh "https://www.youtube.com/@BedtimeHistory/videos"
./yt-download.sh "https://www.youtube.com/@BedtimeHistory/shorts"
```

**Download everything from a channel (prompts for playlists/videos/shorts):**
```bash
./yt-download.sh "https://www.youtube.com/@BedtimeHistory"
# Script will ask: Download playlists? videos? shorts?

# Or download all without prompting:
./yt-download.sh --yes "https://www.youtube.com/@BedtimeHistory"
```

**Download a channel for Jellyfin (recommended):**
```bash
./yt-download.sh --jellyfin "https://www.youtube.com/@BedtimeHistory"
# Equivalent to:
./yt-download.sh --sidecar --append-channel --keep-id --yes "https://www.youtube.com/@BedtimeHistory"
# With --yes / --jellyfin on a bare channel URL, all playlists, videos, and shorts are downloaded.
```

**Download a channel into a specific directory:**
```bash
./yt-download.sh -o ~/Videos "https://www.youtube.com/@BedtimeHistory/playlists"
```

**Download audio only (MP3):**
```bash
./yt-download.sh --audio "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

**Test with just 3 videos per playlist:**
```bash
./yt-download.sh --jellyfin --max 3 "https://www.youtube.com/@BedtimeHistory"
```

**Fetch folder poster images for an already-downloaded channel:**
```bash
./yt-download.sh --posters-only --browser firefox "https://www.youtube.com/@BedtimeHistory"
```

**Write a log file:**
```bash
./yt-download.sh --jellyfin --log ~/logs "https://www.youtube.com/@BedtimeHistory"
# Writes ~/logs/yt-download-20260516-143022.log
```

**Download and clean up empty playlist folders afterwards:**
```bash
./yt-download.sh --jellyfin --cleanup "https://www.youtube.com/@BedtimeHistory"
```

A folder is only removed if **both** conditions are true:
- Contains no media files (`.mp4`, `.mkv`, `.webm`, `.m4a`, `.mp3`, `.opus`)
- Is under 2MB total — safety net to prevent accidental deletion of folders with videos, songs, or ebooks

A folder containing only `poster.jpg` and `season.nfo` (typically a few hundred KB) will be removed.
A folder with any media file, or anything over 2MB, is left untouched regardless.
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
| With `--jellyfin` | `ChannelName/Playlist Title/Video Title - Channel [VideoID].mp4` |
| Channel `/videos` | `ChannelName/ChannelName - Videos/Video Title.mp4` |
| Channel `/shorts` | `ChannelName/ChannelName - Shorts/Video Title.mp4` |
| With `-a` | `Video Title.mp3` |

### Jellyfin Workflow

The `--jellyfin` flag is the recommended way to download channels for use with [jellyfin-youtube-metadata-plugin](https://github.com/ankenyr/jellyfin-youtube-metadata-plugin) 
and [jf-ytdlp-info-reader-plugin](https://github.com/ArabCoders/jf-ytdlp-info-reader-plugin/).
It combines several flags into one: --sidecar, --append-channel, --keep-id, and --yes:

```bash
./yt-download.sh --jellyfin "https://www.youtube.com/@BedtimeHistory"
```

This single command:
- Downloads all playlists, videos, and shorts without prompting
- Saves `.info.json` and `.jpg` sidecar files alongside each video
- Appends the channel name to each video title (with deduplication)
- Keeps `[VideoID]` in each filename for reliable Jellyfin matching
- Saves `poster.jpg` in each playlist folder and the channel root
- Writes `tvshow.nfo` and `season.nfo` files for correct Jellyfin season numbering
- Skips private or unavailable videos and continues

If you get authentication error, you might need to sign into YouTube in your browser and provider the --browser parameter:

```bash
./yt-download.sh --browser firefox --jellyfin "https://www.youtube.com/@BedtimeHistory"
```
See **Authentication (Sign-in / Bot Detection)** below for details.


**Fixing up an existing download:**
```bash
./yt-rename.sh --jellyfin --all ~/Videos
./yt-nfo.sh --all ~/Videos
./yt-download.sh --posters-only --yes "https://www.youtube.com/@BedtimeHistory"
```

---

## yt-rename.sh

Renames YouTube sidecar files using metadata from `.info.json`. Handles both Jellyfin-style (`Channel - Date - Title [VideoID]`) and clean (`Title [VideoID]`) filenames. Strips the `Channel - Date -` prefix if present, and optionally adds index, channel name, and VideoID. Renames all companion files (`.info.json`, `.jpg`, `.srt`) together.

### Usage

```
./yt-rename.sh [options] <directory>
```

### Options

| Flag | Description |
|------|-------------|
| `-n`, `--dry-run` | Show what would be renamed without doing anything |
| `-a`, `--all` | Process every subfolder in `DIR` as a separate channel |
| `--prefix-index` | Prefix episode number: `001 - Title.mp4` |
| `--postfix-index` | Postfix episode number: `Title - 001.mp4` |
| `--append-channel` | Append channel name if not already in title |
| `--keep-id` | Keep `[VideoID]` at end of filename |
| `--jellyfin` | Shortcut for `--append-channel --keep-id` (clears any index flags) |
| `-l`, `--log DIR` | Write log to `DIR/yt-rename-TIMESTAMP.log` (default: current directory) |
| `-h`, `--help` | Show usage |

### Examples

```bash
# Preview what would change
./yt-rename.sh --dry-run ./BedtimeHistory

# Jellyfin-ready rename (append channel + keep VideoID)
./yt-rename.sh --jellyfin ./BedtimeHistory
# "Bedtime History - 20251128 - Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"
# -> "Henry Hudson's Journey Made Easy - Bedtime History [6748DOW_Xps].mp4"

# Also works on already-clean filenames (Title [VideoID].mp4)
# -> "Title - Bedtime History [VideoID].mp4"

# Process all channels in a folder at once
./yt-rename.sh --jellyfin --all ~/Videos
./yt-rename.sh --jellyfin --all .    # current directory

# Strip Channel/Date prefix, keep VideoID (without appending channel)
./yt-rename.sh --keep-id ./BedtimeHistory
# "Bedtime History - 20251128 - Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"
# -> "Henry Hudson's Journey Made Easy [6748DOW_Xps].mp4"
```

> **Note:** `--append-channel` and `--jellyfin` skip appending if the channel name is already present in the title (case-insensitive). Both the Jellyfin-style `Channel - Date - Title [VideoID]` format and the clean `Title [VideoID]` format are supported.

---

## yt-nfo.sh

Generates Jellyfin-compatible `season.nfo` and `tvshow.nfo` files in a YouTube channel download folder.

Without these files, Jellyfin infers season numbers from `playlist_index` in the video `info.json`, producing wrong "Season 1", "Season 44" etc. for channels with many playlists. `yt-nfo.sh` writes explicit `season.nfo` files with sequential season numbers (1, 2, 3...) and the playlist folder name as the season title.

> **Note:** When using `--jellyfin`, these files are generated automatically. `yt-nfo.sh` is for fixing existing downloads or re-generating after adding new playlists.

### Usage

```
./yt-nfo.sh [options] <directory>
```

### Options

| Flag | Description |
|------|-------------|
| `-n`, `--dry-run` | Show what would be written without doing anything |
| `-f`, `--force` | Overwrite existing `.nfo` files (use after adding new playlists) |
| `-a`, `--all` | Process every subfolder in `DIR` as a separate channel |
| `-l`, `--log DIR` | Write log to `DIR/yt-nfo-TIMESTAMP.log` (default: current directory) |
| `-h`, `--help` | Show usage |

### Examples

```bash
# Generate nfo files for one channel
./yt-nfo.sh ~/Videos/ChessKidOfficial

# Process all channels in a folder at once
./yt-nfo.sh --all ~/Videos
./yt-nfo.sh --all .           # current directory

# Regenerate after adding new playlists
./yt-nfo.sh --force ~/Videos/ChessKidOfficial
./yt-nfo.sh --all --force ~/Videos
```

After running, do a **Refresh Metadata** in Jellyfin (with "Replace all existing metadata" checked) on the library to apply the new season numbers.

### What it creates

```
ChessKidOfficial/
  tvshow.nfo                <- series title for Jellyfin
  poster.jpg                <- channel artwork
  Beginner Lessons/
    season.nfo              <- Season 1: Beginner Lessons
    poster.jpg              <- playlist artwork
    video [VideoID].mp4
  Opening Traps/
    season.nfo              <- Season 2: Opening Traps
    poster.jpg              <- playlist artwork
    video [VideoID].mp4
```

---

## Authentication (Sign-in / Bot Detection)

Some videos or channels require sign-in, or YouTube may block downloads with a "Sign in to confirm you're not a bot" error. When this happens the script aborts immediately rather than continuing to fail on every subsequent video. Private or unavailable videos within a playlist are skipped automatically.

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
