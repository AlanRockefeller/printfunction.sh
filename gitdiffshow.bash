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
#   --color            Force ANSI color output
#   --no-color         Disable ANSI color (best for pasting into AI)
#
# TIP:
#   Tune excerpt size with:
#     export GITDIFFSHOW_CONTEXT=30
#
# Version 1.0.2 by Alan Rockefeller - January 27, 2026
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
  local color_mode="auto"
  local -a revspec=()

  local a
  for a in "$@"; do
    case "$a" in
      --printwholefile|--wholefile|--whole-file|--all)
        print_wholefile=1
        ;;
      --diff)
        show_diff=1
        ;;
      --color)
        color_mode="always"
        ;;
      --color=*)
        color_mode="${a#*=}"
        if [[ ! "$color_mode" =~ ^(always|never|auto)$ ]]; then
           echo "Error: Invalid color mode '$color_mode'. Use always, never, or auto." >&2
           exit 1
        fi
        ;;
      --no-color|--nocolor|-n)
        color_mode="never"
        ;;
      -h|--help)
        cat <<'EOF'
gitdiffshow - Show context for files changed in git diff

USAGE:
  gitdiffshow [--all|--printwholefile] [--diff] [--color[=MODE]|--no-color] [git-diff-revspec...]

DEFAULT:
  - Python files: print only affected functions/methods (via print_function.sh)
  - Other files: print numbered excerpts around changed hunks

FLAGS:
  --all              Print entire file contents with line numbers (alias)
  --printwholefile   Same as --all
  --diff             Print git diff output in addition to the function context
  --color[=MODE]     Color mode: always, auto, never (default: auto). Bare --color implies always.
  --no-color, -n     Disable ANSI color (best for pasting into AI)

EXAMPLES:
  gitdiffshow
  gitdiffshow --cached
  gitdiffshow HEAD
  gitdiffshow main..
  gitdiffshow --all
  gitdiffshow --diff --no-color

TIP: Tune excerpt size:
  export GITDIFFSHOW_CONTEXT=30
EOF
        return 0
        ;;
      *)
        revspec+=("$a")
        ;;
    esac
  done

  # Get changed files (NUL-delimited for safety)
  local -a filenames=()
  while IFS= read -r -d '' f; do
    filenames+=("$f")
  done < <(git diff --name-only -z --relative "${revspec[@]}" 2>/dev/null || true)

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
      # If analysis produced no hunks, still show something *colored*.
      if command -v batcat >/dev/null 2>&1; then
        batcat --color=always --paging=never --style=numbers "$f"
      elif command -v bat >/dev/null 2>&1; then
        bat --color=always --paging=never --style=numbers "$f"
      else
        nl -ba -n ln "$f"
      fi
    fi
  done

  echo "Done! ${#filenames[@]} files shown."
}

gitdiffshow "$@"
