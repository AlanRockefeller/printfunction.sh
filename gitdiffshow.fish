#!/usr/bin/env fish
# ======================================================================
# gitdiffshow - Show context for files changed in git diff
# ======================================================================

# ----------------------------------------------------------------------
# Force NO PAGERS anywhere (important for copy/paste into AI).
# Git and bat commonly page with `less` depending on user config.
# ----------------------------------------------------------------------
set -l __GITDIFFSHOW_NO_PAGER_ENV \
    PAGER=cat \
    GIT_PAGER=cat \
    BAT_PAGER=cat \
    BAT_PAGING=never \
    LESS=FRX

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
#
# TIP:
#   Tune excerpt size with:
#     set -x GITDIFFSHOW_CONTEXT 30
#
# Version 1.1.0 by Alan Rockefeller - March 17, 2026
#
# ======================================================================

function __gitdiffshow_find_printfunc
    set -l candidates print_function.sh printfunction.sh print_function printfunction
    for c in $candidates
        if type -q $c
            echo $c
            return 0
        end
    end
    return 1
end

function __gitdiffshow_print_excerpt --argument-names file start_line end_line label
    if test -z "$start_line" -o -z "$end_line"
        return
    end
    echo "--- $label (lines $start_line-$end_line) ---"

    # Color control: GITDIFFSHOW_COLOR_MODE is "always|auto|never"
    set -l _color (set -q GITDIFFSHOW_COLOR_MODE; and echo $GITDIFFSHOW_COLOR_MODE; or echo auto)

    # Best: bat/batcat can show real file line numbers and syntax highlight directly.
    if type -q bat
        bat --color=$_color --paging=never --style=plain,numbers --line-range "$start_line:$end_line" "$file"
        return
    else if type -q batcat
        batcat --color=$_color --paging=never --style=plain,numbers --line-range "$start_line:$end_line" "$file"
        return
    end

    # Fallback: pygmentize (we slice the file then set linenostart so numbers match)
    if test "$_color" != "never"; and type -q pygmentize
        sed -n "$start_line,$end_line p" "$file" | pygmentize -g -f terminal256 -O "style=monokai,linenos=1,linenostart=$start_line" 2>/dev/null
        or sed -n "$start_line,$end_line p" "$file" | pygmentize -g -f terminal256 -O "linenos=1,linenostart=$start_line"
        return
    end

    # Last resort: plain numbered output
    sed -n "$start_line,$end_line p" "$file" | nl -ba -n ln -v $start_line
end

# __gitdiffshow_patch_helper: Unified Python-based patch parser.
# Usage: __gitdiffshow_patch_helper <command> <patch_file> [args...]
# Commands: list-files (INDEX|STATUS|OLD_PATH|NEW_PATH),
#           analyze <file_path> [local_path] [entry_index],
#           raw-diff <file_path> [entry_index]
function __gitdiffshow_patch_helper
    set -l pycode '
import ast
import os
import re
import sys
import tokenize
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

@dataclass
class PatchFile:
    status: str
    old_path: str
    new_path: str
    header: str
    raw_text: str

def parse_patch(patch_text: str) -> List[PatchFile]:
    file_re = re.compile(r"^diff --git ", re.M)
    splits = file_re.split(patch_text)
    results: List[PatchFile] = []
    for section in splits[1:]:
        full_section = "diff --git " + section
        header_line = full_section.split("\n", 1)[0]
        hdr_match = re.match(r"diff --git a/(.*?) b/(.*)", header_line)
        if not hdr_match:
            continue
        raw_old = hdr_match.group(1)
        raw_new = hdr_match.group(2)
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
        minus_match = re.search(r"^--- (?:a/(.+)|/dev/null)", full_section, re.M)
        plus_match = re.search(r"^\+\+\+ (?:b/(.+)|/dev/null)", full_section, re.M)
        if minus_match and minus_match.group(1) is None and status != "added":
            status = "added"
            old_path = ""
        if plus_match and plus_match.group(1) is None and status != "deleted":
            status = "deleted"
            new_path = ""
        results.append(PatchFile(
            status=status, old_path=old_path, new_path=new_path,
            header=header_line, raw_text=full_section,
        ))
    return results

