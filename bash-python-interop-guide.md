# Bash/Python Interop: Cross-Platform Scripts for macOS, Linux, Git Bash & Cygwin

A recipe for writing bash scripts that call Python and work reliably across **macOS**, **Linux**, **Git Bash**, and **Cygwin** — especially with **UTF-8 filenames** containing special characters (umlauts, spaces, etc).

## The Core Problem

On **Windows (Git Bash, Cygwin)**, UTF-8 filenames get corrupted when passed to subprocesses as **command-line arguments**, but work fine when handled by **bash itself** or read via **stdin**.

### What Fails ❌

```bash
# ❌ FAILS on Cygwin: filename with ä gets corrupted
python -c "open(sys.argv[1])" "$path_with_umlaut"
# Python receives: /path/to/Legend?re (corrupted)
```

### What Works ✅

```bash
# ✅ WORKS everywhere: bash reads file, pipes to Python stdin
cat "$path_with_umlaut" | python -c "import json, sys; json.load(sys.stdin)"

# ✅ WORKS everywhere: grep/sed/bash tools handle filenames natively
grep -q "pattern" "$path_with_umlaut"
```

---

## Rule 1: Don't Pass UTF-8 Filenames as Command-Line Arguments to Subprocesses

### ❌ Problem Pattern

```bash
# This fails on Cygwin when $file contains UTF-8 characters
result=$(python -c "code" "$file")
result=$(jq . "$file")
result=$(python -c "code" "$file" "$another_file")
```

### ✅ Solution: Use stdin instead

```bash
# Bash reads the file (handles encoding), pipes to Python
result=$(cat "$file" | python -c "code")

# Or use input redirection (equivalent)
result=$(python -c "code" < "$file")
```

---

## Rule 2: For Simple String Matching, Use Native Bash Tools

Don't invoke Python just to check if a file contains a pattern. Use `grep`.

### ❌ Problem Pattern

```bash
# Python subprocess to extract metadata - encoding issues on Cygwin
extractor=$("$PYTHON" -c "import json; print(json.load(open('$file'))['extractor'])" "$file")
if [[ "$extractor" == "ZDF" ]]; then ...
```

### ✅ Solution: Use grep for string checks

```bash
# Grep is a bash tool, handles filenames natively
if grep -q '"extractor_key": "ZDF"' "$file"; then
    # It's a ZDF file
fi
```

This works everywhere: macOS, Linux, Cygwin.

---

## Rule 3: For Complex Data Extraction, Use Python stdin with JSON Parsing

When you need to extract structured data, use Python but feed it via stdin.

### ❌ Problem Pattern

```bash
# Passes filename as argument - fails on Cygwin with UTF-8 filenames
season=$(python -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('season_number'))
" "$json_file")
```

### ✅ Solution: Pipe file content to Python stdin

```bash
# Bash reads file, pipes to Python
season=$(cat "$json_file" | python -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('season_number'))
")
```

**Key difference:** Python reads from `sys.stdin` (raw bytes piped by bash), not from `sys.argv[1]`.

---

## Rule 4: Use Detected Python Executable Consistently

Detect Python once at script start, then use that variable everywhere.

### ✅ Pattern

```bash
# Detect once at the start
PYTHON_EXE=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_EXE="python3"
elif command -v python >/dev/null 2>&1; then
    if python -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
        PYTHON_EXE="python"
    fi
fi
[[ -z "$PYTHON_EXE" ]] && die "Python 3 required"

# Use consistently in all Python calls
cat "$file" | "$PYTHON_EXE" -c "..."
grep -q '"extractor_key": "ZDF"' "$file"  # No Python needed for this
```

---

## Rule 5: Handle Encoding Explicitly

Set `PYTHONIOENCODING=utf-8` when running Python, and handle non-UTF-8 input gracefully.

### ✅ Pattern

```bash
# Set encoding, handle errors gracefully
PYTHONIOENCODING=utf-8 python -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('title', ''))
except Exception:
    print('')  # Fallback on error
"
```

---

## Common Patterns

### Pattern 1: Check if file contains a marker string

```bash
# ✅ Use grep (works everywhere, no encoding issues)
if ! grep -q '"extractor_key": "ZDF"' "$file"; then
    echo "Not a ZDF file"
    return
fi
```

### Pattern 2: Extract a single JSON field

```bash
# ✅ Use Python stdin
title=$(cat "$json_file" | python -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('title', ''))
")
```

### Pattern 3: Extract multiple JSON fields at once

More efficient: extract all fields in one Python call, output as delimited string.

```bash
# ✅ Extract multiple fields in one pass
data=$(cat "$json_file" | python -c "
import json, sys
d = json.load(sys.stdin)
print(f\"{d.get('title', '')}|{d.get('season', '')}|{d.get('episode', '')}\")
")

# Parse the delimited output
IFS='|' read -r title season episode <<< "$data"
```

### Pattern 4: Parse command-line safe data (no UTF-8)

For simple values like integers or IDs, you can still use command-line args since they rarely have encoding issues:

```bash
# Safe: passing simple IDs/numbers as arguments
result=$(python -c "code" "$simple_id" "$number")

# Unsafe: passing filenames with special characters
result=$(python -c "code" "$filename_with_umlauts")  # ❌ Will fail on Cygwin
```

### Pattern 5: Call Python script with structured data input

If you have a Python script (not inline -c code), use stdin for the data:

```bash
# ✅ Pipe JSON to Python script via stdin
cat "$data_file" | python /path/to/script.py

# In script.py:
import json, sys
data = json.load(sys.stdin)
```

