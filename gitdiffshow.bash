#!/usr/bin/env bash
# ======================================================================
# gitdiffshow - Show context for files changed in git diff
# ======================================================================

# ----------------------------------------------------------------------
# Force NO PAGERS anywhere (important for copy/paste into AI).
# Git and bat commonly page with `less` depending on user config.
# ----------------------------------------------------------------------
# We pass these to child processes via 'env' to avoid polluting the shell
# if this script is sourced.
GITDIFFSHOW_NO_PAGER_ENV=(PAGER=cat GIT_PAGER=cat BAT_PAGER=cat BAT_PAGING=never LESS=FRX)

#
# DEFAULT BEHAVIOR:
#   - For Python files (*.py): print ONLY the functions/methods that contain
#     the changed lines (using print_function.sh), plus small numbered excerpts
#     for any module/class-scope changes.
#   - For non-Python files: print numbered excerpts around changed hunks.
#
# FLAGS:
#   --printwholefile   Print the entire file with line numbers (old behavior)
#   --all              Alias for --printwholefile  (requested)
#   --diff             Print git diff output in addition to the function context
#   --patch FILE       Read diff from a patch file (or - for stdin) instead of git diff
#   --relative         Only show files relative to the current directory
#   --color            Force ANSI color output
#   --no-color         Disable ANSI color (best for pasting into AI)
#
# TIP:
#   Tune excerpt size with:
#     export GITDIFFSHOW_CONTEXT=30
#
# Version 1.1.0 by Alan Rockefeller - March 17, 2026
#
# ======================================================================


set -euo pipefail