def find_patch_for_path(entries: List[PatchFile], target_path: str) -> Optional[PatchFile]:
    for e in entries:
        display_path = e.new_path if e.status != "deleted" else e.old_path
        if display_path == target_path:
            return e
    return None

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
        if n < 1: return 1
        if n > nlines: return nlines
        return n
    changed_lines = [clamp_line(x) for x in changed_lines]
    for s, e, label in ranges_around(changed_lines, "diff context", nlines):
        print(f"HUNK|{s}|{e}|{label}")
    if not path.endswith(".py"):
        return

    @dataclass(frozen=True)
    class DefSpan:
        qualname: str
        start: int
        end: int
        kind: str

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
            try: self.generic_visit(node)
            finally: self.class_stack.pop()
        def _visit_func(self, node: ast.AST, name: str) -> None:
            qn = self._qn(name)
            start = span_start_with_decorators(node)
            end = int(getattr(node, "end_lineno", getattr(node, "lineno", start)))
            funcs.append(DefSpan(qn, start, end, "func"))
            self.func_stack.append(name)
            try: self.generic_visit(node)
            finally: self.func_stack.pop()
        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            self._visit_func(node, node.name)
        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            self._visit_func(node, node.name)

    Extract().visit(tree)

    def innermost(spans: List[DefSpan], ln: int) -> Optional[DefSpan]:
        cands = [s for s in spans if s.start <= ln <= s.end]
        if not cands: return None
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

command = sys.argv[1]
patch_file = sys.argv[2]
with open(patch_file, "r") as f:
    patch_text = f.read()
entries = parse_patch(patch_text)

def resolve_entry(entries, target_path, index_arg=None):
    if index_arg is not None:
        try:
            idx = int(index_arg)
            if 0 <= idx < len(entries):
                return entries[idx]
        except ValueError:
            pass
    return find_patch_for_path(entries, target_path)

if command == "list-files":
    for i, e in enumerate(entries):
        print(f"{i}|{e.status}|{e.old_path}|{e.new_path}")
elif command == "analyze":
    target_path = sys.argv[3]
    local_path = sys.argv[4] if len(sys.argv) > 4 else target_path
    entry_index = sys.argv[5] if len(sys.argv) > 5 else None
    entry = resolve_entry(entries, target_path, entry_index)
    if entry is None:
        print("NOTE|File not found in patch")
        sys.exit(0)
    analyze_file_with_patch_text(local_path, entry.raw_text)
elif command == "raw-diff":
    target_path = sys.argv[3]
    entry_index = sys.argv[4] if len(sys.argv) > 4 else None
    entry = resolve_entry(entries, target_path, entry_index)
    if entry:
        print(entry.raw_text, end="")
else:
    print(f"Unknown command: {command}", file=sys.stderr)
    sys.exit(2)
'
    # Suppress noisy stderr unless debug mode
    if set -q GITDIFFSHOW_DEBUG
        printf "%s" "$pycode" | python3 - $argv
    else
        printf "%s" "$pycode" | python3 - $argv 2>/dev/null
    end
end

function __gitdiffshow_analyze_file --argument-names file
    # Remaining args are passed through to `git diff`
    set -l args $argv[2..-1]

    # Fish does NOT support bash heredocs reliably; pipe code into python instead.
    set -l pycode '
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
'

    # Suppress noisy stderr (e.g. conda entry-point chatter) so output stays parseable.
    printf "%s" "$pycode" | python3 - "$file" $args 2>/dev/null
end

