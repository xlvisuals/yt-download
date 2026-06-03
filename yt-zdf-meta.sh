#!/usr/bin/env bash
# yt-zdf-meta.sh -- Write Jellyfin NFO files for ZDF downloads
#
# Recursively searches a ZDF download directory for .info.json files and
# writes Jellyfin-compatible NFO files:
#
#   Movies   (season_number: null) -- fetches the ZDF movie page to extract
#            genre, year, FSK rating, runtime, and description. Writes a
#            <movie> NFO alongside the video file.
#
#   Episodes (season_number: set)  -- reads metadata directly from the
#            info.json. Writes an <episodedetails> NFO alongside the video file.
#
# Works on Linux, macOS (BSD grep/sed) and Windows (Cygwin/Git Bash).
# Safe to re-run -- existing NFO files are skipped unless --force is set.
#
# FIXED: Use grep for ZDF detection, Python stdin for data extraction (no encoding issues)

set -euo pipefail

trap 'echo "Error: script aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/yt-common.sh"

DRY_RUN=false
FORCE=false
LOG_DIR=""
TARGET_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Write Jellyfin NFO files for ZDF downloads (movies and episodes).

Options:
  -n, --dry-run   Show what would be written without doing anything
  -f, --force     Overwrite existing .nfo files
  -l, --log DIR   Write log to DIR/yt-zdf-meta-TIMESTAMP.log
  -h, --help      Show this help

Examples:
  $(basename "$0") ~/Videos/ZDF\ Filme
  $(basename "$0") ~/Videos
  $(basename "$0") --force ~/Videos/ZDF\ Dokus
  $(basename "$0") --dry-run ~/Videos
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=true;     shift ;;
        -f|--force)    FORCE=true;        shift ;;
        -l|--log)      LOG_DIR="$2";      shift 2 ;;
        -h|--help)     usage 0 ;;
        -*)            echo "Unknown option: $1" >&2; usage 1 ;;
        *)             TARGET_DIR="$1";   shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="."
[[ -d "$TARGET_DIR" ]] || die "'$TARGET_DIR' is not a directory."
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if [[ -n "$LOG_DIR" ]]; then
    setup_logging "$LOG_DIR" "yt-zdf-meta"
fi

[[ "$DRY_RUN" == true ]] && info "Dry run -- nothing will be written"

PYTHON_EXE=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_EXE="python3"
elif command -v python >/dev/null 2>&1; then
    if python -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
        PYTHON_EXE="python"
    fi
fi

if [[ -z "$PYTHON_EXE" ]]; then
    die "Error: This script requires Python 3."
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

write_file() {
    local path="$1" content="$2"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD WRITE: $path"
        echo "$content" | sed 's/^/    /'
    else
        echo "$content" > "$path"
        echo "  WROTE: $path"
    fi
}

fetch_page() {
    curl -s --max-time 15 \
        -H "Accept: text/html" \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
        "$1" 2>/dev/null | tr -d '\r'
}