---

## Testing Strategy

### Test Script to Verify Cross-Platform Compatibility

```bash
#!/bin/bash
# test-utf8-interop.sh - Verify Python interop works with UTF-8 filenames

set -euo pipefail

# Create a test directory with UTF-8 filenames
TEST_DIR="test_utf8_$$"
mkdir -p "$TEST_DIR"

# Create test files with UTF-8 characters in names
cat > "$TEST_DIR/Legendäre_Piraten.json" << 'EOF'
{"title": "Anne Bonny und Mary Read", "season_number": 1, "extractor_key": "ZDF"}
EOF

cat > "$TEST_DIR/file_with_ä_ö_ü.json" << 'EOF'
{"data": "test"}
EOF

echo "Testing bash/Python interop with UTF-8 filenames..."

cd "$TEST_DIR"

# Test 1: grep with UTF-8 filename
echo -n "Test 1 (grep): "
if grep -q '"extractor_key": "ZDF"' "Legendäre_Piraten.json"; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Test 2: Python stdin with UTF-8 filename
echo -n "Test 2 (Python stdin): "
title=$(cat "Legendäre_Piraten.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('title', ''))
")
if [[ "$title" == "Anne Bonny und Mary Read" ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL (got: $title)"
fi

# Test 3: Multiple fields extraction
echo -n "Test 3 (Multiple fields): "
data=$(cat "Legendäre_Piraten.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"{d.get('title', '')}|{d.get('season_number', '')}\")
")
IFS='|' read -r t s <<< "$data"
if [[ "$t" == "Anne Bonny und Mary Read" && "$s" == "1" ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL (got: title=$t, season=$s)"
fi

# Cleanup
cd ..
rm -rf "$TEST_DIR"

echo "All tests passed!"
```

Run on each platform to verify:
```bash
bash test-utf8-interop.sh  # macOS, Linux
bash test-utf8-interop.sh  # Git Bash
bash test-utf8-interop.sh  # Cygwin
```

---

## Debugging Checklist

If your script fails on Windows/Cygwin but works on macOS/Linux:

- [ ] Are you passing **UTF-8 filenames as command-line arguments** to Python?
  - **Solution:** Use stdin instead (`cat file | python -c ...`)

- [ ] Are you checking for **file existence or simple patterns** with Python?
  - **Solution:** Use native bash tools (`grep`, `test -f`, `[[ -f ]]`)

- [ ] Did you **set `PYTHONIOENCODING=utf-8`**?
  - **Solution:** Add it: `PYTHONIOENCODING=utf-8 python -c ...`

- [ ] Are you **reading from stdin in Python** (`sys.stdin`) or **opening a file** (`open(filename)`)?
  - **Solution:** Always use stdin when filenames might have UTF-8: `json.load(sys.stdin)`

- [ ] Is your **Python code handling exceptions gracefully**?
  - **Solution:** Add try/except, print empty string on error, let bash handle fallbacks

---

## Complete Real-World Example

Here's a minimal but complete script demonstrating all patterns:

```bash
#!/usr/bin/env bash
# process-json.sh - Cross-platform JSON processing

set -euo pipefail

# Detect Python
PYTHON_EXE="python3"
if ! command -v python3 >/dev/null 2>&1; then
    PYTHON_EXE="python"
fi

process_file() {
    local file="$1"
    
    # Pattern 1: Simple string check with grep
    if ! grep -q '"type": "episode"' "$file"; then
        echo "SKIP: Not an episode"
        return
    fi
    
    # Pattern 2: Extract single field with Python stdin
    local title
    title=$(cat "$file" | "$PYTHON_EXE" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('title', ''))
except Exception:
    print('')
")
    
    if [[ -z "$title" ]]; then
        echo "ERROR: Could not parse title"
        return
    fi
    
    # Pattern 3: Extract multiple fields at once
    local data
    data=$(cat "$file" | "$PYTHON_EXE" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    season = d.get('season_number', '')
    episode = d.get('episode_number', '')
    print(f'{season}|{episode}')
except Exception:
    print('|')
")
    
    local season episode
    IFS='|' read -r season episode <<< "$data"
    
    echo "Title: $title, Season: $season, Episode: $episode"
}

# Usage
for file in *.json; do
    process_file "$file"
done
```

---

## Summary: The Golden Rules

1. ✅ **Don't pass UTF-8 filenames as command-line arguments to Python**
   - Use stdin instead: `cat file | python -c ...`

2. ✅ **Use native bash tools for simple checks**
   - Use `grep`, `test`, `[[ ]]` instead of Python for string matching

3. ✅ **Python reads from stdin** (`sys.stdin`), **not from file paths** (`sys.argv[1]`)
   - Exception: simple IDs/numbers without special characters are OK as arguments

4. ✅ **Set Python encoding explicitly**
   - `PYTHONIOENCODING=utf-8 python -c ...`

5. ✅ **Handle errors gracefully**
   - Exceptions → print fallback value → let bash decide what to do

6. ✅ **Test on all platforms**
   - Write test files with UTF-8 characters, run on macOS, Linux, Git Bash, Cygwin

---

## Further Reading

- [Python stdin/stdout encoding](https://docs.python.org/3/library/sys.html#sys.stdin)
- [GNU Cygwin documentation](https://cygwin.com/docs/)
- [UTF-8 in bash](https://wiki.bash-hackers.org/syntax/quoting)
- [Shellcheck](https://www.shellcheck.net/) - lint your bash scripts