__gitdiffshow_find_printfunc() {
  local candidates=(print_function.sh printfunction.sh print_function printfunction)
  local c
  for c in "${candidates[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

__gitdiffshow_print_excerpt() {
  local file="$1"
  local start_line="${2:-}"
  local end_line="${3:-}"
  local label="${4:-}"

  [[ -z "$start_line" || -z "$end_line" ]] && return 0

  local color_mode="${GITDIFFSHOW_COLOR_MODE:-auto}"
  local bat_color="$color_mode"

  echo "--- $label (lines $start_line-$end_line) ---"

  # Best: bat/batcat can show real file line numbers and syntax highlight directly.
  if command -v batcat >/dev/null 2>&1; then
    env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" batcat --color="$bat_color" --paging=never --style=numbers --line-range "${start_line}:${end_line}" "$file"
    return 0
  elif command -v bat >/dev/null 2>&1; then
    env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" bat --color="$bat_color" --paging=never --style=numbers --line-range "${start_line}:${end_line}" "$file"
    return 0
  fi

  # Fallback: pygmentize (we slice the file then set linenostart so numbers match)
  if [[ "$color_mode" != "never" ]] && command -v pygmentize >/dev/null 2>&1; then
    if sed -n "${start_line},${end_line}p" "$file" | pygmentize -g -f terminal256 -O "style=monokai,linenos=1,linenostart=${start_line}" 2>/dev/null; then
      return 0
    fi
    sed -n "${start_line},${end_line}p" "$file" | pygmentize -g -f terminal256 -O "linenos=1,linenostart=${start_line}"
    return 0
  fi

  # Last resort: plain numbered output
  sed -n "${start_line},${end_line}p" "$file" | nl -ba -n ln -v "$start_line"
}

# __gitdiffshow_patch_helper: Unified Python-based patch parser.
# Handles all patch parsing operations via a single Python script.
#
# Usage:
#   __gitdiffshow_patch_helper <command> <patch_file> [args...]
#
# Commands:
#   list-files <patch_file>
#       Output one line per file entry: STATUS|OLD_PATH|NEW_PATH
#       STATUS is one of: modified, added, deleted, renamed, copied
#
#   analyze <patch_file> <file_path>
#       Output analysis lines (same format as __gitdiffshow_analyze_file):
#       HUNK|start|end|label, FUNC|qualname|start|end, NONFUNC|start|end|label, NOTE|msg
#
#   raw-diff <patch_file> <file_path>
#       Output the raw diff section for a single file from the patch.
#
# <patch_file> can be "-" to read from stdin (already captured to a temp file by caller).
#
__gitdiffshow_patch_helper() {
  local cmd="$1"; shift
  local patch_file="$1"; shift
  local -a extra_args=("$@")

  local stderr_target="/dev/null"
  if [[ -n "${GITDIFFSHOW_DEBUG:-}" ]]; then
    stderr_target="/dev/stderr"
  fi

  python3 - "$cmd" "$patch_file" "${extra_args[@]}" 2>"$stderr_target" <<'PYEOF'
import ast
import os
import re
import sys
import tokenize
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Patch parser: split a unified diff into per-file sections
# ---------------------------------------------------------------------------

@dataclass
class PatchFile:
    """One file entry parsed from a unified diff."""
    status: str          # modified, added, deleted, renamed, copied
    old_path: str        # path on the --- side (empty for added)
    new_path: str        # path on the +++ side (empty for deleted)
    header: str          # the "diff --git ..." header line
    raw_text: str        # full text of this file's diff section

def parse_patch(patch_text: str) -> List[PatchFile]:
    """Parse a unified diff into per-file PatchFile entries."""
    # Split on "diff --git" boundaries
    file_re = re.compile(r"^diff --git ", re.M)
    splits = file_re.split(patch_text)
    # First element is anything before the first "diff --git" (usually empty)
    results: List[PatchFile] = []
    for section in splits[1:]:
        full_section = "diff --git " + section
        header_line = full_section.split("\n", 1)[0]

        # Parse old/new paths from the header: diff --git a/old b/new
        # Handle paths with spaces by matching "a/" prefix and " b/" separator
        hdr_match = re.match(r"diff --git a/(.*?) b/(.*)", header_line)
        if not hdr_match:
            continue
        raw_old = hdr_match.group(1)
        raw_new = hdr_match.group(2)

        # Determine status from the diff header block
        status = "modified"
        old_path = raw_old
        new_path = raw_new

        if re.search(r"^new file mode", full_section, re.M):
            status = "added"
            old_path = ""
        elif re.search(r"^deleted file mode", full_section, re.M):
            status = "deleted"
            new_path = ""
        else:
            # Check for rename/copy
            rename_from = re.search(r"^rename from (.+)", full_section, re.M)
            rename_to = re.search(r"^rename to (.+)", full_section, re.M)
            if rename_from and rename_to:
                status = "renamed"
                old_path = rename_from.group(1)
                new_path = rename_to.group(1)
            else:
                copy_from = re.search(r"^copy from (.+)", full_section, re.M)
                copy_to = re.search(r"^copy to (.+)", full_section, re.M)
                if copy_from and copy_to:
                    status = "copied"
                    old_path = copy_from.group(1)
                    new_path = copy_to.group(1)

        # Also check --- / +++ for /dev/null confirmation
        minus_match = re.search(r"^--- (?:a/(.+)|/dev/null)", full_section, re.M)
        plus_match = re.search(r"^\+\+\+ (?:b/(.+)|/dev/null)", full_section, re.M)
        if minus_match and minus_match.group(1) is None and status != "added":
            status = "added"
            old_path = ""
        if plus_match and plus_match.group(1) is None and status != "deleted":
            status = "deleted"
            new_path = ""

        results.append(PatchFile(
            status=status,
            old_path=old_path,
            new_path=new_path,
            header=header_line,
            raw_text=full_section,
        ))
    return results


def find_patch_for_path(entries: List[PatchFile], target_path: str) -> Optional[PatchFile]:
    """Find the PatchFile entry whose new_path (or old_path for deletes) matches target_path."""
    for e in entries:
        # For display, the "current" path is new_path for non-deletes, old_path for deletes
        display_path = e.new_path if e.status != "deleted" else e.old_path
        if display_path == target_path:
            return e
    return None


# ---------------------------------------------------------------------------
# Hunk analysis (shared with git-diff mode)
# ---------------------------------------------------------------------------

CTX = int(os.environ.get("GITDIFFSHOW_CONTEXT", "20"))
hunk_re = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)

def changed_lines_from_patch_text(patch_text: str) -> List[int]:
    changed: List[int] = []
    for m in hunk_re.finditer(patch_text):
        new_start = int(m.group(3))
        new_count = int(m.group(4) or "1")
        if new_count == 0:
            changed.append(new_start)
        else:
            changed.extend(range(new_start, new_start + new_count))
    return sorted(set(changed))


def merge_ranges(ranges: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    if not ranges:
        return []
    ranges = sorted(ranges)
    out: List[List[int]] = [[ranges[0][0], ranges[0][1]]]
    for s, e in ranges[1:]:
        if s <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]

def ranges_around(lines_: List[int], label: str, nlines: int) -> List[Tuple[int, int, str]]:
    rs = []
    for ln in lines_:
        s = max(1, ln - CTX)
        e = min(nlines, ln + CTX)
        rs.append((s, e))
    merged = merge_ranges(rs)
    return [(a, b, label) for a, b in merged]


def analyze_file_with_patch_text(path: str, patch_text: str):
    """Analyze a file given its patch text. Print analysis lines to stdout."""
    if not patch_text.strip():
        return

    if "Binary files " in patch_text:
        print("NOTE|Binary diff (no text hunks)")
        return

    changed_lines = changed_lines_from_patch_text(patch_text)
    if not changed_lines:
        print("NOTE|No text hunks found")
        return

    if not os.path.exists(path):
        print("NOTE|File not found in working tree (likely deleted)")
        return

    try:
        with tokenize.open(path) as f:
            source = f.read()
    except Exception as e:
        print(f"NOTE|Could not read file: {e}")
        return

    lines = source.splitlines(True)
    nlines = len(lines)
    if nlines == 0:
        print("NOTE|Empty file")
        return

    def clamp_line(n: int) -> int:
        if n < 1:
            return 1
        if n > nlines:
            return nlines
        return n

    changed_lines = [clamp_line(x) for x in changed_lines]

    # Always emit generic hunk-based context ranges (fallback path)
    for s, e, label in ranges_around(changed_lines, "diff context", nlines):
        print(f"HUNK|{s}|{e}|{label}")

    # If it is not Python, stop here.
    if not path.endswith(".py"):
        return

    @dataclass(frozen=True)
    class DefSpan:
        qualname: str
        start: int
        end: int
        kind: str  # "func" or "class"

    def span_start_with_decorators(node: ast.AST) -> int:
        start = getattr(node, "lineno", 1)
        decs = getattr(node, "decorator_list", None) or []
        dec_lns = [getattr(d, "lineno", None) for d in decs]
        dec_lns = [x for x in dec_lns if isinstance(x, int) and x > 0]
        if dec_lns:
            start = min(start, min(dec_lns))
        return int(start)

    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as e:
        print(f"NOTE|Python parse failed (syntax error): {e}")
        return
    except Exception as e:
        print(f"NOTE|Python parse failed: {e}")
        return

    funcs: List[DefSpan] = []
    classes: List[DefSpan] = []

    class Extract(ast.NodeVisitor):
        def __init__(self) -> None:
            self.class_stack: List[str] = []
            self.func_stack: List[str] = []

        def _qn(self, name: str) -> str:
            return ".".join(self.class_stack + self.func_stack + [name])

        def visit_ClassDef(self, node: ast.ClassDef) -> None:
            qn = ".".join(self.class_stack + [node.name])
            start = span_start_with_decorators(node)
            end = int(getattr(node, "end_lineno", getattr(node, "lineno", start)))
            classes.append(DefSpan(qn, start, end, "class"))

            self.class_stack.append(node.name)
            try:
                self.generic_visit(node)
            finally:
                self.class_stack.pop()

        def _visit_func(self, node: ast.AST, name: str) -> None:
            qn = self._qn(name)
            start = span_start_with_decorators(node)
            end = int(getattr(node, "end_lineno", getattr(node, "lineno", start)))
            funcs.append(DefSpan(qn, start, end, "func"))

            self.func_stack.append(name)
            try:
                self.generic_visit(node)
            finally:
                self.func_stack.pop()

        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            self._visit_func(node, node.name)

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            self._visit_func(node, node.name)

    Extract().visit(tree)

    def innermost(spans: List[DefSpan], ln: int) -> Optional[DefSpan]:
        cands = [s for s in spans if s.start <= ln <= s.end]
        if not cands:
            return None
        cands.sort(key=lambda s: (s.end - s.start, s.start, s.qualname.count(".")))
        return cands[0]

    selected_funcs: Dict[str, DefSpan] = {}
    nonfunc_lines_by_label: Dict[str, List[int]] = {}

    for ln in changed_lines:
        f = innermost(funcs, ln)
        if f is not None:
            selected_funcs[f.qualname] = f
            continue

        c = innermost(classes, ln)
        if c is not None:
            label = f"class {c.qualname}"
            nonfunc_lines_by_label.setdefault(label, []).append(ln)
        else:
            nonfunc_lines_by_label.setdefault("module", []).append(ln)

    for qn, sp in sorted(selected_funcs.items(), key=lambda kv: (kv[1].start, kv[1].end, kv[0])):
        print(f"FUNC|{qn}|{sp.start}|{sp.end}")

    for label, lns in nonfunc_lines_by_label.items():
        for s, e, _ in ranges_around(sorted(set(lns)), label, nlines):
            print(f"NONFUNC|{s}|{e}|{label}")


# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

command = sys.argv[1]
patch_file = sys.argv[2]

with open(patch_file, "r") as f:
    patch_text = f.read()

entries = parse_patch(patch_text)

if command == "list-files":
    for e in entries:
        print(f"{e.status}|{e.old_path}|{e.new_path}")

elif command == "analyze":
    target_path = sys.argv[3]
    # Find the entry and analyze
    entry = find_patch_for_path(entries, target_path)
    if entry is None:
        print("NOTE|File not found in patch")
        sys.exit(0)
    # Resolve local file path for reading source
    local_path = sys.argv[4] if len(sys.argv) > 4 else target_path
    analyze_file_with_patch_text(local_path, entry.raw_text)

elif command == "raw-diff":
    target_path = sys.argv[3]
    entry = find_patch_for_path(entries, target_path)
    if entry:
        # Print the raw diff section for this file only
        print(entry.raw_text, end="")

else:
    print(f"Unknown command: {command}", file=sys.stderr)
    sys.exit(2)
PYEOF
}

