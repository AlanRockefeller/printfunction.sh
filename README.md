# printfunction.sh

**Author:** Alan Rockefeller  
**Date:** January 10, 2026  
**Repository:** [https://github.com/AlanRockefeller/printfunction.sh](https://github.com/AlanRockefeller/printfunction.sh)

---

A robust, structure-aware command-line tool to extract Python function and method definitions from source files.

Unlike `grep` or `sed`, this tool uses Python's abstract syntax tree (AST) to precisely locate code. It correctly handles multi-line definitions, decorators, docstrings, and nested classes without breaking on edge cases.

## Features

* **AST Precision:** Understands Python structure and captures complete function bodies (including decorators) regardless of indentation style or complexity.
* **Smart Targeting:** Extract top-level functions (`main`), class methods (`MyClass.save`), or deeply nested closures (`outer.inner`).
* **Import Analysis:** Automatically detect and include only the imports *actually used* by the extracted function with `--import=used`.
* **Regex Support:** Find functions using patterns (e.g., extract all tests: `--regex '^test_'`).
* **Syntax Highlighting:** Auto-detects `bat`, `batcat`, or `pygmentize` for colored output when outputting to a terminal.
* **Intelligent Error Messages:** Suggests similar function names using fuzzy matching when a target isn't found.
* **Deduplication:** Handles redefinitions cleanly—prints all matches by default for debugging, or use `--first` for only the initial definition.

## Installation

1. Save the script as `printfunction.sh`:
   ```bash
   curl -o printfunction.sh https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/printfunction.sh
   ```

2. Make it executable:
   ```bash
   chmod +x printfunction.sh
   ```

3. (Optional) Move it to your PATH:
   ```bash
   sudo mv printfunction.sh /usr/local/bin/printfunction
   ```

## Usage

```bash
./printfunction.sh [OPTIONS] FILENAME [FUNCTION_NAME]
```

### Options

| Option | Description |
|--------|-------------|
| `--all` | Search nested scopes (functions inside functions/methods). |
| `--first` | If a function is defined multiple times, print only the first match. |
| `--import` | Include all module/class-level imports. |
| `--import=all` | Same as `--import` (explicit form). |
| `--import=used` | **Smart mode:** Analyze the function body and print only the imports it references. |
| `--import=none` | Explicitly disable import extraction. |
| `--list` | List all available function names in the file instead of printing code. |
| `--regex PATTERN` | Match functions by regex applied to the fully qualified name. |
| `-h, --help` | Show help message with examples. |

### Function Name Syntax

The `FUNCTION_NAME` argument supports several formats:

* **Simple name:** `foo` - matches any function named `foo`
* **Class method:** `ClassName.method` - matches a specific method in a class
* **Nested method:** `Outer.Inner.method` - matches methods in nested classes
* **Nested function** (with `--all`): `outer.inner` - matches a function defined inside another function

## Examples

### 1. Basic Extraction

Extract a top-level function named `calculate`:

```bash
./printfunction.sh math_utils.py calculate
```

### 2. Class Methods

Target a specific method inside a class using dot notation:

```bash
./printfunction.sh models.py User.save_to_db
```

### 3. Smart Import Extraction

Extract a function with only the libraries it actually uses. Perfect for creating self-contained snippets or understanding dependencies:

```bash
# Finds 'def fetch_data' and includes 'import requests' only if 'requests' is used inside
./printfunction.sh --import=used scraper.py fetch_data
```

**Example output:**
```python
import requests
from typing import Dict

####################

def fetch_data(url: str) -> Dict:
    """Fetch JSON data from a URL."""
    response = requests.get(url)
    return response.json()
```

### 4. Nested Functions

Extract functions defined inside other functions (requires `--all`):

```bash
./printfunction.sh --all decorators.py retry.exponential_backoff
```

### 5. Regex & Bulk Extraction

Print every function that starts with `test_`:

```bash
./printfunction.sh --regex '^test_' tests/unit_tests.py
```

Or match methods in a specific class:

```bash
./printfunction.sh --regex 'DatabaseHandler\\..*' db.py
```

### 6. Listing Available Functions

Not sure what's in the file? List all available functions:

```bash
./printfunction.sh --list complex_script.py
```

**Output:**
```
main  (line 10)
MyClass.process  (line 25)
helper_function  (line 45)
```

Include nested functions in the listing:

```bash
./printfunction.sh --list --all complex_script.py
```

**Output:**
```
main  (line 10)
MyClass.process  (line 25)
MyClass.process.helper  (line 30)
helper_function  (line 45)
```

### 7. Combining Options

Extract the first definition of a function with its imports:

```bash
./printfunction.sh --first --import=used api.py handle_request
```

## Requirements

### Required
* **Python 3.8+** (uses `ast.get_source_segment` and `tokenize` module)
* **Bash** (standard on Linux/macOS)

### Optional (for syntax highlighting)

The script automatically detects and uses these tools if installed (in order of preference):

1. `bat` / `batcat` (Recommended - best highlighting)
2. `pygmentize` (from Pygments package)

To install `bat`:
```bash
# macOS
brew install bat

# Ubuntu/Debian
sudo apt install bat

# Other Linux (check package manager or download from GitHub)
```

To install `pygmentize`:
```bash
pip install pygments
```

## How It Works

1. **AST Parsing:** The script parses your Python file into an abstract syntax tree using Python's built-in `ast` module.
2. **Qualified Name Tracking:** As it walks the tree, it builds fully-qualified names by tracking class and function nesting context.
3. **Smart Matching:** Matches your target against these qualified names, supporting both simple names and dot-notation paths.
4. **Source Extraction:** Uses line number information from AST nodes to extract the exact source code, including decorators.
5. **Import Analysis:** For `--import=used`, walks the function's AST to collect referenced names and matches them against available imports.

## Troubleshooting

### "Function not found"

The tool uses `difflib` to suggest similar function names when you make a typo. Check the suggestions in the error output:

```
Couldn't find a match in: myfile.py
  Target: 'proces'

Tips:
  • List available definitions:
      ./printfunction.sh --list myfile.py
  
Closest matches (fully-qualified):
  - MyClass.process
  - process_data
```

### Multiple Definitions

If a function is defined multiple times (e.g., in conditional blocks or for monkey-patching), the tool prints both versions in source order by default. Use `--first` to get only the initial definition:

```bash
./printfunction.sh --first myfile.py conditional_function
```

### Import Detection Issues

The `--import=used` mode does basic static analysis and may:
* **Over-include** star imports (`from module import *`) as it can't determine what's actually imported
* **Miss** dynamically accessed attributes or `getattr()` usage

For these edge cases, use `--import=all` to include all module-level imports.

### Syntax Errors

The tool requires valid Python syntax. If your file has syntax errors:

```
Error: syntax error while parsing myfile.py:
  invalid syntax (myfile.py, line 42)
Tip: this tool requires the file to be valid Python syntax.
```

Fix the syntax errors in your source file before using the tool.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests on GitHub.

## License

MIT License - see repository for details.

## Related Tools

* **[ast-grep](https://ast-grep.github.io/)** - Multi-language structural search using AST
* **[semgrep](https://semgrep.dev/)** - Pattern-based code analysis
* **[bat](https://github.com/sharkdp/bat)** - Syntax highlighting for cat

---

**Why use this instead of grep?**

```bash
# grep might break on multi-line definitions:
grep -A 20 "def process" myfile.py  # How many lines? Misses decorators!

# This tool gets it right:
./printfunction.sh myfile.py MyClass.process  # Exact, complete, always works
```
