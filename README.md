# printfunction.sh 
# Version 1.0 
# By Alan Rockefeller - January 10, 2026

**Extract Python functions with surgical precision using AST parsing.**

A command-line tool that uses Python's abstract syntax tree to extract function and method definitions from source files. Unlike `grep` or `sed`, it understands Python structure—handling decorators, multi-line definitions, and nested scopes correctly every time.

---

## Quick Start

```bash
# Download and install
curl -o printfunction https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/printfunction.sh
chmod +x printfunction
mv printfunction ~/.local/bin/  # or /usr/local/bin with sudo

# Extract a function
printfunction myfile.py my_function

# Extract with imports
printfunction --import=used myfile.py fetch_data

# List all available functions
printfunction --list myfile.py
```

---

## Why not grep?

```bash
# grep breaks on multi-line definitions and misses decorators
grep -A 20 "def process" myfile.py  # How many lines? What about @decorators?

# printfunction gets it right every time
printfunction myfile.py MyClass.process  # Complete, accurate, always works
```

---

## Features

- **AST-based extraction** – Captures complete function bodies including decorators, regardless of formatting
- **Smart targeting** – Extract by name (`foo`), class method (`MyClass.method`), or nested path (`outer.inner` with `--all`)
- **Intelligent errors** – Detects when a function exists but is nested; suggests using `--all`
- **Import analysis** – `--import=used` extracts only the imports your function actually references
- **Regex search** – Match by pattern against fully-qualified names (`--regex '^test_'`)
- **Syntax highlighting** – Auto-detects `bat`/`batcat`/`pygmentize` when outputting to terminal
- **Multiple matches** – Shows all definitions by default; use `--first` for just the initial one

---

## Installation

**Download the script:**

```bash
curl -o printfunction https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/printfunction.sh
chmod +x printfunction
```

**Install (choose one):**

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
printfunction [OPTIONS] FILENAME [FUNCTION_NAME]
```

### Options

| Option | Description |
|--------|-------------|
| `--all` | Include nested functions (functions defined inside other functions) |
| `--first` | Print only the first match when multiple definitions exist |
| `--import` | Include all module/class-scope imports (same as `--import=all`) |
| `--import=all` | Include all module/class-scope imports (explicit form) |
| `--import=used` | Include only imports referenced by the extracted function (best-effort heuristic) |
| `--import=none` | Disable import extraction |
| `--list` | List all available functions instead of extracting |
| `--regex PATTERN` | Match by regex against fully-qualified names (overrides `FUNCTION_NAME`) |
| `-h, --help` | Show help message |

### Function Name Syntax

- `foo` – Any function named `foo`
- `ClassName.method` – Specific class method
- `Outer.Inner.method` – Method in nested class
- `outer.inner` (with `--all`) – Function nested inside another function

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success – function(s) found and printed |
| `1` | Not found – no matching functions |
| `2` | Usage error – invalid arguments, missing file, or syntax error |

---

## Examples

### Basic extraction

```bash
printfunction math_utils.py calculate
```

### Class methods

```bash
printfunction models.py User.save_to_db
```

### Smart import extraction

Extract a function with only the imports it actually uses:

```bash
printfunction --import=used scraper.py fetch_data
```

**Output:**
```python
import requests
from typing import Dict

####################

def fetch_data(url: str) -> Dict:
    """Fetch JSON data from a URL."""
    response = requests.get(url)
    return response.json()
```

### Nested functions

Extract functions defined inside other functions (requires `--all`):

```bash
printfunction --all decorators.py retry.exponential_backoff
```

**Forgot `--all`? The tool helps you:**

```
*** FOUND IT! ***
'process_one' is nested inside: main

By default, this tool does not search functions defined inside other functions.
Use --all to include nested functions.

Run with --all:
  printfunction --all myfile.py process_one
```

### Regex matching

Extract all test functions:

```bash
printfunction --regex '^test_' tests/unit_tests.py
```

Match methods in a specific class:

```bash
printfunction --regex 'DatabaseHandler\\..*' db.py
```

**Note:** Regex applies to fully-qualified names (e.g., `MyClass.method`).
- `^test_` matches only top-level functions named `test_*`.
- `(^|\\.)test_` matches `test_*` at the top level OR inside classes/modules.

### List available functions

```bash
printfunction --list myfile.py
```

**Output:**
```
main  (line 10)
MyClass.process  (line 25)
helper_function  (line 45)
```

Include nested functions:

```bash
printfunction --list --all myfile.py
```

**Output:**
```
main  (line 10)
main.process_one  (line 257)
MyClass.process  (line 25)
MyClass.process.helper  (line 30)
```

### Multiple matches

When multiple functions match, the tool shows context:

```bash
printfunction myfile.py foo
```

**Stderr output (TTY only):**
```
Found 3 definitions: foo (line 10), MyClass.foo (line 45), Other.foo (line 78)
```

Print only the first:

```bash
printfunction --first myfile.py foo
```

**Stderr output:**
```
Found 3 definitions: foo (line 10), MyClass.foo (line 45), Other.foo (line 78) (printing first due to --first)
```

---

## Requirements

**Required:**
- Bash (standard on Linux/macOS)
- Python 3.8+

**Optional (for syntax highlighting):**
- `bat` or `batcat` (recommended)
- `pygmentize` (from Pygments package)

**Install syntax highlighters:**

```bash
# macOS
brew install bat

# Ubuntu/Debian
apt install bat

# Or install pygmentize
pip install pygments
```

---

## How It Works

1. **Parse** – Converts Python source into an abstract syntax tree using Python's `ast` module
2. **Track context** – Builds fully-qualified names by tracking class/function nesting as it walks the tree
3. **Match** – Compares your target against qualified names (supports simple names and dot-notation)
4. **Extract** – Uses AST line numbers to extract exact source code including decorators
5. **Analyze imports** – For `--import=used`, walks the function's AST to find referenced names and matches them against imports

---

## Troubleshooting

### Function not found

The tool suggests similar names when you make a typo:

```
Couldn't find a match in: myfile.py
  Target: 'proces'

Closest matches:
  - MyClass.process
  - process_data
```

### Nested function detection

If a function exists but is nested, you'll get specific guidance:

```
*** FOUND IT! ***
'helper' is nested inside: main.process_data

Use --all to include nested functions:
  printfunction --all myfile.py helper
```

### Import detection limitations

The `--import=used` mode is best-effort and may:

- **Over-include** star imports (`from module import *`)
- **Miss** dynamic attribute access (`getattr()`) or names in strings/`eval()`

For these cases, use `--import=all` to include all module-level imports.

### Syntax errors

The tool requires valid Python syntax:

```
Error: syntax error while parsing myfile.py:
  invalid syntax (myfile.py, line 42)
```

Fix syntax errors before using the tool.

---

## Contributing

Contributions welcome! Submit issues or pull requests on GitHub.

---

## License

MIT License – see repository for details.

---

## Related Tools

- [ast-grep](https://ast-grep.github.io/) – Multi-language AST-based search
- [semgrep](https://semgrep.dev/) – Pattern-based code analysis
- [bat](https://github.com/sharkdp/bat/) – Syntax highlighting for cat

---

**Author:** Alan Rockefeller  
**Repository:** [github.com/AlanRockefeller/printfunction.sh](https://github.com/AlanRockefeller/printfunction.sh)
