# gitdiffshow

**Author:** Alan Rockefeller  
**Version:** 1.1.1
**Date:** March 26, 2026
**License:** MIT  
**Repository:** <https://github.com/AlanRockefeller/printfunction.sh>

## Overview

`gitdiffshow` is a smart git diff viewer that provides contextual, syntax-highlighted output for changed files. Instead of showing raw diffs, it intelligently displays the relevant portions of your code with proper context.

## Key Features

- **Smart Python handling**: For Python files, shows only the functions/methods containing changes
- **Syntax highlighting**: Leverages `bat`/`batcat` or `pygmentize` for colored output
- **Binary file skipping**: Skips binary files by default (use `--binarydiff` to include them)
- **Configurable context**: Adjust the number of lines shown around changes
- **Multiple output modes**: View excerpts or entire files
- **Works with any git diff syntax**: Supports all standard git revision specifications
- **Patch file support**: Review GitHub PR diffs against local code without checking out the branch

## Installation

Both Bash and Fish shell versions are available:

```bash
# Download the script for your shell
curl -o ~/.local/bin/gitdiffshow https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/gitdiffshow.bash
# or for Fish shell:
curl -o ~/.local/bin/gitdiffshow https://raw.githubusercontent.com/AlanRockefeller/printfunction.sh/main/gitdiffshow.fish

# Make executable
chmod +x ~/.local/bin/gitdiffshow
```

## Usage

```bash
gitdiffshow [OPTIONS] [git-diff-revspec...]
gitdiffshow --patch FILE [OPTIONS]
```

### Examples

```bash
# Show changes in working directory
gitdiffshow

# Show staged changes
gitdiffshow --cached

# Show changes from HEAD
gitdiffshow HEAD

# Show changes between branches
gitdiffshow main..feature-branch

# Show entire files (not just excerpts)
gitdiffshow --all

# Show changes between specific commits
gitdiffshow abc123..def456

# Show changes with full git diff output (useful for AI code review context)
gitdiffshow --diff HEAD

# Review a GitHub PR patch file
gitdiffshow --patch pr-123.patch
gitdiffshow --patch pr-123.patch --diff

# Pipe a PR patch from GitHub
curl -L https://github.com/OWNER/REPO/pull/123.patch | gitdiffshow --patch -

# Show changes including binary files
gitdiffshow --binarydiff
```

## Default Behavior

By default, `gitdiffshow` shows all changed files in the repository regardless of your current working directory. Use `--relative` to limit output to files under the current directory. Binary files are skipped by default.

### For Python Files (*.py)

`gitdiffshow` attempts to locate `print_function.sh` in your PATH. If found, it uses it to extract and display only the functions and methods that were modified. This provides a clean, focused view of code changes. If `print_function.sh` is missing, it falls back to showing hunks with context.

### For Other Files

`gitdiffshow` displays hunks of changes with several lines of context around each change.

## Configuration

### Context Size

Control how many lines are shown around changes:

```bash
export GITDIFFSHOW_CONTEXT=30
```

### Debug Mode

Enable Python error output for troubleshooting:

```bash
export GITDIFFSHOW_DEBUG=1
```

## Command-Line Flags

- `--all` - Print entire file contents with line numbers
- `--printwholefile` - Same as `--all` (alternative syntax)
- `--diff` - Print git diff output in addition to the function context
- `--patch FILE` - Read diff from a patch file instead of running `git diff`. Use `-` for stdin. Patch paths are resolved against the git repo root (if in a repo) or the current directory. Cannot be combined with git diff revision arguments.
- `--binarydiff` - Show diff for binary files (default: skip binary files)
- `--relative` - Only show files relative to the current directory (by default, all repo files are shown)
- `--wholefile` - Same as `--all` (alternative syntax)
- `--whole-file` - Same as `--all` (alternative syntax)
- `--color[=MODE]` - Force ANSI color output. `MODE` can be `always`, `never`, or `auto` (default: `auto`). Bare `--color` implies `always`.
- `--no-color`, `-n` - Disable ANSI color (best for pasting into AI)
- `-h`, `--help` - Display help information

## Dependencies

### Required
- `git` - Version control system
- `python3` - For Python file analysis

### Optional (for enhanced output)
- `bat` or `batcat` - Syntax highlighting and line numbers (recommended)
- `pygmentize` - Fallback syntax highlighting
- `printfunction.sh` (or `print_function.sh`) - For optimal Python function display ([available here](https://github.com/AlanRockefeller/printfunction.sh))

### Fallback
If no syntax highlighters are available, the tool falls back to plain numbered output using `nl`.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Author

**Alan Rockefeller** - [GitHub](https://github.com/AlanRockefeller)

## Repository

The source code is available on GitHub: [AlanRockefeller/printfunction.sh](https://github.com/AlanRockefeller/printfunction.sh).

## Related Tools

- [`printfunction.sh` (aka `print_function.sh`)](https://github.com/AlanRockefeller/printfunction.sh) - Extract and display individual Python functions (used internally by gitdiffshow)
