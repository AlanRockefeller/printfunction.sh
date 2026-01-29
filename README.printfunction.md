# printfunction.sh
# Version 1.4.0
# By Alan Rockefeller — January 29, 2026

**Extract Python functions with surgical precision using AST parsing.**

A command-line tool that uses Python’s abstract syntax tree to extract function and method definitions from source files. Unlike `grep` or `sed`, it understands Python structure—handling decorators, multi-line definitions, and nested scopes correctly.

As of **v1.4+**, it features **high-performance searching** via `ripgrep` integration and optimized globbing, making it suitable for large repositories. It supports multi-file searching, directory recursion, globs (including brackets), and context-aware extraction.

---

## Quick Start

```bash
# Download and install
curl -o printfunction https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/printfunction.sh
chmod +x printfunction
mv printfunction ~/.local/bin/  # or /usr/local/bin with sudo

# List all functions (default when no query provided)
printfunction myfile.py

# Extract a function from one file
printfunction foo myfile.py

# Find the function containing a specific string
printfunction --at "cached_preview" myfile.py


# Search across multiple files
printfunction foo a.py b.py

# Recursive search in a directory
printfunction foo .

# Bracket globs
printfunction foo "tests/[a-c]*.py"

# Extract with imports
printfunction --import=used fetch_data scraper.py

# Regex search across a tree
printfunction --regex '^test_' .

# List all available functions/methods
printfunction --list myfile.py

# Extract by line range
printfunction lines 10-40 myfile.py

# Smart “best enclosing block” for a line range (AST-aware)
printfunction ~10-40 myfile.py
```

---

## Why not grep?

```bash
# grep breaks on multi-line definitions and misses decorators
grep -A 20 "def process" myfile.py  # How many lines? What about @decorators?

# printfunction gets it right every time
printfunction MyClass.process myfile.py  # Complete, accurate, always works
```

---

## What changed since v1.0?

v1.4.0 transforms `printfunction` from a small-scale extractor into a **performant repository search tool**:

- **New calling convention:** `printfunction [OPTIONS] [QUERY] [FILES...]`
- **Performance:** Automatic `ripgrep` pre-filtering and fast-path string scanning
- **Multi-file output with per-file headers**
- **Recursive directory scanning** with sensible default ignores
- **Glob support** (including `**/*.py` with `recursive=True` in Python)
- **Bracket Globs:** Supports shell-style `[a-z]` patterns in file paths
- **Regex mode** via `--regex` (no positional QUERY required)
- **Content-based targeting** via `--at PATTERN` (finds enclosing block around match)
- **Line range extraction** (`lines START-END`) and **smart block extraction** (`~START-END`)
- **Context lines** for line-mode matches (`--context N`)
- **File type filter** (`--type py` default, or `--type all`)
- **Default list mode** (v1.3.2+) – Providing only files/roots lists available definitions

---

## Features

- **AST-based extraction** – Captures complete function bodies including decorators, regardless of formatting
- **High Performance** – Uses `ripgrep` (if available) to pre-filter files before parsing
- **Smart targeting** – Extract by name (`foo`) or qualified name (`Class.method`)
- **Nested support** – `--all` descends into function bodies to include nested defs in search/listing
- **Import analysis**
  - `--import=all` prints module/class-scope imports
  - `--import=used` prints a best-effort subset used by matched function(s)
- **Regex search** – `--regex` matches against fully-qualified names (`Class.method`, `outer.inner`, etc.)
- **Content search** – `--at PATTERN` finds the first line matching a regex and extracts the surrounding function/class (Python) or padded lines (other files).
- **Multi-file + recursive search** – Search across files, globs, or entire directories
- **Line range extraction**
  - `lines START-END` extracts raw lines (optionally with `--context`)
  - `~START-END` extracts the *best enclosing block* (function/class/if/try/with/etc.)