__gitdiffshow_analyze_file() {
  local file="$1"; shift
  # Remaining args are passed through to `git diff`
  local -a args=("$@")

  # Bash heredoc is fine; feed to python for analysis.
  # Default: keep stderr quiet so output stays parseable.
  # Debug: set GITDIFFSHOW_DEBUG=1 to see Python errors.
  local stderr_target="/dev/null"
  if [[ -n "${GITDIFFSHOW_DEBUG:-}" ]]; then
    stderr_target="/dev/stderr"
  fi

  python3 - "$file" "${args[@]}" 2>"$stderr_target" <<'PY'
import ast
import os
import re
import subprocess
import sys
import tokenize
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

path = sys.argv[1]
git_args = sys.argv[2:]

CTX = int(os.environ.get("GITDIFFSHOW_CONTEXT", "20"))

def run_git_diff() -> str:
    cmd = ["git", "diff", "--unified=0", "--no-color"]
    cmd += git_args
    cmd += ["--", path]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return p.stdout or ""

patch = run_git_diff()

if not patch.strip():
    sys.exit(0)

if "Binary files " in patch:
    print("NOTE|Binary diff (no text hunks)")
    sys.exit(0)

hunk_re = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)

changed_lines: List[int] = []
for m in hunk_re.finditer(patch):
    new_start = int(m.group(3))
    new_count = int(m.group(4) or "1")
    if new_count == 0:
        changed_lines.append(new_start)
    else:
        changed_lines.extend(range(new_start, new_start + new_count))

