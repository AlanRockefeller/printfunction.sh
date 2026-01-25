# Changelog

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
