# Changelog

## printfunction.sh [1.4.0] - 2026-01-29

#### Added
- **`ripgrep` Integration:** Added an optimization layer that uses `rg` (if installed) to pre-filter files before Python AST parsing, significantly reducing runtime on large codebases.
- **Bracket Glob Support:** Added support for shell-style bracket patterns in file paths (e.g., `tests/[a-c]*.py`).
- **Signal Handling:** Added `SIGPIPE` handling to prevent stack traces when piping output to tools like `head` or `less`.

#### Changed
- **Optimized Globbing:** Recursive globs (`**/*.py`) now use an optimized directory walk that applies ignore filters *during* discovery rather than after.
- **Fast-Path Scanning:** Files are now pre-scanned for the target string to skip AST parsing for files that clearly don't contain the definition.
- **Ignore List:** Added `site-packages`, `dist-packages`, and `verify_venv` to the default ignore configuration.

#### Fixed
- **Environment Hygiene:** Explicitly unset internal environment variables (`PF_MISSING_ROOTS`, `PF_MATCHES_FILE`, etc.) to prevent leakage from wrapper scripts.

## printfunction.sh [1.3.3] - 2026-01-27

### Changed
- **More consistent highlighting:** When syntax highlighting is enabled and --type py is in effect, Python highlighting is now forced even in line-mode output for more uniform results.
- **Color control:** Added PF_COLOR_MODE=always|auto|never and improved NO_COLOR/TTY handling so wrappers (e.g., gitdiffshow -n) can reliably force monochrome output.

## gitdiffshow [1.0.2] - 2026-01-27

- **Consistent color behavior:** --no-color/-n now forces monochrome output for both git diff and extracted function/snippet context by propagating PF_COLOR_MODE=never to printfunction.sh.
- **Color mode passthrough:** When color is enabled (--color[=auto|always|never]), the chosen mode is forwarded to printfunction.sh so diff output and function context follow the same policy.

## printfunction.sh [1.3.2] - 2026-01-27

### Changed
- **Default List Mode:**
  - When you provide only files/roots (no query/--regex/--at/line mode), the tool now defaults to listing available definitions (equivalent to --list) instead of erroring with “Missing FUNCTION_NAME”.
  - This removes the "Missing FUNCTION_NAME" error for commands like `printfunction .` or `printfunction myfile.py` and makes exploring a new codebase faster.

## gitdiffshow [1.0.1] - 2026-01-27

### Added to gitdiffshow
- **Color control flags:**
  - `--color` / `--no-color` (alias `-n`) to force or disable ANSI color output.
  - Useful for copying output into AI tools or logs.
- **Pager disabling:**
  - Pagers (like `less`) are now explicitly disabled for `git diff` and syntax highlighting tools (`bat`, etc.) to ensure direct terminal output.

## printfunction.sh [1.3.1] - 2026-01-26

### Added
- **File:range syntax** for easy pasting from Claude Code output or error messages:
  - `app.py:100-200` extracts lines 100-200 from app.py
  - `app.py:~100-200` extracts smart context around lines 100-200
  - Useful for quickly viewing code referenced in IDE output or error messages

### Fixed
- **--at option improvements:**
  - Help text now explicitly states that `--at PATTERN` uses regex matching
  - Added validation to prevent incompatible combinations: `--at` with `--regex`, `--list`, or a positional QUERY
  - Per-file non-matches are silent (normal behavior); overall no-match exits with code 1
  - Improved code clarity: restructured variable flow for line mode resolution

## printfunction.sh [1.2] - 2026-01-25

### Added
- Added gitdiffshow - shows context around the diffs displayed by git diff
- Multi-file search support: run `printfunction.sh` against multiple files, directories (recursive), and `**` globs.
- New `--type TYPE` filter to restrict scanned files (`py` default, `all` for no extension filtering).
- New `--context N` option to add surrounding context lines around `lines START-END` and smart `~START-END` output.
- Per-file headers in output to make multi-file results readable.
- `--list` now works across multiple inputs and can be filtered by `QUERY` (name/qualname) or `--regex`.

### Changed
- CLI usage changed from `printfunction.sh FILENAME [FUNCTION_NAME]` to `printfunction.sh [QUERY] [FILES...]`.
- `--first` behavior is now “first match per file” instead of “first match overall”.
- Syntax highlighting behavior updated for multi-file output: defaults to plain highlighting; uses Python highlighting when scanning `--type py` and not in line mode.
- Improved argument parsing and validation for mixed modes (`--regex`, `--list`, line mode, and query mode).
- Line-range parsing now supports both `-` and `–`, plus smart ranges prefixed with `~`.

### Fixed
- Query parsing bug where a previously-set `QUERY` wasn’t considered when deciding whether later bare ranges (`10-20`) should be treated as line mode; now correctly errors unless `lines` is used or the range is the first arg.
- More robust glob handling and clearer warnings when globs match no files.



## printfunction.sh [1.1] - 2026-01-25
### Added
- Line-range output mode for any file type:
  - `lines START-END` prints an inclusive numbered range.
  - `START-END` or `~START-END` shorthand accepted as the second positional argument.
- “Smart context” mode with `~START-END`:
  - For `.py/.pyw`: prints the smallest enclosing `def`/`class` that contains the range.
  - For non-Python files: prints a padded numbered range around the requested lines.

### Changed
- Help text and examples now use the actual script name `printfunction.sh`.
- In line-range mode, syntax highlighting is no longer forced to Python:
  - `bat/batcat` uses `--file-name "$FILENAME"` for better language detection.
  - `pygmentize` uses `-g` for generic highlighting.

### Fixed
- Clear error message when attempting function extraction on non-`.py/.pyw` files (instead of a confusing Python parse error).
