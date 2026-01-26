#!/usr/bin/env fish
# ======================================================================
# gitdiffshow - Show context for files changed in git diff
# ======================================================================
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
#
# TIP:
#   Tune excerpt size with:
#     set -x GITDIFFSHOW_CONTEXT 30
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

    # Best: bat/batcat can show real file line numbers and syntax highlight directly.
    if type -q bat
        bat --color=always --paging=never --style=plain,numbers --line-range "$start_line:$end_line" "$file"
        return
    else if type -q batcat
        batcat --color=always --paging=never --style=plain,numbers --line-range "$start_line:$end_line" "$file"
        return
    end

    # Fallback: pygmentize (we slice the file then set linenostart so numbers match)
    if type -q pygmentize
        sed -n "$start_line,$end_line p" "$file" | pygmentize -g -f terminal256 -O "style=monokai,linenos=1,linenostart=$start_line" 2>/dev/null
        or sed -n "$start_line,$end_line p" "$file" | pygmentize -g -f terminal256 -O "linenos=1,linenostart=$start_line"
        return
    end

    # Last resort: plain numbered output
    sed -n "$start_line,$end_line p" "$file" | nl -ba -n ln -v $start_line
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

hunk_re = re.compile(r"^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@", re.M)

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
    set -l revspec

    for a in $argv
        switch $a
            case --printwholefile --wholefile --whole-file --all
                set print_wholefile 1
            case -h --help
                echo "gitdiffshow - Show context for files changed in git diff"
                echo ""
                echo "USAGE:"
                echo "  gitdiffshow [--all|--printwholefile] [git-diff-revspec...]"
                echo ""
                echo "DEFAULT:"
                echo "  - Python files: print only affected functions/methods (via print_function.sh)"
                echo "  - Other files: print numbered excerpts around changed hunks"
                echo ""
                echo "FLAGS:"
                echo "  --all              Print entire file contents with line numbers (alias)"
                echo "  --printwholefile   Same as --all"
                echo ""
                echo "EXAMPLES:"
                echo "  gitdiffshow"
                echo "  gitdiffshow --cached"
                echo "  gitdiffshow HEAD"
                echo "  gitdiffshow main.."
                echo "  gitdiffshow --all"
                echo ""
                echo "TIP: Tune excerpt size:"
                echo "  set -x GITDIFFSHOW_CONTEXT 30"
                return 0
            case '*'
                set revspec $revspec $a
        end
    end

    # Get changed files (NUL-delimited for safety)
    set -l filenames (git diff --name-only -z --relative $revspec 2>/dev/null | string split0)

    if test (count $filenames) -eq 0
        echo "No changes found for: git diff $revspec"
        echo "Try: gitdiffshow --cached"
        return 0
    end

    set -l printfun (__gitdiffshow_find_printfunc)

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

        if test $print_wholefile -eq 1
            if type -q bat
                bat --color=always --paging=never --style=plain,numbers "$f"
            else if type -q batcat
                batcat --color=always --paging=never --style=plain,numbers "$f"
            else if type -q pygmentize
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
                env PF_FORCE_COLOR=1 BAT_FORCE_COLOR=1 CLICOLOR_FORCE=1 $printfun --all "$f" "$qn"
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
