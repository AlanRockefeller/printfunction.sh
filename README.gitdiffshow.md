# gitdiffshow

**Author:** Alan Rockefeller  
**Version:** 1.0.1  
**Date:** January 27, 2026  
**License:** MIT  
**Repository:** <https://github.com/AlanRockefeller/printfunction.sh>

## Overview

`gitdiffshow` is a smart git diff viewer that provides contextual, syntax-highlighted output for changed files. Instead of showing raw diffs, it intelligently displays the relevant portions of your code with proper context.

## Key Features

- **Smart Python handling**: For Python files, shows only the functions/methods containing changes
- **Syntax highlighting**: Leverages `bat`/`batcat` or `pygmentize` for colored output
- **Configurable context**: Adjust the number of lines shown around changes
- **Multiple output modes**: View excerpts or entire files
- **Works with any git diff syntax**: Supports all standard git revision specifications

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
gitdiffshow [--all|--printwholefile] [--diff] [--color[=MODE]|--no-color] [git-diff-revspec...]
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
```

## Default Behavior

### For Python Files (*.py)
- Displays only the complete functions/methods that contain changed lines
- Shows small numbered excerpts for module-level or class-level changes
- Requires `printfunction.sh` for optimal output (falls back to excerpts if unavailable)

### For Non-Python Files
- Shows numbered excerpts around changed hunks
- Context size defaults to 20 lines (configurable)

## Configuration

### Adjust Context Size

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

## How It Works

1. **Git diff analysis**: Identifies changed files and line numbers
2. **Python parsing**: For `.py` files, uses AST parsing to map changes to functions/classes
3. **Smart context**: Groups nearby changes and displays relevant code sections
4. **Syntax highlighting**: Applies color and formatting for readability

## Output Format

```text
Showing N changed file(s):
   path/to/file1.py
   path/to/file2.js
─────────────────────────────────────────────────

===== path/to/file1.py =====

--- function MyClass.my_method (lines 45-67) ---
[syntax-highlighted function code with line numbers]

--- class MyClass (lines 23-28) ---
[syntax-highlighted excerpt for class-level changes]

Done! N files shown.
```

## Supported Shells

- **Bash**: `gitdiffshow.bash`
- **Fish**: `gitdiffshow.fish`

Both versions provide identical functionality.

## Troubleshooting

### No output shown
```bash
# Check if there are actually changes
git diff --name-only

# For staged changes, use:
gitdiffshow --cached
```

### Python analysis not working
- Ensure `python3` is installed and in PATH
- Enable debug mode: `export GITDIFFSHOW_DEBUG=1`
- Check for syntax errors in your Python files

### Missing syntax highlighting
```bash
# Install bat (recommended)
# Ubuntu/Debian:
apt install bat

# macOS:
brew install bat

# Or install pygmentize
pip install pygments
```

## License

MIT License - see repository for full license text.

## Contributing

Contributions welcome! Please submit issues and pull requests to the [GitHub repository](https://github.com/AlanRockefeller/printfunction.sh).

## Related Tools

- [`printfunction.sh` (aka `print_function.sh`)](https://github.com/AlanRockefeller/printfunction.sh) - Extract and display individual Python functions (used internally by gitdiffshow)