changed_lines = sorted(set(changed_lines))
if not changed_lines:
    print("NOTE|No text hunks found")
    sys.exit(0)

if not os.path.exists(path):
    print("NOTE|File not found in working tree (likely deleted)")
    sys.exit(0)

try:
    with tokenize.open(path) as f:
        source = f.read()
except Exception as e:
    print(f"NOTE|Could not read file: {e}")
    sys.exit(0)

lines = source.splitlines(True)
nlines = len(lines)
if nlines == 0:
    print("NOTE|Empty file")
    sys.exit(0)

def clamp_line(n: int) -> int:
    if n < 1:
        return 1
    if n > nlines:
        return nlines
    return n

changed_lines = [clamp_line(x) for x in changed_lines]

def merge_ranges(ranges: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    if not ranges:
        return []
    ranges = sorted(ranges)
    out: List[List[int]] = [[ranges[0][0], ranges[0][1]]]
    for s, e in ranges[1:]:
        if s <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]

def ranges_around(lines_: List[int], label: str) -> List[Tuple[int, int, str]]:
    rs = []
    for ln in lines_:
        s = max(1, ln - CTX)
        e = min(nlines, ln + CTX)
        rs.append((s, e))
    merged = merge_ranges([(a, b) for a, b in rs])
    return [(a, b, label) for a, b in merged]

# Always emit generic hunk-based context ranges (fallback path)
for s, e, label in ranges_around(changed_lines, "diff context"):
    print(f"HUNK|{s}|{e}|{label}")

# If it is not Python, stop here.
if not path.endswith(".py"):
    sys.exit(0)

@dataclass(frozen=True)
class DefSpan:
    qualname: str
    start: int
    end: int
    kind: str  # "func" or "class"

def span_start_with_decorators(node: ast.AST) -> int:
    start = getattr(node, "lineno", 1)
    decs = getattr(node, "decorator_list", None) or []
    dec_lns = [getattr(d, "lineno", None) for d in decs]
    dec_lns = [x for x in dec_lns if isinstance(x, int) and x > 0]
    if dec_lns:
        start = min(start, min(dec_lns))
    return int(start)

try:
    tree = ast.parse(source, filename=path)
except SyntaxError as e:
    print(f"NOTE|Python parse failed (syntax error): {e}")
    sys.exit(0)
except Exception as e:
    print(f"NOTE|Python parse failed: {e}")
    sys.exit(0)

funcs: List[DefSpan] = []
classes: List[DefSpan] = []