- **Syntax highlighting** – Auto-detects `bat`/`batcat`/`pygmentize` when output is a TTY
- **Multiple matches** – Prints all matches in source order by default; use `--first` for just the first match *per file*
- **List mode** – `--list` prints available defs with line numbers (optionally filtered by QUERY or `--regex`)

---

## Installation

```bash
curl -o printfunction https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/printfunction.sh
chmod +x printfunction
```

Install (choose one):

```bash
# User-local (recommended)
mkdir -p ~/.local/bin
mv printfunction ~/.local/bin/
# Add to ~/.bashrc if needed: export PATH="$HOME/.local/bin:$PATH"

# System-wide
sudo mv printfunction /usr/local/bin/
```

---

## Usage

```bash
printfunction [OPTIONS] [QUERY] [FILES...]
```

### The “FILES…” arguments

You can pass any mix of:

- A file path (`a.py`)
- A directory (`src/`) — scanned recursively
- A glob (`"**/*.py"`) — quote it if you don’t want your shell to expand it first

The tool skips common junk folders during recursion (e.g. `.git`, `.venv`, `__pycache__`, `node_modules`, etc.).

### Query syntax

`QUERY` can be one of:

- `foo` — function name
- `ClassName.method` — qualified method name
- `lines START-END` — raw line extraction (works on any file type)
- `~START-END` — smart block extraction (AST-aware for Python; padded fallback for non-Python)
- `file.py:100-200` — file with line range (paste from Claude Code output)
- `file.py:~100-200` — file with smart context range

Notes:

- If you use `--regex` or `--at`, the pattern is provided via the option, so **no positional QUERY is required**.
- A bare range like `10-20` or `~10-20` is treated as line-mode **only if it’s the first “query-like” argument**.

---

## Options

| Option | Description |
|--------|-------------|
| `--all` | Include nested functions (descend into function bodies) |
| `--first` | Print only the first match **per file** |
| `--type py` | Only scan Python files (`.py`, `.pyw`) (default) |
| `--type all` | Scan all files (line-mode is always allowed; AST extraction still only applies to Python) |
| `--import` | Include imports (same as `--import=all`) |
| `--import=all` | Include all module/class-scope imports |
| `--import=used` | Include only imports that appear to be referenced by the extracted function(s) (best-effort) |
| `--import=none` | Disable import extraction (default) |
| `--context N` | Add `N` lines of context around line-mode and smart line-mode output (default: `0`) |
| `--list` | List names + line numbers instead of extracting (use with `--all` to include nested) |
| `--regex PATTERN` | Match by regex against fully-qualified names |
| `--at PATTERN` | Find first line matching regex PATTERN and extract enclosing block (Python) or padded lines (others) |
| `-h, --help` | Show help message |

---

## Examples

### 1) Extract a function from one file

```bash
printfunction foo myfile.py
```

### 2) Search across multiple files

```bash
printfunction foo a.py b.py src/utils.py
```

### 3) Recursive search

```bash
printfunction foo .
```

### 4) Globs (recommended to quote)

```bash
printfunction foo "**/*.py"
```

### 5) Regex matching

Match all test defs:

```bash
printfunction --regex '^test_' tests/
```

Match methods in a class:

```bash
printfunction --regex 'DatabaseHandler\..*' db.py
```

### 6) List available functions/methods

```bash
printfunction --list myfile.py
```

Filter the list by query:

```bash
printfunction --list process myfile.py
```

Include nested functions:

```bash
printfunction --list --all myfile.py
```

### 7) Import extraction

All imports:

```bash
printfunction --import=all fetch_data scraper.py
```

Only used imports (best-effort):

```bash
printfunction --import=used fetch_data scraper.py
```

### 8) Line range extraction (raw lines)

```bash
printfunction lines 10-40 myfile.py
```

With extra context:

```bash
printfunction --context 5 lines 10-40 myfile.py
```

### 9) Smart block extraction (AST-aware)

Extract the "best enclosing block" containing that range:

