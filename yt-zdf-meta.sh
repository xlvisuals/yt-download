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
# Works on macOS (BSD grep/sed) and Windows (Cygwin/Git Bash).
# Safe to re-run -- existing NFO files are skipped unless --force is set.

set -euo pipefail

trap 'echo "Error: script aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=yt-common.sh
source "${SCRIPT_DIR}/yt-common.sh"


# ── Parse arguments ──────────────────────────────────────────────────────────

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
  $(basename "$0") ~/Videos                  # searches all ZDF subdirs
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


# ── Detect Python Executable ──────────────────────────────────────────────────
PYTHON_EXE=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_EXE="python3"
elif command -v python >/dev/null 2>&1; then
    # Double-check that 'python' is actually Python 3
    if python -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
        PYTHON_EXE="python"
    fi
fi

if [[ -z "$PYTHON_EXE" ]]; then
    die "Error: This script requires Python 3, but neither 'python3' nor 'python' was found in your PATH."
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

write_file() {  # write_file <path> <content>
    local path="$1" content="$2"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD WRITE: $path"
        echo "$content" | sed 's/^/    /'
    else
        echo "$content" > "$path"
        echo "  WROTE: $path"
    fi
}

fetch_page() {  # fetch_page <url> -> stdout
    curl -s --max-time 15 \
        -H "Accept: text/html" \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
        "$1" 2>/dev/null | tr -d '\r'
}

# Parse ZDF movie page HTML and output: title|year|runtime|fsk|genres|description
# Uses only python3 -- avoids grep -P (not available on macOS/BSD).
# Accepts the HTML as a file path argument to avoid stdin conflict with heredoc.
parse_movie_page() {  # parse_movie_page <html_file> -> stdout: field|field|...
    "$PYTHON_EXE" - "$1" << 'PYEOF'
import sys, re

html = open(sys.argv[1], encoding='utf-8', errors='replace').read()

# og: meta tags -- two attribute orderings used by ZDF
def og(name):
    m = re.search(r'<meta\s+property=["\']og:' + name + r'["\']\s+content=["\'](.*?)["\']', html, re.IGNORECASE | re.DOTALL)
    if not m:
        m = re.search(r'<meta\s+content=["\'](.*?)["\']\s+property=["\']og:' + name + r'["\']', html, re.IGNORECASE | re.DOTALL)
    return m.group(1).strip() if m else ''

title       = og('title')
description = og('description')

# Year: standalone <li>1965</li>
m = re.search(r'<li>\s*((19|20)\d{2})\s*</li>', html)
year = m.group(1) if m else ''

# Runtime: match 'N Min.' or 'N&nbsp;Min.' anywhere in the page
m = re.search(r'(\d{2,3})(?:\s|&nbsp;)+Min\.', html)
runtime = m.group(1) if m else ''

# FSK: href="/altersfreigabe-ab-12"
m = re.search(r'altersfreigabe-ab-(\d+)', html)
fsk = m.group(1) if m else ''

# Genres: links to ZDF category pages, excluding navigation and FSK
skip_slugs = {
    'altersfreigabe', 'filme', 'serien', 'shows', 'reportagen', 'dokus',
    'magazine', 'kinder', 'live', 'suche', 'mein-zdf', 'nutzungsbedingungen',
    'datenschutz', 'impressum', 'kontakt', 'apps-und-mobile-angebote',
    'smart-tv', 'sendungen-a-z', 'unternehmen', 'karriere', 'presseportal',
    'mainzelmaennchen', 'zuschauerservice', 'service-und-hilfe', 'kategorien',
    'live-tv', 'zdfneo', 'zdfinfo',
}
genre_set = set()
# Match href links and their text content
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
    # Unescape HTML entities (&quot; &amp; &lt; &gt; etc.) before XML-escaping
    s = html_module.unescape(s)
    return s.replace('|', ' ').replace('\n', ' ').strip()

print('|'.join(clean(x) for x in [title, year, runtime, fsk, genres, description]))
PYEOF
}


# ── Movie NFO ────────────────────────────────────────────────────────────────

write_movie_nfo() {  # write_movie_nfo <nfo_path> <page_url> <title_fallback>
    local nfo_path="$1" page_url="$2" title_fallback="$3"

    local html
    html="$(fetch_page "$page_url")"
    if [[ -z "$html" ]]; then
        echo "  ERROR: could not fetch $page_url"
        return
    fi

    # Write HTML to temp file -- parse_movie_page uses python3 with a heredoc
    # which consumes stdin, so we cannot pipe HTML via stdin simultaneously.
    local html_tmp; html_tmp="$(mktemp)"
    printf '%s' "$html" > "$html_tmp"
    local parsed
    parsed="$(parse_movie_page "$html_tmp")"
    rm -f "$html_tmp"

    local title year runtime fsk genres description
    IFS='|' read -r title year runtime fsk genres description <<< "$parsed"
    [[ -z "$title" ]] && title="$title_fallback"

    echo "  Title: $title | Year: $year | FSK: $fsk | Runtime: ${runtime}min | Genres: $genres"

    # Build genre XML
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


# ── Episode NFO ──────────────────────────────────────────────────────────────

write_episode_nfo() {  # write_episode_nfo <nfo_path> <json_path>
    local nfo_path="$1" json_path="$2"

    local title plot season episode series
    title="$(  "$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('title',''))"          "$json_path" 2>/dev/null)"
    plot="$(   "$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('description',''))"    "$json_path" 2>/dev/null)"
    season="$( "$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get('season_number'); print('' if v is None else str(v))" "$json_path" 2>/dev/null)"
    episode="$("$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get('episode_number'); print('' if v is None else str(v))" "$json_path" 2>/dev/null)"
    series="$( "$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('series',''))"        "$json_path" 2>/dev/null)"
    # Year from upload_date (format YYYYMMDD) -- the broadcast/availability date
    aired="$(  "$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); u=d.get('upload_date',''); print(f'{u[:4]}-{u[4:6]}-{u[6:]}' if len(u)==8 else '')" "$json_path" 2>/dev/null)"

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


