# yt-download.sh

A bash script to download YouTube videos, music, playlists, and entire channels — with automatic subtitle embedding and sane filenames across all platforms.

## Features

- Downloads single videos, music, playlists, or whole channels
- Automatically downloads and manages [yt-dlp](https://github.com/yt-dlp/yt-dlp) — no manual setup needed
- Embeds English subtitles as `.srt` into the video file
- Best available MP4 quality, with audio
- Best available MP3 quality
- Filenames safe on Windows (NTFS/exFAT), macOS (APFS/HFS+), and Linux (ext4)
- Channel downloads are automatically organised into a named folder
- Works on macOS, Linux, and Windows (Git Bash, Cygwin)

## Requirements

- **bash** (macOS/Linux: built-in; Windows: [Git for Windows](https://git-scm.com/download/win))
- **curl** or **wget** to download yt-dlp on first run
  - macOS: `curl` is always present
  - Linux: one or both are usually present; if not: `sudo apt install curl`
  - Windows/Git Bash: `curl` ships with Windows 10 1803+ and is available in Git Bash
- **ffmpeg** for audio-only processing. Not required when downloading videos.
  - macOS: install via `brew install ffmpeg`
  - Linux: install via `sudo apt install ffmpeg`
  - Windows/Git Bash: download `ffmpeg-release-essentials.zip` from [FFmpeg Builds binaries for Windows](https://www.gyan.dev/ffmpeg/builds/)

yt-dlp itself is downloaded automatically on first run to `~/.local/bin/`.

## Usage

```
./yt-download.sh [options] <URL>
```

### Options

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Download full playlists without prompting |
| `-u`, `--update` | Update yt-dlp to the latest release before running |
| `-a`, `--audio` | Download audio only as MP3 (no video, no subtitles) |
| `-o`, `--output DIR` | Save files into `DIR` (default: current directory, or channel name for channel URLs) |
| `-h`, `--help` | Show usage |

## Examples

**Download a single video:**
```bash
./yt-download.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

**Download a single video, audio only:**
```bash
./yt-download.sh --audio "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
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

**Update yt-dlp then download:**
```bash
./yt-download.sh --update "https://www.youtube.com/@BedtimeHistory/playlists"
```

## Output Structure

| URL type | Output path |
|----------|-------------|
| Single video | `Video Title.mp4` |
| Single audio | `Video Title.mp3` |
| Playlist | `Playlist Title/001-Video Title.mp4` |
| Channel (no `-o` given) | `ChannelName/Playlist Title/001-Video Title.mp4` |
| Any URL with `-o ~/Videos` | `~/Videos/Playlist Title/001-Video Title.mp4` |
| Single video with `-a` | `Video Title.mp3` |
| Playlist with `-a` | `Playlist Title/001-Video Title.mp3` |

## First Run

On first run, the script detects your platform and downloads the appropriate yt-dlp binary from GitHub:

| Platform | Binary |
|----------|--------|
| Linux x86_64 | `yt-dlp_linux` |
| Linux ARM64 | `yt-dlp_linux_aarch64` |
| macOS | `yt-dlp_macos` |
| Windows x86_64 (Git Bash) | `yt-dlp.exe` |
| Windows ARM64 (Git Bash) | `yt-dlp_arm64.exe` |

If yt-dlp is already installed and on your `PATH`, the system version is used instead.

## Keeping yt-dlp Up to Date

YouTube changes frequently, and old versions of yt-dlp can stop working. Run with `-u` periodically:

```bash
./yt-download.sh --update "https://..."
```

## License

MIT — use freely, modify as needed.


