#!/usr/bin/env bash

# printfunction.sh version 1.3.3
# Alan Rockefeller - January 27, 2026

set -euo pipefail

# --- Help Section ---
if [ $# -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'HELP'
Usage:
  printfunction.sh [OPTIONS] [QUERY] [FILES...]

Extract Python function/method definitions using AST parsing.
Supports multi-file searching, directory recursion, and globs.

Targeting:
  - QUERY can be:
      foo                (Function name)
      ClassName.method   (Method name)
      lines START-END    (Line range)
      ~START-END         (Smart context range)
      file.py:100-200    (File with line range - paste from Claude Code output)
      file.py:~100-200   (File with smart context range)
  - If --regex is used, the pattern is provided via the option, so no QUERY argument is needed.

Matching:
  - By default, this prints *all* matches in source order.
  - Use --first to print only the first match (per file).

Options:
  --all                 Include nested functions (descend into function bodies)
  --first               Print only the first match per file
  --type TYPE           Filter file extensions (default: py).
                        TYPE can be: 'py' (default), 'all' (no filter).

  --import              Print imports too (defaults to --import=all)
  --import=all          Print imports at module/class scope
  --import=used         Print only imports that appear to be used by the extracted function(s)

  --context N           Add N lines of context around line-mode matches (default: 0).

  --list                List available functions/methods (use with --all to include nested).
                        If QUERY is provided, filters list by name/qualname.
                        If you provide only files/roots, printfunction lists available definitions (same as --list).

  --regex PATTERN       Match by regex against fully-qualified names

  --at PATTERN          Find the first line matching regex PATTERN and extract the surrounding
                        function/class (Python) or a padded snippet (other files).
                        Replaces QUERY. Cannot be combined with QUERY, lines START-END / ~START-END,
                        --regex, or --list.

  -h, --help            Show this help message

Examples:
  # Search for 'foo' in specific files
  ./printfunction.sh foo a.py b.py

  # Recursive search in current directory
  ./printfunction.sh foo .

  # Search using globs (quoted to prevent shell expansion, or unquoted)
  ./printfunction.sh foo "**/*.py"

  # Line extraction (header per file)
  ./printfunction.sh lines 10-20 file1.py file2.py

  # Smart context extraction
  ./printfunction.sh ~10-20 file1.py

  # Extract lines from file (paste from Claude Code output)
  ./printfunction.sh app.py:3343-3414

  # Find function containing 'cached_preview'
  ./printfunction.sh --at 'cached_preview' faststack/app.py

HELP
    exit 0
fi

# --- Argument Parsing ---
INCLUDE_NESTED="false"
FIRST_ONLY="false"
LIST_MODE="false"
REGEX_PATTERN=""
AT_PATTERN=""
IMPORT_MODE="none"
TYPE_FILTER="py"
CONTEXT_LINES=0
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --all) INCLUDE_NESTED="true"; shift ;;
        --first) FIRST_ONLY="true"; shift ;;
        --list) LIST_MODE="true"; shift ;;
        --regex) 
            shift
            if [ $# -eq 0 ]; then echo "Error: --regex requires a PATTERN" >&2; exit 2; fi
            REGEX_PATTERN="$1"; shift ;;
        --at) 
            shift
            if [ $# -eq 0 ]; then echo "Error: --at requires a PATTERN" >&2; exit 2; fi
            AT_PATTERN="$1"; shift ;;
        --import|--imports) IMPORT_MODE="all"; shift ;;
        --import=all|--imports=all) IMPORT_MODE="all"; shift ;;
        --import=used|--imports=used) IMPORT_MODE="used"; shift ;;
        --import=none|--imports=none) IMPORT_MODE="none"; shift ;;
        --type) 
            shift
            if [ $# -eq 0 ]; then echo "Error: --type requires an argument" >&2; exit 2; fi
            TYPE_FILTER="$1"; shift ;;
        --context)
            shift
            if [ $# -eq 0 ]; then echo "Error: --context requires an argument" >&2; exit 2; fi
            CONTEXT_LINES="$1"
            if ! [[ "$CONTEXT_LINES" =~ ^[0-9]+$ ]]; then echo "Error: --context requires an integer" >&2; exit 2; fi
            if [ "$CONTEXT_LINES" -gt 5000 ]; then CONTEXT_LINES=5000; fi
            shift ;;
        -h|--help) exec "$0" --help ;;
        --*) echo "Error: Unknown option: $1" >&2; exit 2 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

