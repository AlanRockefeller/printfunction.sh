#!/usr/bin/env bash

# printfunction.sh version 1.1
# Alan Rockefeller - January 25, 2026

set -euo pipefail

# --- Help Section ---
if [ $# -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'HELP'
Usage:
  printfunction.sh [OPTIONS] FILENAME [FUNCTION_NAME]

Extract Python function/method definitions using AST parsing.
Auto-detects 'bat'/'batcat' or 'pygmentize' for syntax highlighting when stdout is a TTY.

Targeting:
  - FUNCTION_NAME can be:
      foo
      ClassName.method
      Outer.Inner.method
  - With --all, nested functions are also addressable:
      outer.inner

  lines START-END prints a line range (inclusive).

  ~START-END prints a "smart context" range (enclosing def/class for .py, else padded range).

Matching:
  - By default, this prints *all* matches in source order.
    If the function is defined twice, you will see both definitions.
  - Use --first to print only the first match.

Options:
  --all                 Include nested functions (descend into function bodies)
  --first               Print only the first match (in source order)

  --import              Print imports too (defaults to --import=all)
  --import=all           Print imports at module/class scope (not inside any function)
  --import=used          Print only imports that appear to be used by the extracted function(s)
                         (best-effort heuristic; may miss dynamic imports or over-include star imports)

  --list                List available functions/methods (use with --all to include nested)
  --regex PATTERN        Match by regex against fully-qualified names (overrides FUNCTION_NAME)

  -h, --help            Show this help message

Examples:
  # Print a top-level function (all matches named 'foo')
  ./printfunction.sh myfile.py foo

  # Print only the first match named 'foo'
  ./printfunction.sh --first myfile.py foo

  # Print exact lines 470-510 (any file type)
  ./printfunction.sh myfile.py lines 470-510
  ./printfunction.sh myfile.qml 470-510

  # Smart context around 470-510
  ./printfunction.sh myfile.py ~470-510
  ./printfunction.sh myfile.qml lines ~470-510

  # Print a method inside a class
  ./printfunction.sh myfile.py MyClass.process

  # Include nested functions and target a nested function by qualname
  ./printfunction.sh --all myfile.py outer.inner

  # Print function plus all module/class-scope imports
  ./printfunction.sh --import myfile.py foo

  # Print function plus only imports that appear used by that function
  ./printfunction.sh --import=used myfile.py foo

  # List everything available
  ./printfunction.sh --list myfile.py

  # Regex match (fully-qualified names)
  ./printfunction.sh --regex '(^|\\.)test_' myfile.py
  ./printfunction.sh --list --regex 'MyClass\\..*' myfile.py
HELP
    exit 0
fi

# --- Argument Parsing ---
INCLUDE_NESTED="false"
FIRST_ONLY="false"
LIST_MODE="false"
REGEX_PATTERN=""
IMPORT_MODE="none"   # none|all|used
POSITIONAL_ARGS=()

# Parse all arguments, allowing options anywhere
while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            INCLUDE_NESTED="true"
            shift
            ;;
        --first)
            FIRST_ONLY="true"
            shift
            ;;
        --list)
            LIST_MODE="true"
            shift
            ;;
        --regex)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --regex requires a PATTERN argument" >&2
                exit 2
            fi
            REGEX_PATTERN="$1"
            shift
            ;;
        --import|--imports)
            IMPORT_MODE="all"   # default
            shift
            ;;
        --import=all|--imports=all)
            IMPORT_MODE="all"
            shift
            ;;
        --import=used|--imports=used)
            IMPORT_MODE="used"
            shift
            ;;
        --import=none|--imports=none)
            IMPORT_MODE="none"
            shift
            ;;
        -h|--help)
            # handled above, but keep for completeness
            exec "$0" --help
            ;;
        --*)
            echo "Error: Unknown option: $1" >&2
            echo "Run with --help for usage information." >&2
            exit 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Now POSITIONAL_ARGS contains only non-option arguments
ARGS=("${POSITIONAL_ARGS[@]}")