# ── Process one info.json ─────────────────────────────────────────────────────

#process_info_json() {  # process_info_json <info_json_path>
#    local json_path="$1"
#    local dir; dir="$(dirname "$json_path")"
#    local base; base="$(basename "$json_path" .info.json)"
#    local nfo_path="${dir}/${base}.nfo"
#
#    if [[ -f "$nfo_path" && "$FORCE" == false ]]; then
#        echo "  SKIP (exists): $(basename "$nfo_path")"
#        return
#    fi
#
#    local ek
#    ek=$("$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('extractor_key','').upper())" "$json_path" 2>/dev/null)
#    if [[ "$ek" != "ZDF" ]]; then
#        echo "  SKIP (not ZDF): $(basename "$json_path")"
#        return
#    fi
#
#    local season_number
#    season_number=$("$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get('season_number'); print('' if v is None else str(v))" "$json_path" 2>/dev/null)
#
#    if [[ -n "$season_number" ]]; then
#        write_episode_nfo "$nfo_path" "$json_path"
#    else
#        local page_url title_fallback
#        page_url=$("$PYTHON_EXE" -c "
#import json, sys, re
#d = json.load(open(sys.argv[1]))
#webpage_url = d.get('webpage_url', '')
#series_id = d.get('series_id', '')
#m = re.match(r'https?://www\.zdf\.de/(?:video/)?([^/]+)/([^/]+)', webpage_url)
#if m:
#    cat, sid = m.group(1), m.group(2)
#    print(f'https://www.zdf.de/{cat}/{sid}')
#elif series_id:
#    print(f'https://www.zdf.de/filme/{series_id}')
#" "$json_path" 2>/dev/null)
#        title_fallback=$("$PYTHON_EXE" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('title',''))" "$json_path" 2>/dev/null)
#
#        if [[ -z "$page_url" ]]; then
#            echo "  SKIP (no URL): $(basename "$json_path")"
#            return
#        fi
#        echo "  Movie: $page_url"
#        write_movie_nfo "$nfo_path" "$page_url" "$title_fallback"
#    fi
#}

process_info_json() {  # process_info_json <info_json_path>
    local json_path="$1"
    local dir; dir="$(dirname "$json_path")"
    local base; base="$(basename "$json_path" .info.json)"
    local nfo_path="${dir}/${base}.nfo"

    if [[ -f "$nfo_path" && "$FORCE" == false ]]; then
        echo "  SKIP (exists): $(basename "$nfo_path")"
        return
    fi

    # Save current directory location
    local current_pwd; current_pwd="$PWD"

    # Change execution context to the file's directory to drop path prefixes
    cd "$dir" || return

    # Query Python using local directory lookups to bypass Unicode normalization bugs
    local ek
    ek=$(PYTHONIOENCODING=utf-8 "$PYTHON_EXE" -c "
import json, glob, sys
files = glob.glob('*.info.json')
if files:
    with open(files[0], encoding='utf-8') as f:
        print(json.load(f).get('extractor_key', '').upper())
" 2>/dev/null)

    if [[ "$ek" != "ZDF" ]]; then
        echo "  SKIP (not ZDF): $base.info.json"
        cd "$current_pwd" || return
        return
    fi

    local season_number
    season_number=$(PYTHONIOENCODING=utf-8 "$PYTHON_EXE" -c "
import json, glob
files = glob.glob('*.info.json')
if files:
    with open(files[0], encoding='utf-8') as f:
        v = json.load(f).get('season_number')
        print('' if v is None else str(v))
" 2>/dev/null)

    if [[ -n "$season_number" ]]; then
        # Restore directory context before executing the sub-write function
        cd "$current_pwd" || return
        write_episode_nfo "$nfo_path" "$json_path"
    else
        local page_url title_fallback parsed_data
        parsed_data=$(PYTHONIOENCODING=utf-8 "$PYTHON_EXE" -c "
import json, glob, re
files = glob.glob('*.info.json')
if files:
    with open(files[0], encoding='utf-8') as f:
        d = json.load(f)
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
" 2>/dev/null)

        # Restore working directory context
        cd "$current_pwd" || return

        IFS='|' read -r page_url title_fallback <<< "$parsed_data"

        if [[ -z "$page_url" ]]; then
            echo "  SKIP (no URL): $(basename "$json_path")"
            return
        fi
        echo "  Movie: $page_url"
        write_movie_nfo "$nfo_path" "$page_url" "$title_fallback"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

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