```bash
printfunction ~10-40 myfile.py
```

### 10) File:range syntax (paste from Claude Code)

Extract lines directly from a file reference (useful for pasting from error messages or IDE output):

```bash
printfunction app.py:3343-3414
```

Smart context with file:range syntax:

```bash
printfunction app.py:~100-200
```

### 11) Find enclosing block by content

Find the function definition that contains a specific string (e.g. error message or variable):

```bash
printfunction --at "raise ValueError" myfile.py
```

Find a usage of a token in non-Python files (shows context):

```bash
printfunction --at "TODO" --type all .
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — matches were printed (or `--list` produced output) |
| `1` | Not found — no matches anywhere (and no fatal errors) |
| `2` | Error — invalid arguments, unreadable file, parse error, invalid regex, or “no matches + at least one error” |

---

## Requirements

**Required:**
- Bash (standard on Linux/macOS)
- Python 3.8+

**Recommended for speed:**
- `ripgrep` (rg) — Significantly speeds up searches in large directories

**Optional (for syntax highlighting):**
- `bat` or `batcat` (recommended)
- `pygmentize` (from Pygments)

```bash
# macOS
brew install bat ripgrep

# Ubuntu/Debian
apt install bat ripgrep

# Or install pygmentize
pip install pygments
```

---

## How It Works

1. **Expand roots** – Accepts files, directories (recursive), and globs; dedupes paths while preserving discovery order.
2. **Pre-filter** – Checks files for the target string (using `rg` or fast string scanning) to skip parsing irrelevant files.
3. **Parse (Python only)** – Uses `ast.parse()` to build a structural view of Python source.
4. **Track context** – Builds fully-qualified names by tracking class and (optionally) function nesting:
   - `Foo.bar`
   - `outer.inner`
5. **Handle decorators** – Includes `@decorators` above the `def` line as part of the extracted span.
6. **Match**
   - Direct name match (`foo`) or exact qualified match (`Class.method`)
   - Regex match over qualnames (`--regex`)
   - Content match (`--at`) -> maps to smart line mode
7. **Line mode**
   - `lines A-B`: raw line slice (optionally with `--context`)
   - `~A-B`: selects the best enclosing AST block (function/class/control block). If not Python, falls back to padded raw lines.
8. **Import extraction**
   - `--import=all`: prints module/class-scope imports
   - `--import=used`: collects “root names” used inside the matched function nodes and filters imports accordingly (best-effort)

---

## Troubleshooting

### “Missing FILES/ROOTS”

You must provide at least one file/dir/glob root:

```bash
printfunction foo   # Error - missing roots
printfunction foo . # Correct
```

### “Missing FUNCTION_NAME”

If you aren’t using `--regex`, `--at`, `--list`, or line-mode, and provide arguments that look like files but no query, the tool now defaults to **listing** functions (v1.3.2+). 

However, if you explicitly turn off list mode or provide conflicting flags without a query, you might see this error.

```bash
# v1.3.2+ defaults to list mode, so this is now VALID:
printfunction .
```

### Parse errors

If a Python file can’t be parsed, you’ll get an error like:

```text
Error parsing path/to/file.py: invalid syntax (file.py, line 42)
```

Fix syntax errors before using AST extraction. (Line-mode can still work.)

### No matches

If nothing matches and you’re searching Python files, the tool may suggest:

```text
Tip: run with --list to see available definitions.
```

---

## Contributing

Contributions and comments welcome. Submit issues or pull requests on GitHub.

---

## License

MIT License 

---

## Related Tools

- [ast-grep](https://ast-grep.github.io/) – Multi-language AST-based search  
- [semgrep](https://semgrep.dev/) – Pattern-based code analysis  
- [bat](https://github.com/sharkdp/bat/) – Syntax highlighting for cat  

---

**Author:** Alan Rockefeller  
**Repository:** https://github.com/AlanRockefeller/printfunction.sh