parse_movie_page() {
    "$PYTHON_EXE" - "$1" << 'PYEOF'
import sys, re

html = open(sys.argv[1], encoding='utf-8', errors='replace').read()

def og(name):
    m = re.search(r'<meta\s+property=["\']og:' + name + r'["\']\s+content=["\'](.*?)["\']', html, re.IGNORECASE | re.DOTALL)
    if not m:
        m = re.search(r'<meta\s+content=["\'](.*?)["\']\s+property=["\']og:' + name + r'["\']', html, re.IGNORECASE | re.DOTALL)
    return m.group(1).strip() if m else ''

title       = og('title')
description = og('description')

m = re.search(r'<li>\s*((19|20)\d{2})\s*</li>', html)
year = m.group(1) if m else ''

m = re.search(r'(\d{2,3})(?:\s|&nbsp;)+Min\.', html)
runtime = m.group(1) if m else ''

m = re.search(r'altersfreigabe-ab-(\d+)', html)
fsk = m.group(1) if m else ''

skip_slugs = {
    'altersfreigabe', 'filme', 'serien', 'shows', 'reportagen', 'dokus',
    'magazine', 'kinder', 'live', 'suche', 'mein-zdf', 'nutzungsbedingungen',
    'datenschutz', 'impressum', 'kontakt', 'apps-und-mobile-angebote',
    'smart-tv', 'sendungen-a-z', 'unternehmen', 'karriere', 'presseportal',
    'mainzelmaennchen', 'zuschauerservice', 'service-und-hilfe', 'kategorien',
    'live-tv', 'zdfneo', 'zdfinfo',
}
genre_set = set()
for slug, label in re.findall(r'href=["\'/]+(?:www\.zdf\.de/)?([a-z][a-z-]*)["\'][^>]*>([^<]+)<', html):
    label = label.strip()
    if (slug not in skip_slugs
            and not slug.startswith('altersfreigabe')
            and not label.isdigit()
            and len(label) > 1
            and label not in {'Abspielen', 'Mehr', 'Zurück', 'ZDFneo', 'ZDFinfo', 'ZDF',
                              'Kinder', 'Live', 'Suche', 'Startseite', 'Kategorien',
                              'Externer Link', 'Live & TV'}):
        genre_set.add(label)
genres = ','.join(sorted(genre_set))

import html as html_module

def clean(s):
    s = html_module.unescape(s)
    return s.replace('|', ' ').replace('\n', ' ').strip()

print('|'.join(clean(x) for x in [title, year, runtime, fsk, genres, description]))
PYEOF
}

write_movie_nfo() {
    local nfo_path="$1" page_url="$2" title_fallback="$3"

    local html
    html="$(fetch_page "$page_url")"
    if [[ -z "$html" ]]; then
        echo "  ERROR: could not fetch $page_url"
        return
    fi

    local html_tmp; html_tmp="$(mktemp)"
    printf '%s' "$html" > "$html_tmp"
    local parsed
    parsed="$(parse_movie_page "$html_tmp")"
    rm -f "$html_tmp"

    local title year runtime fsk genres description
    IFS='|' read -r title year runtime fsk genres description <<< "$parsed"
    [[ -z "$title" ]] && title="$title_fallback"

    echo "  Title: $title | Year: $year | FSK: $fsk | Runtime: ${runtime}min | Genres: $genres"

    local genre_xml=""
    if [[ -n "$genres" ]]; then
        local g
        while IFS= read -r g; do
            [[ -n "$g" ]] && genre_xml+="  <genre>$(xml_escape "$g")</genre>"$'\n'
        done < <(echo "$genres" | tr ',' '\n')
    fi

    local nfo
    nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>"$'\n'"<movie>"$'\n'"  <title>$(xml_escape "$title")</title>"
    if [[ -n "$year" ]];        then nfo+=$'\n'"  <year>${year}</year>";                          fi
    if [[ -n "$runtime" ]];     then nfo+=$'\n'"  <runtime>${runtime}</runtime>";                 fi
    if [[ -n "$fsk" ]];         then nfo+=$'\n'"  <mpaa>FSK ${fsk}</mpaa>";                      fi
    if [[ -n "$description" ]]; then nfo+=$'\n'"  <plot>$(xml_escape "$description")</plot>";     fi
    if [[ -n "$genre_xml" ]];   then nfo+=$'\n'"${genre_xml%$'\n'}";                             fi
    nfo+=$'\n'"</movie>"

    write_file "$nfo_path" "$nfo"
}

