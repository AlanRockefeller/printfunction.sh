# Changelog

## [1.2] - 2026-01-25

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



## [1.1] - 2026-01-25
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