if [ ${#ARGS[@]} -lt 1 ]; then
    echo "Error: Missing FILENAME" >&2
    echo "Run with --help for usage information." >&2
    exit 2
fi

FILENAME="${ARGS[0]}"
FUNC_NAME="${ARGS[1]:-}"  # optional if --list or --regex is used

# --- Line-range shorthand / mode ---
LINE_MODE="false"
LINE_SPEC=""

# Allow: printfunction.sh file lines 470-510
# Treat 'lines' as keyword only if followed by a range-like argument
if [ "${FUNC_NAME:-}" = "lines" ] && [ ${#ARGS[@]} -ge 3 ] && [[ "${ARGS[2]:-}" =~ ^~?[0-9]+[-–][0-9]+$ ]]; then
    LINE_MODE="true"
    LINE_SPEC="${ARGS[2]}"
    FUNC_NAME=""   # not used
else
    # Allow: printfunction.sh file 470-510  OR  ~470-510
    if [[ "${FUNC_NAME:-}" =~ ^~?[0-9]+[-–][0-9]+$ ]]; then
        LINE_MODE="true"
        LINE_SPEC="${FUNC_NAME}"
        FUNC_NAME=""
    fi
fi

# Validate that FILENAME doesn't look like an option (common mistake)
if [[ "$FILENAME" == --* ]]; then
    echo "Error: Expected FILENAME, got option: $FILENAME" >&2
    echo "Run with --help for usage information." >&2
    exit 2
fi

# If not listing and no regex and no function name and not line mode, that's an error.
if [ "$LIST_MODE" != "true" ] && [ -z "$REGEX_PATTERN" ] && [ -z "$FUNC_NAME" ] && [ "$LINE_MODE" != "true" ]; then
    echo "Error: Missing FUNCTION_NAME (or use --regex / --list)" >&2
    echo "Run with --help for usage information." >&2
    exit 2
fi

# --- Python Logic ---
extract_code() {
    python3 - \
        "$FILENAME" \
        "$FUNC_NAME" \
        "$INCLUDE_NESTED" \
        "$IMPORT_MODE" \
        "$LIST_MODE" \
        "$REGEX_PATTERN" \
        "$FIRST_ONLY" \
        "$LINE_MODE" \
        "$LINE_SPEC" <<'PY'
import ast
import difflib
import re
import sys
import tokenize
from dataclasses import dataclass
from typing import List, Set, Tuple, Optional

filename = sys.argv[1]
target = sys.argv[2]  # may be empty if using --regex/--list
include_nested = sys.argv[3] == "true"
import_mode = sys.argv[4]  # none|all|used
list_mode = sys.argv[5] == "true"
regex_pat = sys.argv[6] or None
first_only = sys.argv[7] == "true"
line_mode = sys.argv[8] == "true"
line_spec = sys.argv[9] or ""

def parse_line_spec(spec: str) -> Tuple[bool, int, int]:
    """
    Returns (smart, start, end). Accepts:
      470-510
      470–510  (en dash)
      ~470-510
      ~470–510
    """
    spec = spec.strip()
    smart = spec.startswith("~")
    if smart:
        spec = spec[1:].strip()
    spec = spec.replace("–", "-")
    m = re.fullmatch(r"(\d+)-(\d+)", spec)
    if not m:
        raise ValueError(f"Invalid line range: {spec!r} (expected START-END)")
    a = int(m.group(1))
    b = int(m.group(2))
    if a <= 0 or b <= 0:
        raise ValueError("Line numbers must be >= 1")
    start, end = (a, b) if a <= b else (b, a)
    return smart, start, end

def print_numbered_range(lines: List[str], start: int, end: int) -> None:
    start = max(1, start)
    end = min(len(lines), end)
    width = len(str(end))
    for ln in range(start, end + 1):
        s = lines[ln - 1].rstrip("\n")
        print(f"{ln:>{width}} | {s}")

def is_python_file(path: str) -> bool:
    return path.endswith(".py") or path.endswith(".pyw")

def contains_range(node: ast.AST, start: int, end: int) -> bool:
    if not hasattr(node, "lineno") or not hasattr(node, "end_lineno"):
        return False
    return int(node.lineno) <= start and int(node.end_lineno) >= end

def pick_best_enclosing(tree: ast.AST, start: int, end: int) -> Optional[ast.AST]:
    # Prefer functions, then classes; else fallback
    candidates: List[ast.AST] = []

    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if contains_range(n, start, end):
                candidates.append(n)

    if not candidates:
        return None

    # Smallest enclosing = minimal (end-start) span, tie-breaker: deepest (more specific)
    def key(n: ast.AST) -> Tuple[int, int, int]:
        span = int(n.end_lineno) - int(n.lineno)
        # function gets priority over class if same span
        pri = 0 if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) else 1
        return (span, pri, int(getattr(n, "lineno", 10**18)))

    return sorted(candidates, key=key)[0]

if import_mode not in ("none", "all", "used"):
    print(f"Internal error: invalid import mode '{import_mode}'", file=sys.stderr)
    raise SystemExit(2)

try:
    with tokenize.open(filename) as f:
        source = f.read()
except FileNotFoundError:
    print(f"Error: file not found: {filename}", file=sys.stderr)
    print("Tip: check the path, or run with --help for usage examples.", file=sys.stderr)
    raise SystemExit(2)
except Exception as e:
    print(f"Error reading {filename}: {e}", file=sys.stderr)
    raise SystemExit(2)

lines = source.splitlines(True)

if line_mode:
    try:
        smart, start, end = parse_line_spec(line_spec)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        raise SystemExit(2)

    # If not smart, just print exact range and exit
    if not smart:
        print_numbered_range(lines, start, end)
        raise SystemExit(0)

    # Smart mode:
    # - Python: try to print smallest enclosing def/class that contains the range
    # - Otherwise: print padded lines around the range
    if not is_python_file(filename):
        PAD = 25
        print_numbered_range(lines, start - PAD, end + PAD)
        raise SystemExit(0)

    # Python smart mode falls through to AST parse below

if not line_mode and not is_python_file(filename):
    print(f"Error: function extraction only supports .py/.pyw files (got {filename}).", file=sys.stderr)
    print(f"For other files, use: lines START-END or ~START-END", file=sys.stderr)
    raise SystemExit(2)

try:
    tree = ast.parse(source, filename=filename)
except SyntaxError as e:
    print(f"Error: syntax error while parsing {filename}:", file=sys.stderr)
    print(f"  {e}", file=sys.stderr)
    print("Tip: this tool requires the file to be valid Python syntax.", file=sys.stderr)
    raise SystemExit(2)
except Exception as e:
    print(f"Error parsing {filename}: {e}", file=sys.stderr)
    raise SystemExit(2)

def node_span(node: ast.AST) -> Tuple[int, int, int, int]:
    """(start_line, start_col, end_line, end_col) for sorting/dedup."""
    return (
        getattr(node, "lineno", 10**18),
        getattr(node, "col_offset", 0),
        getattr(node, "end_lineno", getattr(node, "lineno", 10**18)),
        getattr(node, "end_col_offset", 0),
    )

def get_full_code(node: ast.AST) -> str:
    """Extract exact source segment including decorators, defensively."""
    if not hasattr(node, "lineno") or not hasattr(node, "end_lineno"):
        seg = ast.get_source_segment(source, node)
        return seg if seg is not None else ""

    start_line = int(getattr(node, "lineno"))
    end_line = int(getattr(node, "end_lineno"))
    end_col = getattr(node, "end_col_offset", None)

    # Include decorators if present
    # Guard against decorators with missing/None lineno (can occur in synthetic AST nodes)
    decs = getattr(node, "decorator_list", None) or []
    dec_linenos = []
    for d in decs:
        ln = getattr(d, "lineno", None)
        if isinstance(ln, int) and ln > 0:
            dec_linenos.append(ln)
    if dec_linenos:
        start_line = min(start_line, min(dec_linenos))

    seg_lines = lines[start_line - 1 : end_line]
    if not seg_lines:
        return ""

    # Trim last line to end_col_offset to avoid capturing next statement.
    if isinstance(end_col, int) and end_col >= 0:
        seg_lines[-1] = seg_lines[-1][:end_col]

    return "".join(seg_lines)

if line_mode:
    # we already validated it above
    smart, start, end = parse_line_spec(line_spec)

    node = pick_best_enclosing(tree, start, end)
    if node is not None:
        print(get_full_code(node).rstrip("\n"))
        raise SystemExit(0)

    # Fallback if no enclosing node found
    PAD = 25
    print_numbered_range(lines, start - PAD, end + PAD)
    raise SystemExit(0)

@dataclass(frozen=True)
class FoundDef:
    qualname: str
    name: str
    lineno: int
    node: ast.AST

@dataclass(frozen=True)
class FoundImport:
    node: ast.AST

def provide_imported_names(node: ast.AST) -> Set[str]:
    """
    Return names bound by this import statement (best-effort).
    For 'import a.b', Python binds 'a'. For aliases, binds alias name.
    """
    out: Set[str] = set()
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.asname:
                out.add(alias.asname)
            else:
                # import pkg.mod -> binds 'pkg'
                root = alias.name.split(".", 1)[0]
                out.add(root)
    elif isinstance(node, ast.ImportFrom):
        for alias in node.names:
            if alias.name == "*":
                out.add("*")
            elif alias.asname:
                out.add(alias.asname)
            else:
                out.add(alias.name)
    return out

class UsedNameCollector(ast.NodeVisitor):
    def __init__(self) -> None:
        self.names: Set[str] = set()

    def _root_name(self, expr: ast.AST) -> None:
        """Extract and collect the root name from an expression chain."""
        while isinstance(expr, (ast.Attribute, ast.Subscript)):
            expr = expr.value
        if isinstance(expr, ast.Name):
            self.names.add(expr.id)

    def visit_Name(self, node: ast.Name) -> None:
        self.names.add(node.id)

    def visit_Attribute(self, node: ast.Attribute) -> None:
        # Capture the root name in chained attributes: pkg.mod.func -> "pkg"
        self._root_name(node.value)
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        # Capture root name in subscripts: mod["x"] -> "mod"
        self._root_name(node.value)
        self.generic_visit(node)

class Extractor(ast.NodeVisitor):
    def __init__(self, include_nested: bool, import_mode: str):
        self.include_nested = include_nested
        self.import_mode = import_mode

        self.class_stack: List[str] = []
        self.func_stack: List[str] = []
        self.function_depth = 0  # to avoid collecting imports inside functions

        self.defs: List[FoundDef] = []
        self.imports: List[FoundImport] = []

    def _qualname_for(self, func_name: str) -> str:
        parts = []
        parts.extend(self.class_stack)
        parts.extend(self.func_stack)
        parts.append(func_name)
        return ".".join(parts)

    # Imports: collect only at module/class scope (function_depth == 0)
    def visit_Import(self, node: ast.Import) -> None:
        if self.import_mode != "none" and self.function_depth == 0:
            self.imports.append(FoundImport(node=node))
        self.generic_visit(node)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if self.import_mode != "none" and self.function_depth == 0:
            self.imports.append(FoundImport(node=node))
        self.generic_visit(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.class_stack.append(node.name)
        try:
            self.generic_visit(node)
        finally:
            self.class_stack.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        qn = self._qualname_for(node.name)
        self.defs.append(FoundDef(qualname=qn, name=node.name, lineno=getattr(node, "lineno", 0), node=node))

        # Descend into function bodies only if include_nested
        if self.include_nested:
            self.func_stack.append(node.name)
            self.function_depth += 1
            try:
                self.generic_visit(node)
            finally:
                self.function_depth -= 1
                self.func_stack.pop()

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        qn = self._qualname_for(node.name)
        self.defs.append(FoundDef(qualname=qn, name=node.name, lineno=getattr(node, "lineno", 0), node=node))

        if self.include_nested:
            self.func_stack.append(node.name)
            self.function_depth += 1
            try:
                self.generic_visit(node)
            finally:
                self.function_depth -= 1
                self.func_stack.pop()

# Run extraction
ex = Extractor(include_nested=include_nested, import_mode=import_mode)
ex.visit(tree)

# Sort/dedup defs in stable source order
defs_sorted = sorted(ex.defs, key=lambda d: node_span(d.node))
deduped: List[FoundDef] = []
seen_spans = set()
for d in defs_sorted:
    sp = node_span(d.node)
    if sp in seen_spans:
        continue
    seen_spans.add(sp)
    deduped.append(d)

all_qualnames = [d.qualname for d in deduped]

def format_list(items: List[FoundDef]) -> str:
    out = []
    for d in items:
        out.append(f"{d.qualname}  (line {d.lineno})")
    return "\n".join(out)

# Regex handling
regex = None
if regex_pat is not None:
    try:
        regex = re.compile(regex_pat)
    except re.error as e:
        print(f"Error: invalid regex: {regex_pat}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        raise SystemExit(2)

def matches(defn: FoundDef) -> bool:
    if regex is not None:
        return bool(regex.search(defn.qualname))
    if target and "." in target:
        return defn.qualname == target
    if target:
        return defn.name == target
    return False

# --list mode
if list_mode:
    items = deduped
    if regex is not None:
        items = [d for d in items if matches(d)]
    if items:
        print(format_list(items))
        raise SystemExit(0)
    else:
        print("(no matches)", file=sys.stderr)
        raise SystemExit(1)

# Extraction mode: determine selected defs
selected = [d for d in deduped if matches(d)]

def friendly_not_found() -> None:
    print(f"Couldn't find a match in: {filename}", file=sys.stderr)
    if regex is not None:
        print(f"  Regex: {regex_pat!r}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Try:", file=sys.stderr)
        print(f"  ./print_function.sh --list --all --regex {regex_pat!r} {filename}", file=sys.stderr)
    else:
        print(f"  Target: {target!r}", file=sys.stderr)
        
        # Check if the target would be found with --all
        if not include_nested and target:
            # Re-run extraction with nested=True to see if we'd find it
            ex_nested = Extractor(include_nested=True, import_mode="none")
            ex_nested.visit(tree)
            defs_nested = sorted(ex_nested.defs, key=lambda d: node_span(d.node))
            deduped_nested: List[FoundDef] = []
            seen_nested = set()
            for d in defs_nested:
                sp = node_span(d.node)
                if sp in seen_nested:
                    continue
                seen_nested.add(sp)
                deduped_nested.append(d)
            
            # Check if target would match with --all
            matched_defs = []
            for d in deduped_nested:
                if (target and "." in target and d.qualname == target) or \
                   (target and "." not in target and d.name == target):
                    matched_defs.append(d)
            
            if matched_defs:
                print("", file=sys.stderr)
                print("*** FOUND IT! ***", file=sys.stderr)
                
                # Show all matches with their parent context
                for d in matched_defs:
                    parts = d.qualname.split(".")
                    if len(parts) > 1:
                        parent = ".".join(parts[:-1])
                        print(f"'{d.name}' is nested inside: {parent}", file=sys.stderr)
                    else:
                        print(f"'{d.name}' found at: {d.qualname}", file=sys.stderr)
                
                print("", file=sys.stderr)
                print(f"By default, this tool does not search functions defined inside other functions.", file=sys.stderr)
                print("Use --all to include nested functions.", file=sys.stderr)
                print("", file=sys.stderr)
                print("Run with --all to search nested functions:", file=sys.stderr)
                print(f"  ./print_function.sh --all {filename} {target}", file=sys.stderr)
                print("", file=sys.stderr)
                print("Or list all nested functions:", file=sys.stderr)
                print(f"  ./print_function.sh --list --all {filename}", file=sys.stderr)
                raise SystemExit(1)
        
        print("", file=sys.stderr)
        print("Tips:", file=sys.stderr)
        print(f"  • List available definitions:", file=sys.stderr)
        print(f"      ./print_function.sh --list {filename}", file=sys.stderr)
        print(f"      ./print_function.sh --list --all {filename}    # include nested", file=sys.stderr)
        if target and "." not in target:
            print(f"  • If you meant a method, try a qualified name like:", file=sys.stderr)
            print(f"      ./print_function.sh {filename} MyClass.{target}", file=sys.stderr)
        print(f"  • Use regex matching:", file=sys.stderr)
        escaped = re.escape(target) if target else "name"
        print(f'      ./print_function.sh --regex "(^|\\.){escaped}$" {filename}', file=sys.stderr)

    # Suggestions
    if all_qualnames:
        if regex is None and target:
            # Suggest close qualified names and also close bare names
            close = difflib.get_close_matches(target, all_qualnames, n=8, cutoff=0.5)
            if not close and "." not in target:
                bare = sorted({d.name for d in deduped})
                close_bare = difflib.get_close_matches(target, bare, n=8, cutoff=0.6)
                if close_bare:
                    print("", file=sys.stderr)
                    print("Did you mean one of these function names?", file=sys.stderr)
                    for c in close_bare:
                        print(f"  - {c}", file=sys.stderr)
            elif close:
                print("", file=sys.stderr)
                print("Closest matches (fully-qualified):", file=sys.stderr)
                for c in close:
                    print(f"  - {c}", file=sys.stderr)

        print("", file=sys.stderr)
        print("Hint: run with --list to see everything this tool can find.", file=sys.stderr)

    raise SystemExit(1)

if not selected:
    friendly_not_found()

# Show match count to stderr if outputting to TTY (before --first truncation)
total_matches = len(selected)
if total_matches > 1 and sys.stderr.isatty():
    preview_count = 3
    names = ", ".join(f"{d.qualname} (line {d.lineno})" for d in selected[:preview_count])
    if total_matches > preview_count:
        remaining = total_matches - preview_count
        names += f", ... ({remaining} more)"
    msg = f"Found {total_matches} definitions: {names}"
    if first_only:
        msg += " (printing first due to --first)"
    print(msg, file=sys.stderr)
    print("", file=sys.stderr)

# --first option
if first_only:
    selected = selected[:1]

# Imports
imports_out: List[FoundImport] = []
if import_mode != "none":
    imports_sorted = sorted(ex.imports, key=lambda imp: node_span(imp.node))

    if import_mode == "all":
        imports_out = imports_sorted
    else:
        # used mode: keep imports that provide any names used in the selected function(s)
        used_names: Set[str] = set()
        for d in selected:
            c = UsedNameCollector()
            c.visit(d.node)
            used_names |= c.names

        for imp in imports_sorted:
            provided = provide_imported_names(imp.node)
            if "*" in provided:
                # star-import: conservative; include
                imports_out.append(imp)
                continue
            if provided & used_names:
                imports_out.append(imp)

# Print imports (if any)
if imports_out:
    for imp in imports_out:
        print(get_full_code(imp.node).rstrip("\n"))
    print("\n" + "#" * 20 + "\n")

# Print selected function(s)
for i, d in enumerate(selected):
    print(get_full_code(d.node).rstrip("\n"))
    if i < len(selected) - 1:
        print()
PY
}

# --- Output Handling ---
# With `set -euo pipefail`, we need to capture the extractor's exit code
# without the pipeline causing an immediate exit.
run_with_optional_highlighting() {
    if [ -t 1 ]; then
        local -a highlighter=(cat)
        if command -v bat >/dev/null 2>&1; then
            if [ "$LINE_MODE" = "true" ]; then
                highlighter=(bat --color=always --style=plain --paging=never --file-name "$FILENAME")
            else
                highlighter=(bat --color=always --language=python --style=plain --paging=never)
            fi
        elif command -v batcat >/dev/null 2>&1; then
            if [ "$LINE_MODE" = "true" ]; then
                highlighter=(batcat --color=always --style=plain --paging=never --file-name "$FILENAME")
            else
                highlighter=(batcat --color=always --language=python --style=plain --paging=never)
            fi
        elif command -v pygmentize >/dev/null 2>&1; then
            if [ "$LINE_MODE" = "true" ]; then
                highlighter=(pygmentize -g)
            else
                highlighter=(pygmentize -l python)
            fi
        fi

        set +e
        extract_code | "${highlighter[@]}"
        local -a statuses=("${PIPESTATUS[@]}")
        set -e
        if [ "${statuses[0]}" -ne 0 ]; then
            return "${statuses[0]}"
        fi
        if [ "${statuses[1]}" -ne 0 ]; then
            return "${statuses[1]}"
        fi
        return 0
    else
        extract_code
    fi
}

run_with_optional_highlighting
exit $?