class Extract(ast.NodeVisitor):
    def __init__(self) -> None:
        self.class_stack: List[str] = []
        self.func_stack: List[str] = []

    def _qn(self, name: str) -> str:
        return ".".join(self.class_stack + self.func_stack + [name])

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        qn = ".".join(self.class_stack + [node.name])
        start = span_start_with_decorators(node)
        end = int(getattr(node, "end_lineno", getattr(node, "lineno", start)))
        classes.append(DefSpan(qn, start, end, "class"))

        self.class_stack.append(node.name)
        try:
            self.generic_visit(node)
        finally:
            self.class_stack.pop()

    def _visit_func(self, node: ast.AST, name: str) -> None:
        qn = self._qn(name)
        start = span_start_with_decorators(node)
        end = int(getattr(node, "end_lineno", getattr(node, "lineno", start)))
        funcs.append(DefSpan(qn, start, end, "func"))

        # Always descend so we can map to nested defs too
        self.func_stack.append(name)
        try:
            self.generic_visit(node)
        finally:
            self.func_stack.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_func(node, node.name)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_func(node, node.name)

Extract().visit(tree)

def innermost(spans: List[DefSpan], ln: int) -> Optional[DefSpan]:
    cands = [s for s in spans if s.start <= ln <= s.end]
    if not cands:
        return None
    cands.sort(key=lambda s: (s.end - s.start, s.start, s.qualname.count(".")))
    return cands[0]

selected_funcs: Dict[str, DefSpan] = {}
nonfunc_lines_by_label: Dict[str, List[int]] = {}

for ln in changed_lines:
    f = innermost(funcs, ln)
    if f is not None:
        selected_funcs[f.qualname] = f
        continue

    c = innermost(classes, ln)
    if c is not None:
        label = f"class {c.qualname}"
        nonfunc_lines_by_label.setdefault(label, []).append(ln)
    else:
        nonfunc_lines_by_label.setdefault("module", []).append(ln)

for qn, sp in sorted(selected_funcs.items(), key=lambda kv: (kv[1].start, kv[1].end, kv[0])):
    print(f"FUNC|{qn}|{sp.start}|{sp.end}")

for label, lns in nonfunc_lines_by_label.items():
    for s, e, _ in ranges_around(sorted(set(lns)), label):
        print(f"NONFUNC|{s}|{e}|{label}")
PY
}

gitdiffshow() {
  local print_wholefile=0
  local show_diff=0
  local use_relative=0
  local color_mode="auto"
  local patch_file=""
  local -a revspec=()

  # Two-pass arg parsing: first pass to find --patch (which consumes next arg)
  local -a args_array=("$@")
  local i=0
  while [[ $i -lt ${#args_array[@]} ]]; do
    local a="${args_array[$i]}"
    case "$a" in
      --patch)
        if [[ $((i + 1)) -ge ${#args_array[@]} ]]; then
          echo "Error: --patch requires a FILE argument (use - for stdin)" >&2
          return 1
        fi
        patch_file="${args_array[$((i + 1))]}"
        i=$((i + 2))
        ;;
      --patch=*)
        patch_file="${a#*=}"
        i=$((i + 1))
        ;;
      --printwholefile|--wholefile|--whole-file|--all)
        print_wholefile=1
        i=$((i + 1))
        ;;
      --diff)
        show_diff=1
        i=$((i + 1))
        ;;
      --relative)
        use_relative=1
        i=$((i + 1))
        ;;
      --color)
        color_mode="always"
        i=$((i + 1))
        ;;
      --color=*)
        color_mode="${a#*=}"
        if [[ ! "$color_mode" =~ ^(always|never|auto)$ ]]; then
           echo "Error: Invalid color mode '$color_mode'. Use always, never, or auto." >&2
           return 1
        fi
        i=$((i + 1))
        ;;
      --no-color|--nocolor|-n)
        color_mode="never"
        i=$((i + 1))
        ;;
      -h|--help)
        cat <<'EOF'
gitdiffshow - Show context for files changed in git diff

USAGE:
  gitdiffshow [OPTIONS] [git-diff-revspec...]
  gitdiffshow --patch FILE [OPTIONS]

DEFAULT:
  - Shows all changed files in the repository (regardless of current directory)
  - Python files: print only affected functions/methods (via print_function.sh)
  - Other files: print numbered excerpts around changed hunks

FLAGS:
  --all              Print entire file contents with line numbers (alias)
  --printwholefile   Same as --all
  --diff             Print git diff output in addition to the function context
  --patch FILE       Read diff from a patch file instead of running git diff.
                     Use - for stdin. Patch paths are resolved against the git
                     repo root (if in a repo) or the current directory.
                     Cannot be combined with git diff revision arguments.
  --relative         Only show files relative to the current directory
  --color[=MODE]     Color mode: always, auto, never (default: auto). Bare --color implies always.
  --no-color, -n     Disable ANSI color (best for pasting into AI)