function gitdiffshow
    set -l print_wholefile 0
    set -l show_diff 0
    set -l use_relative 0
    set -l color_mode auto
    set -l patch_file ""
    set -l revspec

    # Index-based arg parsing to handle --patch consuming next arg
    set -l i 1
    while test $i -le (count $argv)
        set -l a $argv[$i]
        switch $a
            case --patch
                set -l next (math $i + 1)
                if test $next -gt (count $argv)
                    echo "Error: --patch requires a FILE argument (use - for stdin)" >&2
                    return 1
                end
                set patch_file $argv[$next]
                set i (math $i + 2)
            case '--patch=*'
                set patch_file (string split -m1 = -- $a)[2]
                set i (math $i + 1)
            case --printwholefile --wholefile --whole-file --all
                set print_wholefile 1
                set i (math $i + 1)
            case --diff
                set show_diff 1
                set i (math $i + 1)
            case --relative
                set use_relative 1
                set i (math $i + 1)
            case --color
                set color_mode always
                set i (math $i + 1)
            case '--color=*'
                set -l val (string split -m1 = -- $a)[2]
                if not contains -- $val always never auto
                    echo "Error: Invalid color mode '$val'. Use always, never, or auto." >&2
                    return 1
                end
                set color_mode $val
                set i (math $i + 1)
            case --no-color --nocolor -n
                set color_mode never
                set i (math $i + 1)
            case -h --help
                echo "gitdiffshow - Show context for files changed in git diff"
                echo ""
                echo "USAGE:"
                echo "  gitdiffshow [OPTIONS] [git-diff-revspec...]"
                echo "  gitdiffshow --patch FILE [OPTIONS]"
                echo ""
                echo "DEFAULT:"
                echo "  - Shows all changed files in the repository (regardless of current directory)"
                echo "  - Python files: print only affected functions/methods (via print_function.sh)"
                echo "  - Other files: print numbered excerpts around changed hunks"
                echo ""
                echo "FLAGS:"
                echo "  --all              Print entire file contents with line numbers (alias)"
                echo "  --printwholefile   Same as --all"
                echo "  --diff             Print git diff output in addition to the function context"
                echo "  --patch FILE       Read diff from a patch file instead of running git diff."
                echo "                     Use - for stdin. Patch paths are resolved against the git"
                echo "                     repo root (if in a repo) or the current directory."
                echo "                     Cannot be combined with git diff revision arguments."
                echo "  --relative         Only show files relative to the current directory"
                echo "  --color[=MODE]     Color mode: always, auto, never (default: auto). Bare --color implies always."
                echo "  --no-color, -n     Disable ANSI color (best for pasting into AI)"
                echo ""
                echo "EXAMPLES:"
                echo "  gitdiffshow"
                echo "  gitdiffshow --cached"
                echo "  gitdiffshow HEAD"
                echo "  gitdiffshow main.."
                echo "  gitdiffshow --all"
                echo "  gitdiffshow --relative"
                echo "  gitdiffshow --diff --no-color"
                echo ""
                echo "  # Review a GitHub PR patch file:"
                echo "  gitdiffshow --patch pr-123.patch"
                echo "  gitdiffshow --patch pr-123.patch --diff"
                echo "  curl -L https://github.com/OWNER/REPO/pull/123.patch | gitdiffshow --patch -"
                echo ""
                echo "TIP: Tune excerpt size:"
                echo "  set -x GITDIFFSHOW_CONTEXT 30"
                return 0
            case '*'
                set revspec $revspec $a
                set i (math $i + 1)
        end
    end

    # Mutual exclusion: --patch cannot be combined with revspecs
    if test -n "$patch_file"; and test (count $revspec) -gt 0
        echo "Error: --patch cannot be combined with git diff revision arguments" >&2
        return 1
    end

    # ----- Patch file mode -----
    if test -n "$patch_file"
        # If reading from stdin, capture to a temp file
        set -l tmp_patch ""
        if test "$patch_file" = "-"
            set tmp_patch (mktemp)
            cat > $tmp_patch
            set patch_file $tmp_patch
        else if not test -f "$patch_file"
            echo "Error: Patch file not found: $patch_file" >&2
            return 1
        end

        # Determine base directory for resolving patch paths
        set -l base_dir (git rev-parse --show-toplevel 2>/dev/null; or echo $PWD)

        # Get file list from patch
        set -l raw_list (__gitdiffshow_patch_helper list-files "$patch_file" | string collect)

        set -l filenames
        set -l patch_paths
        set -l display_labels
        set -l entry_indices  # original patch entry index (for repeated paths)

        # Pre-compute real paths for --relative filtering (done once, not per-file)
        set -l real_cwd ""
        set -l real_base ""
        if test $use_relative -eq 1
            set real_cwd (cd $PWD; and pwd -P)
            set real_base (cd $base_dir; and pwd -P)
        end

        for line in (string split \n -- $raw_list)
            if test -z "$line"
                continue
            end
            set -l parts (string split '|' -- $line)
            set -l orig_idx $parts[1]
            set -l file_status $parts[2]
            set -l old_path $parts[3]
            set -l new_path $parts[4]

            set -l display_path ""
            set -l patch_path ""
            switch $file_status
                case modified added copied
                    set display_path $new_path
                    set patch_path $new_path
                case deleted
                    set display_path $old_path
                    set patch_path $old_path
                case renamed
                    set display_path $new_path
                    set patch_path $new_path
            end

            if test -z "$display_path"
                continue
            end

            set -l abs_path "$base_dir/$display_path"

            # --relative: filter to files under CWD (lexical prefix check).
            # We check the parent directory exists so deleted files in valid dirs
            # are kept, but paths in completely absent trees are filtered out.
            if test $use_relative -eq 1
                set -l real_abs "$real_base/$display_path"
                if not string match -q "$real_cwd/*" -- "$real_abs"
                    continue
                end
                if not test -d (dirname "$real_abs")
                    continue
                end
                set display_path (string replace "$real_cwd/" "" -- $real_abs)
                set abs_path $real_abs
            end

            set filenames $filenames $abs_path
            set patch_paths $patch_paths $patch_path
            set entry_indices $entry_indices $orig_idx

            set -l label $display_path
            switch $file_status
                case added
                    set label "$display_path (new file)"
                case deleted
                    set label "$display_path (deleted)"
                case renamed
                    set label "$new_path (renamed from $old_path)"
                case copied
                    set label "$new_path (copied from $old_path)"
            end
            set display_labels $display_labels $label
        end

        if test (count $filenames) -eq 0
            echo "No files found in patch: $patch_file"
            test -n "$tmp_patch"; and rm -f $tmp_patch
            return 0
        end

        set -l printfun (__gitdiffshow_find_printfunc)

        set -gx GITDIFFSHOW_COLOR_MODE $color_mode

        echo "Showing "(count $filenames)" changed file(s) from patch:"
        for dl in $display_labels
            echo "   $dl"
        end
        echo "─────────────────────────────────────────────────"

        for idx in (seq (count $filenames))
            set -l f $filenames[$idx]
            set -l pp $patch_paths[$idx]
            set -l dl $display_labels[$idx]
            set -l entry_idx $entry_indices[$idx]

            if not test -f "$f"
                echo
                echo "===== $dl ====="
                echo
                echo "  (file not in working tree — showing patch diff)"
                echo
                __gitdiffshow_patch_helper raw-diff "$patch_file" "$pp" "$entry_idx"
                echo
                continue
            end

            echo
            echo "===== $dl ====="
            echo

            if test $show_diff -eq 1
                echo "--- Patch Diff ---"
                __gitdiffshow_patch_helper raw-diff "$patch_file" "$pp" "$entry_idx"
                echo
            end

            if test $print_wholefile -eq 1
                if type -q bat
                    bat --color=$color_mode --paging=never --style=plain,numbers "$f"
                else if type -q batcat
                    batcat --color=$color_mode --paging=never --style=plain,numbers "$f"
                else if type -q pygmentize; and test "$color_mode" != "never"
                    pygmentize -g -f terminal256 -O "style=monokai,linenos=1" "$f" 2>/dev/null
                    or pygmentize -g -f terminal256 -O "linenos=1" "$f"
                else
                    nl -ba -n ln "$f"
                end
                continue
            end

            set -l raw (__gitdiffshow_patch_helper analyze "$patch_file" "$pp" "$f" "$entry_idx" | string collect)
            set -l lines (string split \n -- $raw)

            set -l funcs
            set -l nonfunc
            set -l hunks
            set -l notes

            for line in $lines
                if test -z "$line"
                    continue
                end
                set -l parts (string split '|' -- $line)
                switch $parts[1]
                    case NOTE
                        set notes $notes $parts[2]
                    case FUNC
                        set funcs $funcs "$parts[2]|$parts[3]|$parts[4]"
                    case NONFUNC
                        set nonfunc $nonfunc "$parts[2]|$parts[3]|$parts[4]"
                    case HUNK
                        set hunks $hunks "$parts[2]|$parts[3]|$parts[4]"
                end
            end

            for n in $notes
                echo "Notes:  $n"
            end
            if test (count $notes) -gt 0
                echo
            end

            # Preferred: Python funcs + print_function present
            if string match -q "*.py" -- "$f"; and test -n "$printfun"; and test (count $funcs) -gt 0
                for rec in $funcs
                    set -l p (string split '|' -- $rec)
                    set -l qn $p[1]
                    set -l s $p[2]
                    set -l e $p[3]
                    echo "--- function $qn (lines $s-$e) ---"
                    if test "$color_mode" = "never"
                        env $__GITDIFFSHOW_NO_PAGER_ENV NO_COLOR=1 TERM=dumb PF_COLOR_MODE=never $printfun --all "$f" "$qn"
                    else
                        env $__GITDIFFSHOW_NO_PAGER_ENV PF_COLOR_MODE=$color_mode PF_FORCE_COLOR=1 BAT_FORCE_COLOR=1 CLICOLOR_FORCE=1 $printfun --all "$f" "$qn"
                    end
                    echo
                end

                for rec in $nonfunc
                    set -l p (string split '|' -- $rec)
                    __gitdiffshow_print_excerpt "$f" $p[1] $p[2] $p[3]
                    echo
                end
                continue
            end

            # Fallback: excerpts around hunks (works for any file)
            if test (count $hunks) -gt 0
                for rec in $hunks
                    set -l p (string split '|' -- $rec)
                    __gitdiffshow_print_excerpt "$f" $p[1] $p[2] $p[3]
                    echo
                end
            else
                nl -ba -n ln "$f"
            end
        end

        echo "Done! "(count $filenames)" files shown."
        test -n "$tmp_patch"; and rm -f $tmp_patch
        return 0
    end

    # ----- Normal git diff mode -----

    # Get changed files (NUL-delimited for safety)
    set -l diff_flags --name-only -z
    if test $use_relative -eq 1
        set diff_flags $diff_flags --relative
    end
    set -l filenames (git diff $diff_flags $revspec 2>/dev/null | string split0)

    # When not using --relative, paths are repo-root-relative.
    # Resolve them to absolute paths so file-existence checks work from any cwd.
    if test $use_relative -eq 0
        set -l repo_root (git rev-parse --show-toplevel 2>/dev/null)
        if test -n "$repo_root"
            set -l abs_filenames
            for f in $filenames
                set abs_filenames $abs_filenames "$repo_root/$f"
            end
            set filenames $abs_filenames
        end
    end

    if test (count $filenames) -eq 0
        echo "No changes found for: git diff $revspec"
        echo "Try: gitdiffshow --cached"
        return 0
    end

    set -l printfun (__gitdiffshow_find_printfunc)

    # Used by excerpt printer + print_function
    set -gx GITDIFFSHOW_COLOR_MODE $color_mode

    echo "Showing "(count $filenames)" changed file(s):"
    for f in $filenames
        echo "   $f"
    end
    echo "─────────────────────────────────────────────────"

    for f in $filenames
        if not test -f "$f"
            echo
            echo "===== $f ====="
            echo "SKIPPED: $f (file not found - likely deleted)"
            continue
        end

        echo
        echo "===== $f ====="
        echo

        if test $show_diff -eq 1
            echo "--- Git Diff ---"
            # Prevent git from invoking a pager (less) for long diffs
            if test "$color_mode" = "never"
                env $__GITDIFFSHOW_NO_PAGER_ENV git --no-pager diff --no-color $revspec -- "$f"
            else
                env $__GITDIFFSHOW_NO_PAGER_ENV git --no-pager diff --color=$color_mode $revspec -- "$f"
            end
            echo
        end

        if test $print_wholefile -eq 1
            if type -q bat
                bat --color=$color_mode --paging=never --style=plain,numbers "$f"
            else if type -q batcat
                batcat --color=$color_mode --paging=never --style=plain,numbers "$f"
            else if type -q pygmentize; and test "$color_mode" != "never"
                pygmentize -g -f terminal256 -O "style=monokai,linenos=1" "$f" 2>/dev/null
                or pygmentize -g -f terminal256 -O "linenos=1" "$f"
            else
                nl -ba -n ln "$f"
            end
            continue
        end

        set -l raw (__gitdiffshow_analyze_file "$f" $revspec | string collect)
        set -l lines (string split \n -- $raw)

        set -l funcs
        set -l nonfunc
        set -l hunks
        set -l notes

        for line in $lines
            if test -z "$line"
                continue
            end
            set -l parts (string split '|' -- $line)
            switch $parts[1]
                case NOTE
                    set notes $notes $parts[2]
                case FUNC
                    set funcs $funcs "$parts[2]|$parts[3]|$parts[4]"
                case NONFUNC
                    set nonfunc $nonfunc "$parts[2]|$parts[3]|$parts[4]"
                case HUNK
                    set hunks $hunks "$parts[2]|$parts[3]|$parts[4]"
            end
        end

        for n in $notes
            echo "Notes:  $n"
        end
        if test (count $notes) -gt 0
            echo
        end

        # Preferred: Python funcs + print_function present
        if string match -q "*.py" -- "$f"; and test -n "$printfun"; and test (count $funcs) -gt 0
            for rec in $funcs
                set -l p (string split '|' -- $rec)
                set -l qn $p[1]
                set -l s $p[2]
                set -l e $p[3]
                echo "--- function $qn (lines $s-$e) ---"
                # Also prevent any pager that print_function.sh / bat might try to use
                if test "$color_mode" = "never"
                    # Try hard to discourage color in child tools
                    env $__GITDIFFSHOW_NO_PAGER_ENV NO_COLOR=1 TERM=dumb PF_COLOR_MODE=never $printfun --all "$f" "$qn"
                else
                    env $__GITDIFFSHOW_NO_PAGER_ENV PF_COLOR_MODE=$color_mode PF_FORCE_COLOR=1 BAT_FORCE_COLOR=1 CLICOLOR_FORCE=1 $printfun --all "$f" "$qn"
                end
                echo
            end

            for rec in $nonfunc
                set -l p (string split '|' -- $rec)
                __gitdiffshow_print_excerpt "$f" $p[1] $p[2] $p[3]
                echo
            end

            continue
        end

        # Fallback: excerpts around hunks (works for any file)
        if test (count $hunks) -gt 0
            for rec in $hunks
                set -l p (string split '|' -- $rec)
                __gitdiffshow_print_excerpt "$f" $p[1] $p[2] $p[3]
                echo
            end
        else
            nl -ba -n ln "$f"
        end
    end

    echo "Done! "(count $filenames)" files shown."
end

gitdiffshow $argv