# --- Query vs Roots Separation ---
QUERY=""
SEARCH_ROOTS=()
LINE_MODE="false"
LINE_SPEC=""

# 1. Check for explicit 'lines' keyword
FOUND_LINES="false"
for ((i=0; i<${#POSITIONAL_ARGS[@]}; i++)); do
    arg="${POSITIONAL_ARGS[$i]}"
    if [ "$arg" = "lines" ]; then
        next_idx=$((i+1))
        if [ $next_idx -lt ${#POSITIONAL_ARGS[@]} ]; then
             next_arg="${POSITIONAL_ARGS[$next_idx]}"
             if [[ "$next_arg" =~ ^~?[0-9]+[-–][0-9]+$ ]]; then
                 LINE_MODE="true"
                 LINE_SPEC="$next_arg"
                 FOUND_LINES="true"
                 # Mark indices to skip
                 SKIP_INDICES=("$i" "$next_idx")
                 break
             fi
        fi
    fi
done

# 2. Separate Args
for ((i=0; i<${#POSITIONAL_ARGS[@]}; i++)); do
    # Skip arguments consumed by 'lines' check
    if [ "$FOUND_LINES" = "true" ]; then
        for skip in "${SKIP_INDICES[@]}"; do
            if [ "$i" -eq "$skip" ]; then continue 2; fi
        done
    fi

    arg="${POSITIONAL_ARGS[$i]}"

    # Check for file:range syntax (e.g., app.py:100-200 or app.py:~100-200)
    if [[ "$arg" =~ ^(.+):(~?[0-9]+[-–][0-9]+)$ ]]; then
        filename="${BASH_REMATCH[1]}"
        range="${BASH_REMATCH[2]}"
        if [ ! -e "$filename" ]; then
            echo "Error: file not found in 'file:range' syntax: $filename" >&2
            exit 2
        fi
        if [ "$LINE_MODE" = "true" ]; then
            echo "Error: multiple line ranges specified" >&2
            exit 2
        fi
        LINE_MODE="true"
        LINE_SPEC="$range"
        SEARCH_ROOTS+=("$filename")
        continue
    fi

    # Check for direct file/dir existence
    if [ -e "$arg" ]; then
        SEARCH_ROOTS+=("$arg")
        continue
    fi

    # Check for smart line range (if not already found and no query set)
    # Only treat bare range as line mode if we don't have a query yet (and not regex/list mode)
    HAS_QUERY_OR_MODE="false"
    if [ -n "$REGEX_PATTERN" ] || [ -n "$AT_PATTERN" ] || [ "$LIST_MODE" = "true" ] || [ -n "$QUERY" ] || [ "$LINE_MODE" = "true" ]; then
        HAS_QUERY_OR_MODE="true"
    fi

    if [ "$HAS_QUERY_OR_MODE" = "false" ] && [[ "$arg" =~ ^~?[0-9]+[-–][0-9]+$ ]]; then
        LINE_MODE="true"
        LINE_SPEC="$arg"
        continue
    fi

    # Check if we already have a query (via regex, list mode, or previously found func name)
    if [ "$HAS_QUERY_OR_MODE" = "true" ]; then
         # Already have query/mode. If this looks like a bare range, it's likely an error.
         if [[ "$arg" =~ ^~?[0-9]+[-–][0-9]+$ ]]; then
             echo "Error: line range '$arg' must be preceded by 'lines' (or be the first arg)." >&2
             exit 2
         fi
         # Otherwise treat as root
         SEARCH_ROOTS+=("$arg")
    else
        # If it's not a file/dir, and we need a query, assume this is it.
        # But if --regex is set, we don't want a positional query.
        if [ -n "$REGEX_PATTERN" ] || [ -n "$AT_PATTERN" ]; then
            SEARCH_ROOTS+=("$arg")
        else
            # Check if it looks like a glob though?
            if [[ "$arg" == *"*"* || "$arg" == *"?"* ]]; then
                SEARCH_ROOTS+=("$arg")
            else
                QUERY="$arg"
            fi
        fi
    fi
done

# Auto-enable list mode if roots provided but no query/mode
if [ ${#SEARCH_ROOTS[@]} -gt 0 ] && [ -z "$QUERY" ] && [ -z "$REGEX_PATTERN" ] && [ -z "$AT_PATTERN" ] && [ "$LINE_MODE" != "true" ]; then
    LIST_MODE="true"
fi

# Validation
if [ "$LIST_MODE" != "true" ] && [ -z "$REGEX_PATTERN" ] && [ -z "$AT_PATTERN" ] && [ -z "$QUERY" ] && [ "$LINE_MODE" != "true" ]; then
    echo "Error: Missing FUNCTION_NAME (or use --at / --regex / --list / lines START-END)" >&2
    exit 2
fi

# Check for incompatible option combinations
if [ -n "$AT_PATTERN" ]; then
    if [ -n "$REGEX_PATTERN" ]; then
        echo "Error: --at and --regex cannot be used together" >&2
        exit 2
    fi
    if [ "$LIST_MODE" = "true" ]; then
        echo "Error: --at and --list cannot be used together" >&2
        exit 2
    fi
    if [ -n "$QUERY" ]; then
        echo "Error: --at replaces QUERY; do not provide both" >&2
        exit 2
    fi
    if [ "$LINE_MODE" = "true" ]; then
        echo "Error: --at and explicit line ranges cannot be used together" >&2
        exit 2
    fi
fi

if [ ${#SEARCH_ROOTS[@]} -eq 0 ]; then
    echo "Error: Missing FILES/ROOTS" >&2
    echo "Run with --help for usage information." >&2
    exit 2
fi

# Pass everything to Python
export PF_TARGET="$QUERY"
export PF_INCLUDE_NESTED="$INCLUDE_NESTED"
export PF_IMPORT_MODE="$IMPORT_MODE"
export PF_LIST_MODE="$LIST_MODE"
export PF_REGEX_PATTERN="$REGEX_PATTERN"
export PF_AT_PATTERN="$AT_PATTERN"
export PF_FIRST_ONLY="$FIRST_ONLY"
export PF_LINE_MODE="$LINE_MODE"
export PF_LINE_SPEC="$LINE_SPEC"
export PF_TYPE_FILTER="$TYPE_FILTER"
export PF_CONTEXT_LINES="$CONTEXT_LINES"

extract_code() {
    python3 - "${SEARCH_ROOTS[@]}" <<'PY'
import ast
import sys
import os
import glob
import re
import tokenize
from dataclasses import dataclass
from typing import List, Set, Tuple

# --- Configuration ---
target = os.environ["PF_TARGET"]
include_nested = os.environ["PF_INCLUDE_NESTED"] == "true"
import_mode = os.environ["PF_IMPORT_MODE"]
list_mode = os.environ["PF_LIST_MODE"] == "true"
regex_pat = os.environ["PF_REGEX_PATTERN"] or None
at_pattern_str = os.environ.get("PF_AT_PATTERN") or None
first_only = os.environ["PF_FIRST_ONLY"] == "true"
line_mode = os.environ["PF_LINE_MODE"] == "true"
line_spec = os.environ["PF_LINE_SPEC"]
type_filter = os.environ["PF_TYPE_FILTER"]
try:
    context_lines = int(os.environ["PF_CONTEXT_LINES"])
except ValueError:
    context_lines = 0

if type_filter not in ("py", "all"):
    print(f"Error: unknown --type {type_filter!r} (expected 'py' or 'all')", file=sys.stderr)
    sys.exit(2)

roots = sys.argv[1:]

DEFAULT_IGNORE_DIRS = {
    '.git', '.venv', 'venv', '__pycache__', 'build', 'dist',
    '.mypy_cache', '.ruff_cache', 'node_modules', '.idea', '.vscode'
}

# --- Helpers ---
def is_py_file(p: str) -> bool:
    return p.endswith(".py") or p.endswith(".pyw")

def parse_line_spec(spec: str) -> Tuple[bool, int, int]:
    spec = spec.strip()
    smart = spec.startswith("~")
    if smart: spec = spec[1:].strip()
    spec = spec.replace("–", "-")
    m = re.fullmatch(r"(\d+)-(\d+)", spec)
    if not m: raise ValueError(f"Invalid range: {spec}")
    a, b = int(m.group(1)), int(m.group(2))
    if a <= 0 or b <= 0: raise ValueError("Line numbers must be >= 1")
    return smart, min(a,b), max(a,b)

def expand_roots(roots):
    paths = []
    missing = []
    for r in roots:
        if os.path.isfile(r):
            paths.append(r)
        elif os.path.isdir(r):
            for root, dirs, files in os.walk(r):
                dirs[:] = [d for d in dirs if d not in DEFAULT_IGNORE_DIRS]
                for f in files:
                    full_path = os.path.join(root, f)
                    if type_filter == 'py' and not is_py_file(full_path):
                        continue
                    paths.append(full_path)
        elif '*' in r or '?' in r:
            # Glob expansion
            expanded = glob.glob(r, recursive=True)
            if not expanded:
                missing.append(f"glob matched no files: {r}")
                continue
            for g in expanded:
                if os.path.isfile(g):
                    if type_filter == 'py' and not is_py_file(g):
                        continue
                    paths.append(g)
                elif os.path.isdir(g):
                     for root, dirs, files in os.walk(g):
                        dirs[:] = [d for d in dirs if d not in DEFAULT_IGNORE_DIRS]
                        for f in files:
                            full_path = os.path.join(root, f)
                            if type_filter == 'py' and not is_py_file(full_path):
                                continue
                            paths.append(full_path)
        else:
            missing.append(r)
    
    # Dedup and preserve discovery order
    seen = set()
    deduped = []
    for p in paths:
        abs_p = os.path.abspath(p)
        if abs_p not in seen:
            seen.add(abs_p)
            deduped.append(p)
    return deduped, missing

# --- AST & Logic ---
@dataclass(frozen=True)
class FoundDef:
    qualname: str
    name: str
    lineno: int
    node: ast.AST

@dataclass(frozen=True)
class FoundImport:
    node: ast.AST

class Extractor(ast.NodeVisitor):
    def __init__(self, include_nested: bool, import_mode: str):
        self.include_nested = include_nested
        self.import_mode = import_mode
        self.class_stack = []
        self.func_stack = []
        self.function_depth = 0
        self.defs = []
        self.imports = []

    def _qualname_for(self, func_name):
        return ".".join(self.class_stack + self.func_stack + [func_name])

    def visit_Import(self, node):
        if self.import_mode != "none" and self.function_depth == 0:
            self.imports.append(FoundImport(node=node))
        self.generic_visit(node)
    def visit_ImportFrom(self, node):
        if self.import_mode != "none" and self.function_depth == 0:
            self.imports.append(FoundImport(node=node))
        self.generic_visit(node)
    def visit_ClassDef(self, node):
        self.class_stack.append(node.name)
        try: self.generic_visit(node)
        finally: self.class_stack.pop()
    def visit_FunctionDef(self, node):
        self.defs.append(FoundDef(self._qualname_for(node.name), node.name, getattr(node, "lineno", 0), node))
        if self.include_nested:
            self.func_stack.append(node.name)
            self.function_depth += 1
            try: self.generic_visit(node)
            finally: self.function_depth -= 1; self.func_stack.pop()
    def visit_AsyncFunctionDef(self, node):
        self.defs.append(FoundDef(self._qualname_for(node.name), node.name, getattr(node, "lineno", 0), node))
        if self.include_nested:
            self.func_stack.append(node.name)
            self.function_depth += 1
            try: self.generic_visit(node)
            finally: self.function_depth -= 1; self.func_stack.pop()

def node_span(node):
    return (getattr(node, "lineno", 10**18), getattr(node, "col_offset", 0),
            getattr(node, "end_lineno", getattr(node, "lineno", 10**18)), getattr(node, "end_col_offset", 0))

def get_full_code(source_lines, node):
    if not hasattr(node, "lineno"): return ""
    start = node.lineno
    end = node.end_lineno
    decs = getattr(node, "decorator_list", [])
    for d in decs:
        if hasattr(d, "lineno"): start = min(start, d.lineno)
    
    seg = source_lines[start-1:end]
    if not seg: return ""
    if hasattr(node, "end_col_offset") and node.end_col_offset is not None:
         seg[-1] = seg[-1][:node.end_col_offset]
    return "".join(seg)

def contains_range(node, start, end):
    return getattr(node, "lineno", 9e9) <= start and getattr(node, "end_lineno", -1) >= end

def pick_best_enclosing(tree, start, end):
    candidates = []
    # Only include blocks, excluding single-line statements like Assign/Expr
    check_types = (
        ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef,
        ast.If, ast.For, ast.AsyncFor, ast.While,
        ast.With, ast.AsyncWith, ast.Try
    )
    # Py3.10+ Match
    if sys.version_info >= (3, 10):
        if hasattr(ast, 'Match'): check_types += (ast.Match,)

    for n in ast.walk(tree):
        if isinstance(n, check_types):
            if contains_range(n, start, end):
                candidates.append(n)
    if not candidates: return None
    
    # Priority: Function/Class > Other Blocks > ...
    # Smallest span wins (most specific).
    def priority(n):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)): return 0
        return 1
    
    candidates.sort(key=lambda n: (n.end_lineno - n.lineno, priority(n), n.lineno))
    return candidates[0]

def dedup_defs(defs):
    defs_sorted = sorted(defs, key=lambda d: node_span(d.node))
    seen = set()
    out = []
    for d in defs_sorted:
        sp = node_span(d.node)
        if sp in seen:
            continue
        seen.add(sp)
        out.append(d)
    return out

class UsedNameCollector(ast.NodeVisitor):
    def __init__(self) -> None:
        self.names: Set[str] = set()

    def _root_name(self, expr: ast.AST) -> None:
        while isinstance(expr, (ast.Attribute, ast.Subscript)):
            expr = expr.value
        if isinstance(expr, ast.Name):
            self.names.add(expr.id)

    def visit_Name(self, node: ast.Name) -> None:
        self.names.add(node.id)

    def visit_Attribute(self, node: ast.Attribute) -> None:
        # Only capture root name to avoid over-matching attribute names
        self._root_name(node.value)
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        self._root_name(node.value)
        self.generic_visit(node)

# --- Main Processing ---
regex = None
if regex_pat:
    try:
        regex = re.compile(regex_pat)
    except re.error as e:
        print(f"Error: invalid regex: {regex_pat}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(2)

at_regex = None
if at_pattern_str:
    try:
        at_regex = re.compile(at_pattern_str)
    except re.error as e:
        print(f"Error: invalid --at regex: {at_pattern_str}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(2)

def process_file(path):
    # Returns (matches, errors)
    try:
        with tokenize.open(path) as f:
            source = f.read()
    except Exception as e:
        print(f"Error reading {path}: {e}", file=sys.stderr)
        return [], True

    lines = source.splitlines(True)
    
    # Check type filter for explicit files as well
    if type_filter == 'py' and not is_py_file(path):
        if not line_mode and not at_regex:
             # Skip silent or warn? Just skip to match glob behavior.
             return [], False

    # Determine mode and line range (fixes issue #4: clearer control flow)
    current_line_mode = line_mode
    smart = False
    start = end = -1
    at_match_lineno = None  # set only when --at is used

    # Resolve --at pattern to line mode
    if at_regex:
        found_lineno = -1
        for i, line in enumerate(lines):
             if at_regex.search(line):
                 found_lineno = i + 1
                 break
        if found_lineno == -1:
            # Pattern not in this file - silent per-file non-match is normal
            return [], False

        current_line_mode = True
        smart = True
        start = end = found_lineno
        at_match_lineno = found_lineno

    # Parse explicit line mode arguments
    elif line_mode:
        try:
            smart, start, end = parse_line_spec(line_spec)
        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            return [], True

    # Suffixes for --at matching
    match_suffix_paren = f" (match line {at_match_lineno})" if at_match_lineno else ""
    match_suffix_semi = f"; match line {at_match_lineno}" if at_match_lineno else ""

    # Line Mode Processing
    if current_line_mode:
        if not smart:
            s = max(1, start - context_lines)
            e = min(len(lines), end + context_lines)
            block = "".join(lines[s-1:e]).rstrip("\n")
            ctx_info = f" (+{context_lines} context)" if context_lines > 0 else ""
            header = f"==> {path}:lines {start}-{end}{ctx_info}{match_suffix_paren} <=="
            return [(header, block)], False
        
        if not is_py_file(path):
            # Fallback smart mode
            PAD = 25 if context_lines == 0 else context_lines
            s = max(1, start - PAD)
            e = min(len(lines), end + PAD)
            block = "".join(lines[s-1:e]).rstrip("\n")
            ctx_info = f" (+{PAD} context)" 
            header = f"==> {path}:lines {start}-{end}{ctx_info}{match_suffix_paren} (padded) <=="
            return [(header, block)], False
    
    # AST Mode: Only parse Python source files if not in line mode.
    if not current_line_mode and not is_py_file(path):
        return [], False

    try:
        tree = ast.parse(source, filename=path)
    except Exception as e:
        print(f"Error parsing {path}: {e}", file=sys.stderr)
        return [], True

    # Smart Line Mode (AST)
    if current_line_mode: 
        # smart, start, end already resolved
        node = pick_best_enclosing(tree, start, end)
        if node:
            if context_lines > 0:
                s = max(1, node.lineno - context_lines)
                e = min(len(lines), node.end_lineno + context_lines)
                code = "".join(lines[s-1:e]).rstrip("\n")
                ctx_info = f" (+{context_lines} context)"
            else:
                code = get_full_code(lines, node).rstrip("\n")
                ctx_info = ""
            
            name = getattr(node, "name", "unknown")
            lineno = getattr(node, "lineno", start)
            header = f"==> {path}:{name} (line {lineno}{match_suffix_semi}){ctx_info} <=="
            return [(header, code)], False
        else:
            PAD = 25 if context_lines == 0 else context_lines
            s = max(1, start - PAD)
            e = min(len(lines), end + PAD)
            block = "".join(lines[s-1:e]).rstrip("\n")
            ctx_info = f" (+{PAD} context)" 
            header = f"==> {path}:lines {start}-{end}{ctx_info}{match_suffix_paren} (padded) <=="
            return [(header, block)], False

    # Function Extraction Mode
    ex = Extractor(include_nested=include_nested, import_mode=import_mode)
    ex.visit(tree)
    
    all_defs = dedup_defs(ex.defs)
    
    # Filter
    matched_defs = []
    if list_mode:
        if not regex and not target:
             matched_defs = all_defs
        else:
             def is_match_list(d):
                 if regex: return bool(regex.search(d.qualname))
                 if target and "." in target: return d.qualname == target
                 if target: return d.name == target
                 return False
             matched_defs = [d for d in all_defs if is_match_list(d)]
        
        out_data = []
        for d in matched_defs:
            out_data.append((d.qualname, d.lineno))
        
        if out_data:
            return out_data, False 
        return [], False
    
    def is_match(d):
        if regex: return bool(regex.search(d.qualname))
        if target and "." in target: return d.qualname == target
        if target: return d.name == target
        return False
    
    matched_defs = [d for d in all_defs if is_match(d)]
    
    if first_only and matched_defs:
        matched_defs = matched_defs[:1]
    
    # Imports
    imports_out = []
    if import_mode != "none":
        imports_sorted = sorted(ex.imports, key=lambda i: node_span(i.node))
        if import_mode == "all":
            imports_out = imports_sorted
        else:
            used_names = set()
            for d in matched_defs:
                c = UsedNameCollector()
                c.visit(d.node)
                used_names |= c.names

            for imp in imports_sorted:
                out = set()
                if isinstance(imp.node, ast.Import):
                    for a in imp.node.names: out.add(a.asname or a.name.split('.')[0])
                elif isinstance(imp.node, ast.ImportFrom):
                     for a in imp.node.names: 
                        if a.name == "*":
                            out.add("*")
                        else:
                            out.add(a.asname or a.name)
                
                if "*" in out or (out & used_names):
                    imports_out.append(imp)

    output_blocks = []
    
    imp_code = ""
    if imports_out and matched_defs:
        imp_code = "\n".join([get_full_code(lines, i.node).rstrip() for i in imports_out])
        if imp_code:
            imp_code += "\n\n" + ("#" * 20) + "\n\n"

    for i, d in enumerate(matched_defs):
        code = get_full_code(lines, d.node).rstrip("\n")
        if i == 0 and imp_code:
            code = imp_code + code
            
        header = f"==> {path}:{d.qualname} (line {d.lineno}) <=="
        output_blocks.append((header, code))
        
    return output_blocks, False

# --- Run ---
file_list, missing_list = expand_roots(roots)
any_match = False
had_error = False

# Print warnings for missing roots (non-fatal)
for m in missing_list:
    if "glob matched no files" in m:
        print(f"Warning: {m}", file=sys.stderr)
    else:
        print(f"Warning: file not found: {m}", file=sys.stderr)

for path in file_list:
    matches, error = process_file(path)
    if error:
        had_error = True
    
    if matches:
        any_match = True
        
        if list_mode:
            print(f"==> {path} <==")
            # Dynamic alignment based on qualnames in THIS file
            max_qn = max((len(qn) for qn, ln in matches), default=0)
            col_width = max(max_qn + 4, 40)
            for qn, ln in matches:
                print(f"{qn:<{col_width}} line {ln}")
            print() 
        else:
            for header, code in matches:
                print(header)
                print(code)
                print()

if not any_match:
    if target and type_filter == 'py' and not list_mode and sys.stderr.isatty():
         print("Tip: run with --list to see available definitions.", file=sys.stderr)
    sys.exit(2 if had_error else 1)

sys.exit(0)
PY
}

# --- Output Handling ---
run_with_optional_highlighting() {
    # Decide color policy
    # PF_COLOR_MODE: always|auto|never (optional)
    local pf_mode="${PF_COLOR_MODE:-auto}"

    local want_color=0
    if [ "$pf_mode" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${CLICOLOR:-1}" = "0" ] || [ "${TERM:-}" = "dumb" ]; then
        want_color=0
    elif [ "$pf_mode" = "always" ] || [ "${PF_FORCE_COLOR:-0}" = "1" ]; then
        want_color=1
    elif [ -t 1 ]; then
        want_color=1
    else
        want_color=0
    fi

    if [ "$want_color" -eq 1 ]; then
        local -a highlighter=(cat)
        
        # We are forcing color for the highlighter because we already decided want_color=1
        if command -v bat >/dev/null 2>&1; then
             highlighter=(bat --color=always --style=plain --paging=never)
             
             # If we're only dealing with Python, always force Python highlighting (even in line mode)
             if [ "$TYPE_FILTER" = "py" ]; then
                 highlighter=(bat --color=always --language=python --style=plain --paging=never)
             fi
        elif command -v batcat >/dev/null 2>&1; then
             highlighter=(batcat --color=always --style=plain --paging=never)
             
             if [ "$TYPE_FILTER" = "py" ]; then
                 highlighter=(batcat --color=always --language=python --style=plain --paging=never)
             fi
        elif command -v pygmentize >/dev/null 2>&1; then
             if [ "$TYPE_FILTER" = "py" ]; then
                 highlighter=(pygmentize -l python -f terminal256)
             else
                 highlighter=(pygmentize -g -f terminal256)
             fi
        fi
        
        set +e
        extract_code | "${highlighter[@]}"
        local -a statuses=("${PIPESTATUS[@]}")
        set -e
        if [ "${statuses[0]}" -ne 0 ]; then return "${statuses[0]}"; fi
        if [ "${statuses[1]}" -ne 0 ]; then return "${statuses[1]}"; fi
        return 0
    else
        extract_code
    fi
}

run_with_optional_highlighting
exit $?

# --- Regression Tests / Examples ---
# 1. Default list mode
# ./printfunction.sh routes.py
# Expected: Lists functions in routes.py (e.g. hello, world)

# 2. Explicit query overrides default list mode
# ./printfunction.sh hello routes.py
# Expected: Prints source code of hello function

# 3. Regex mode still works
# ./printfunction.sh --regex 'hel.*' routes.py
# Expected: Prints source code of hello function

# 4. Explicit line mode
# ./printfunction.sh lines 10-20 routes.py
# Expected: Prints lines 10-20