EXAMPLES:
  gitdiffshow
  gitdiffshow --cached
  gitdiffshow HEAD
  gitdiffshow main..
  gitdiffshow --all
  gitdiffshow --relative
  gitdiffshow --diff --no-color

  # Review a GitHub PR patch file:
  gitdiffshow --patch pr-123.patch
  gitdiffshow --patch pr-123.patch --diff
  curl -L https://github.com/OWNER/REPO/pull/123.patch | gitdiffshow --patch -

TIP: Tune excerpt size:
  export GITDIFFSHOW_CONTEXT=30
EOF
        return 0
        ;;
      *)
        revspec+=("$a")
        i=$((i + 1))
        ;;
    esac
  done

  # Mutual exclusion: --patch cannot be combined with revspecs
  if [[ -n "$patch_file" && "${#revspec[@]}" -gt 0 ]]; then
    echo "Error: --patch cannot be combined with git diff revision arguments" >&2
    return 1
  fi

  # ----- Patch file mode -----
  if [[ -n "$patch_file" ]]; then
    # If reading from stdin, capture to a temp file
    local tmp_patch=""
    if [[ "$patch_file" == "-" ]]; then
      tmp_patch="$(mktemp)"
      cat > "$tmp_patch"
      patch_file="$tmp_patch"
    elif [[ ! -f "$patch_file" ]]; then
      echo "Error: Patch file not found: $patch_file" >&2
      return 1
    fi

    # Determine base directory for resolving patch paths
    local base_dir
    base_dir="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

    # Get file list from patch
    local raw_list
    raw_list="$(__gitdiffshow_patch_helper list-files "$patch_file" || true)"

    local -a filenames=()
    local -a patch_paths=()      # paths as they appear in the patch
    local -a display_labels=()   # labels for display (includes status info)

    # Pre-compute real paths for --relative filtering (done once, not per-file)
    local real_cwd="" real_base=""
    if [[ "$use_relative" -eq 1 ]]; then
      real_cwd="$(cd "$PWD" && pwd -P)"
      real_base="$(cd "$base_dir" && pwd -P)"
    fi

    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local status old_path new_path
      IFS='|' read -r status old_path new_path <<<"$line"

      # Determine the display path and patch-lookup path
      local display_path="" patch_path=""
      case "$status" in
        modified|added|copied)
          display_path="$new_path"
          patch_path="$new_path"
          ;;
        deleted)
          display_path="$old_path"
          patch_path="$old_path"
          ;;
        renamed)
          display_path="$new_path"
          patch_path="$new_path"
          ;;
      esac

      [[ -z "$display_path" ]] && continue

      local abs_path="$base_dir/$display_path"

      # --relative: filter to files under CWD (lexical prefix check).
      # We check the parent directory exists so deleted files in valid dirs
      # are kept, but paths in completely absent trees are filtered out.
      if [[ "$use_relative" -eq 1 ]]; then
        local real_abs="$real_base/$display_path"
        if [[ "$real_abs" != "$real_cwd"/* ]]; then
          continue
        fi
        if [[ ! -d "$(dirname "$real_abs")" ]]; then
          continue
        fi
        display_path="${real_abs#"$real_cwd"/}"
        abs_path="$real_abs"
      fi

      filenames+=("$abs_path")
      patch_paths+=("$patch_path")

      local label="$display_path"
      case "$status" in
        added)   label="$display_path (new file)" ;;
        deleted) label="$display_path (deleted)" ;;
        renamed) label="$new_path (renamed from $old_path)" ;;
        copied)  label="$new_path (copied from $old_path)" ;;
      esac
      display_labels+=("$label")
    done <<<"$raw_list"

    if [[ "${#filenames[@]}" -eq 0 ]]; then
      echo "No files found in patch: $patch_file"
      [[ -n "$tmp_patch" ]] && rm -f "$tmp_patch"
      return 0
    fi

    local printfun=""
    if printfun="$(__gitdiffshow_find_printfunc)"; then
      :
    else
      printfun=""
    fi

    export GITDIFFSHOW_COLOR_MODE="$color_mode"

    echo "Showing ${#filenames[@]} changed file(s) from patch:"
    local idx
    for idx in "${!display_labels[@]}"; do
      echo "   ${display_labels[$idx]}"
    done
    echo "─────────────────────────────────────────────────"

    for idx in "${!filenames[@]}"; do
      local f="${filenames[$idx]}"
      local pp="${patch_paths[$idx]}"
      local dl="${display_labels[$idx]}"

      if [[ ! -f "$f" ]]; then
        echo
        echo "===== $dl ====="
        echo
        echo "  (file not in working tree — showing patch diff)"
        echo
        __gitdiffshow_patch_helper raw-diff "$patch_file" "$pp" || true
        echo
        continue
      fi

      echo
      echo "===== $dl ====="
      echo

      if [[ "$show_diff" -eq 1 ]]; then
        echo "--- Patch Diff ---"
        __gitdiffshow_patch_helper raw-diff "$patch_file" "$pp" || true
        echo
      fi

      if [[ "$print_wholefile" -eq 1 ]]; then
        if command -v batcat >/dev/null 2>&1; then
          env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" batcat --color="$color_mode" --paging=never --style=numbers "$f"
        elif command -v bat >/dev/null 2>&1; then
          env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" bat --color="$color_mode" --paging=never --style=numbers "$f"
        elif [[ "$color_mode" != "never" ]] && command -v pygmentize >/dev/null 2>&1; then
          pygmentize -g -f terminal256 -O "style=monokai,linenos=1" "$f" 2>/dev/null || \
          pygmentize -g -f terminal256 -O "linenos=1" "$f"
        else
          nl -ba -n ln "$f"
        fi
        continue
      fi

      local raw
      raw="$(__gitdiffshow_patch_helper analyze "$patch_file" "$pp" "$f" || true)"

      local -a funcs=()
      local -a nonfunc=()
      local -a hunks=()
      local -a notes=()

      local line
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r kind p2 p3 p4 <<<"$line" || true
        case "$kind" in
          NOTE)    notes+=("$p2") ;;
          FUNC)    funcs+=("${p2}|${p3}|${p4}") ;;
          NONFUNC) nonfunc+=("${p2}|${p3}|${p4}") ;;
          HUNK)    hunks+=("${p2}|${p3}|${p4}") ;;
        esac
      done <<<"$raw"

      local n
      for n in "${notes[@]}"; do
        echo "Notes:  $n"
      done
      if [[ "${#notes[@]}" -gt 0 ]]; then
        echo
      fi

      # Preferred: Python funcs + print_function present
      if [[ "$f" == *.py && -n "$printfun" && "${#funcs[@]}" -gt 0 ]]; then
        local rec qn s e
        for rec in "${funcs[@]}"; do
          IFS='|' read -r qn s e <<<"$rec"
          echo "--- function $qn (lines $s-$e) ---"
          if [[ "$color_mode" == "never" ]]; then
             env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" env -u CLICOLOR_FORCE -u BAT_FORCE_COLOR -u PF_FORCE_COLOR NO_COLOR=1 TERM=dumb PF_COLOR_MODE=never "$printfun" --all "$f" "$qn"
          else
             env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" PF_COLOR_MODE="$color_mode" PF_FORCE_COLOR=1 BAT_FORCE_COLOR=1 CLICOLOR_FORCE=1 TERM=${TERM:-xterm-256color} "$printfun" --all "$f" "$qn"
          fi
          echo
        done

        for rec in "${nonfunc[@]}"; do
          IFS='|' read -r s e label <<<"$rec"
          __gitdiffshow_print_excerpt "$f" "$s" "$e" "$label"
          echo
        done
        continue
      fi

      # Fallback: excerpts around hunks (works for any file)
      if [[ "${#hunks[@]}" -gt 0 ]]; then
        local rec s e label
        for rec in "${hunks[@]}"; do
          IFS='|' read -r s e label <<<"$rec"
          __gitdiffshow_print_excerpt "$f" "$s" "$e" "$label"
          echo
        done
      else
        if command -v batcat >/dev/null 2>&1; then
          batcat --color="$color_mode" --paging=never --style=numbers "$f"
        elif command -v bat >/dev/null 2>&1; then
          bat --color="$color_mode" --paging=never --style=numbers "$f"
        else
          nl -ba -n ln "$f"
        fi
      fi
    done

    echo "Done! ${#filenames[@]} files shown."
    [[ -n "$tmp_patch" ]] && rm -f "$tmp_patch"
    return 0
  fi

  # ----- Normal git diff mode -----

  # Get changed files (NUL-delimited for safety)
  local -a diff_flags=(--name-only -z)
  if [[ "$use_relative" -eq 1 ]]; then
    diff_flags+=(--relative)
  fi
  local -a filenames=()
  while IFS= read -r -d '' f; do
    filenames+=("$f")
  done < <(git diff "${diff_flags[@]}" "${revspec[@]}" 2>/dev/null || true)

  # When not using --relative, paths are repo-root-relative.
  # Resolve them to absolute paths so file-existence checks work from any cwd.
  if [[ "$use_relative" -eq 0 ]]; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -n "$repo_root" ]]; then
      local -a abs_filenames=()
      for f in "${filenames[@]}"; do
        abs_filenames+=("$repo_root/$f")
      done
      filenames=("${abs_filenames[@]}")
    fi
  fi

  if [[ "${#filenames[@]}" -eq 0 ]]; then
    echo "No changes found for: git diff ${revspec[*]:-}"
    echo "Try: gitdiffshow --cached"
    return 0
  fi

  local printfun=""
  if printfun="$(__gitdiffshow_find_printfunc)"; then
    :
  else
    printfun=""
  fi

  # Used by excerpt printer + print_function
  export GITDIFFSHOW_COLOR_MODE="$color_mode"

  echo "Showing ${#filenames[@]} changed file(s):"
  local f
  for f in "${filenames[@]}"; do
    echo "   $f"
  done
  echo "─────────────────────────────────────────────────"

  for f in "${filenames[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo
      echo "===== $f ====="
      echo "SKIPPED: $f (file not found - likely deleted)"
      continue
    fi

    echo
    echo "===== $f ====="
    echo

    if [[ "$show_diff" -eq 1 ]]; then
      echo "--- Git Diff ---"
      # Prevent git from invoking a pager (less) for long diffs
      if [[ "$color_mode" == "never" ]]; then
        env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" git --no-pager diff --no-color "${revspec[@]}" -- "$f"
      else
        env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" git --no-pager diff --color="$color_mode" "${revspec[@]}" -- "$f"
      fi
      echo
    fi

    if [[ "$print_wholefile" -eq 1 ]]; then
      if command -v batcat >/dev/null 2>&1; then
        env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" batcat --color="$color_mode" --paging=never --style=numbers "$f"
      elif command -v bat >/dev/null 2>&1; then
        env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" bat --color="$color_mode" --paging=never --style=numbers "$f"
      elif [[ "$color_mode" != "never" ]] && command -v pygmentize >/dev/null 2>&1; then
        pygmentize -g -f terminal256 -O "style=monokai,linenos=1" "$f" 2>/dev/null || \
        pygmentize -g -f terminal256 -O "linenos=1" "$f"
      else
        nl -ba -n ln "$f"
      fi
      continue
    fi

    local raw
    raw="$(__gitdiffshow_analyze_file "$f" "${revspec[@]}" || true)"

    local -a funcs=()
    local -a nonfunc=()
    local -a hunks=()
    local -a notes=()

    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r kind p2 p3 p4 <<<"$line" || true
      case "$kind" in
        NOTE)    notes+=("$p2") ;;
        FUNC)    funcs+=("${p2}|${p3}|${p4}") ;;
        NONFUNC) nonfunc+=("${p2}|${p3}|${p4}") ;;
        HUNK)    hunks+=("${p2}|${p3}|${p4}") ;;
      esac
    done <<<"$raw"

    local n
    for n in "${notes[@]}"; do
      echo "Notes:  $n"
    done
    if [[ "${#notes[@]}" -gt 0 ]]; then
      echo
    fi

    # Preferred: Python funcs + print_function present
    if [[ "$f" == *.py && -n "$printfun" && "${#funcs[@]}" -gt 0 ]]; then
      local rec qn s e
      for rec in "${funcs[@]}"; do
        IFS='|' read -r qn s e <<<"$rec"
        echo "--- function $qn (lines $s-$e) ---"
        # Also prevent any pager that print_function.sh / bat might try to use
        if [[ "$color_mode" == "never" ]]; then
           # Try hard to discourage color in child tools
           env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" env -u CLICOLOR_FORCE -u BAT_FORCE_COLOR -u PF_FORCE_COLOR NO_COLOR=1 TERM=dumb PF_COLOR_MODE=never "$printfun" --all "$f" "$qn"
        else
           env "${GITDIFFSHOW_NO_PAGER_ENV[@]}" PF_COLOR_MODE="$color_mode" PF_FORCE_COLOR=1 BAT_FORCE_COLOR=1 CLICOLOR_FORCE=1 TERM=${TERM:-xterm-256color} "$printfun" --all "$f" "$qn"
        fi
        echo
      done

      for rec in "${nonfunc[@]}"; do
        IFS='|' read -r s e label <<<"$rec"
        __gitdiffshow_print_excerpt "$f" "$s" "$e" "$label"
        echo
      done
      continue
    fi

    # Fallback: excerpts around hunks (works for any file)
    if [[ "${#hunks[@]}" -gt 0 ]]; then
      local rec s e label
      for rec in "${hunks[@]}"; do
        IFS='|' read -r s e label <<<"$rec"
        __gitdiffshow_print_excerpt "$f" "$s" "$e" "$label"
        echo
      done
    else
      if command -v batcat >/dev/null 2>&1; then
        batcat --color="$color_mode" --paging=never --style=numbers "$f"
      elif command -v bat >/dev/null 2>&1; then
        bat --color="$color_mode" --paging=never --style=numbers "$f"
      else
        nl -ba -n ln "$f"
      fi
    fi
  done

  echo "Done! ${#filenames[@]} files shown."
}

gitdiffshow "$@"