write_episode_nfo() {
    local nfo_path="$1" json_path="$2"

    # Read JSON via stdin (bash reads file correctly, pipes to Python)
    local json_data
    json_data=$(cat "$json_path" | "$PYTHON_EXE" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    title = d.get('title', '')
    description = d.get('description', '')
    season = d.get('season_number')
    episode = d.get('episode_number')
    series = d.get('series', '')
    upload_date = d.get('upload_date', '')
    aired_date = ''
    if len(upload_date) == 8:
        aired_date = f'{upload_date[:4]}-{upload_date[4:6]}-{upload_date[6:]}'
    # Escape pipes to avoid delimiter collision
    title = title.replace('|', ' ')
    description = description.replace('|', ' ')
    series = series.replace('|', ' ')
    season = '' if season is None else str(int(season))
    episode = '' if episode is None else str(int(episode))
    print(f'{title}|{description}|{season}|{episode}|{series}|{aired_date}')
except Exception as e:
    print('|||||||')
" 2>/dev/null)

    local title plot season episode series aired
    IFS='|' read -r title plot season episode series aired <<< "$json_data"

    echo "  Episode S${season}E${episode}: $title"

    local nfo
    nfo="<?xml version=\"1.0\" encoding=\"utf-8\"?>"$'\n'"<episodedetails>"$'\n'"  <title>$(xml_escape "$title")</title>"$'\n'"  <showtitle>$(xml_escape "$series")</showtitle>"
    if [[ -n "$season" ]];  then nfo+=$'\n'"  <season>${season}</season>";    fi
    if [[ -n "$episode" ]]; then nfo+=$'\n'"  <episode>${episode}</episode>";  fi
    if [[ -n "$aired" ]];   then nfo+=$'\n'"  <aired>${aired}</aired>";        fi
    if [[ -n "$plot" ]];    then nfo+=$'\n'"  <plot>$(xml_escape "$plot")</plot>"; fi
    nfo+=$'\n'"</episodedetails>"

    write_file "$nfo_path" "$nfo"
}

process_info_json() {
    local json_path="$1"
    local dir; dir="$(dirname "$json_path")"
    local base; base="$(basename "$json_path" .info.json)"
    local nfo_path="${dir}/${base}.nfo"

    if [[ -f "$nfo_path" && "$FORCE" == false ]]; then
        echo "  SKIP (exists): $(basename "$nfo_path")"
        return
    fi

    # Check if it's a ZDF file using grep (avoids Python encoding issues entirely)
    if ! grep -q '"extractor_key": "ZDF"' "$json_path" 2>/dev/null; then
        echo "  SKIP (not ZDF): $(basename "$json_path")"
        return
    fi

    # Check if it's an episode or movie: read JSON via stdin
    local season_number
    season_number=$(cat "$json_path" | "$PYTHON_EXE" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get('season_number')
    print('' if v is None else str(int(v)))
except Exception:
    print('')
" 2>/dev/null)

    if [[ -n "$season_number" ]]; then
        write_episode_nfo "$nfo_path" "$json_path"
    else
        # It's a movie - extract webpage_url and title via stdin
        local parsed_data
        parsed_data=$(cat "$json_path" | "$PYTHON_EXE" -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    webpage_url = d.get('webpage_url', '')
    series_id = d.get('series_id', '')
    title = d.get('title', '')
    m = re.match(r'https?://www\.zdf\.de/(?:video/)?([^/]+)/([^/]+)', webpage_url)
    url = ''
    if m:
        url = f'https://www.zdf.de/{m.group(1)}/{m.group(2)}'
    elif series_id:
        url = f'https://www.zdf.de/filme/{series_id}'
    print(f'{url}|{title}')
except Exception:
    print('')
" 2>/dev/null)

        local page_url title_fallback
        IFS='|' read -r page_url title_fallback <<< "$parsed_data"

        if [[ -z "$page_url" ]]; then
            echo "  SKIP (no URL): $(basename "$json_path")"
            return
        fi
        echo "  Movie: $page_url"
        write_movie_nfo "$nfo_path" "$page_url" "$title_fallback"
    fi
}

info "Processing: $TARGET_DIR"
found=0

while IFS= read -r -d "" json_path; do
    process_info_json "$json_path" || true
    (( found++ )) || true
done < <(/usr/bin/find "$TARGET_DIR" -name "*.info.json" \
            ! -name "*.converting.*" \
            ! -path "*/.*" \
            -print0 2>/dev/null | sort -z)

if [[ "$found" -eq 0 ]]; then
    info "No .info.json files found in $TARGET_DIR"
else
    info "Done. $found file(s) processed."
fi
