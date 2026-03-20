"""Tests for gitdiffshow --patch mode."""
import os
import stat
import subprocess
import tempfile
import textwrap

import pytest


@pytest.fixture
def script_path():
    path = os.path.abspath("gitdiffshow.bash")
    assert os.path.exists(path), "gitdiffshow.bash not found"
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


@pytest.fixture
def repo_root():
    return os.path.abspath(".")


def run_gitdiffshow(script_path, args, stdin_data=None, cwd=None, env=None):
    if env is None:
        env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    cmd = [script_path, *args]
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            input=stdin_data,
            timeout=30,
        )
    except subprocess.TimeoutExpired as e:
        raise AssertionError(f"gitdiffshow timed out after 30s: {cmd}") from e
    return result


# ---------------------------------------------------------------------------
# Patch file with a modified Python file
# ---------------------------------------------------------------------------

MODIFIED_PY_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    index abc1234..def5678 100644
    --- a/tests/fixtures/simple.py
    +++ b/tests/fixtures/simple.py
    @@ -1,3 +1,4 @@
     def hello():
    -    pass
    +    print("hello")
    +    return True
""")


def test_patch_modified_file(script_path, repo_root):
    """--patch with a modified Python file should show function context."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(MODIFIED_PY_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "simple.py" in res.stdout
        assert "changed file(s) from patch" in res.stdout
        assert "Done!" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# New file
# ---------------------------------------------------------------------------

NEW_FILE_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    new file mode 100644
    index 0000000..abc1234
    --- /dev/null
    +++ b/tests/fixtures/simple.py
    @@ -0,0 +1,3 @@
    +def hello():
    +    pass
    +
""")


def test_patch_new_file(script_path, repo_root):
    """--patch with a new file should label it as (new file)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(NEW_FILE_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "(new file)" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Deleted file
# ---------------------------------------------------------------------------

DELETED_FILE_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    deleted file mode 100644
    index abc1234..0000000
    --- a/tests/fixtures/simple.py
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -def hello():
    -    pass
    -
""")


def test_patch_deleted_file(script_path, repo_root):
    """--patch with a deleted file should label it as (deleted)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(DELETED_FILE_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "(deleted)" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Renamed file
# ---------------------------------------------------------------------------

RENAMED_FILE_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/old_name.py b/tests/fixtures/simple.py
    similarity index 100%
    rename from tests/fixtures/old_name.py
    rename to tests/fixtures/simple.py
""")


def test_patch_renamed_file(script_path, repo_root):
    """--patch with a renamed file should label it as (renamed from ...)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(RENAMED_FILE_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "renamed from" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# --patch + revspecs -> error
# ---------------------------------------------------------------------------

def test_patch_with_revspec_errors(script_path):
    """--patch combined with revspecs should produce an error."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(MODIFIED_PY_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "HEAD"])
        assert res.returncode != 0
        assert "cannot be combined" in res.stderr
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Missing patch file -> error
# ---------------------------------------------------------------------------

def test_patch_file_missing(script_path, tmp_path):
    """--patch with a nonexistent file should produce an error."""
    missing = tmp_path / "nonexistent_patch_abc123.patch"
    res = run_gitdiffshow(script_path, ["--patch", str(missing)])
    assert res.returncode != 0
    assert "not found" in res.stderr


# ---------------------------------------------------------------------------
# --patch - (stdin)
# ---------------------------------------------------------------------------

def test_patch_stdin(script_path, repo_root):
    """--patch - should read from stdin."""
    res = run_gitdiffshow(
        script_path,
        ["--patch", "-", "--no-color"],
        stdin_data=MODIFIED_PY_PATCH,
    )
    assert res.returncode == 0
    assert "simple.py" in res.stdout
    assert "changed file(s) from patch" in res.stdout


# ---------------------------------------------------------------------------
# --patch + --diff shows per-file raw diff
# ---------------------------------------------------------------------------

def test_patch_with_diff_flag(script_path, repo_root):
    """--patch + --diff should show the raw patch diff per file."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(MODIFIED_PY_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--diff", "--no-color"])
        assert res.returncode == 0
        assert "Patch Diff" in res.stdout
        # Should show the actual diff content
        assert "@@" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# --relative in patch mode
# ---------------------------------------------------------------------------

def test_patch_relative_filters(script_path, repo_root):
    """--patch + --relative should only show files under CWD."""
    # Patch references tests/fixtures/simple.py
    # Running from tests/ subdir should include it
    # Running from a different subdir should exclude it
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(MODIFIED_PY_PATCH)
        patch_path = f.name
    try:
        # From the tests/ subdir, the file should be visible
        res = run_gitdiffshow(
            script_path,
            ["--patch", patch_path, "--relative", "--no-color"],
            cwd=os.path.join(repo_root, "tests"),
        )
        assert res.returncode == 0
        assert "simple.py" in res.stdout

        # From the repo root with a patch that references tests/fixtures/,
        # running --relative from a dir that doesn't contain the file should filter it out
        with tempfile.TemporaryDirectory() as tmpdir:
            res2 = run_gitdiffshow(
                script_path,
                ["--patch", patch_path, "--relative", "--no-color"],
                cwd=tmpdir,
            )
            # Should find no files (the patch paths don't exist under tmpdir)
            assert res2.returncode == 0
            assert "No files found in patch" in res2.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Non-Python file in patch
# ---------------------------------------------------------------------------

NON_PYTHON_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/other.txt b/tests/fixtures/other.txt
    index abc1234..def5678 100644
    --- a/tests/fixtures/other.txt
    +++ b/tests/fixtures/other.txt
    @@ -1,2 +1,3 @@
     hello world
    +new line here
     goodbye world
""")


def test_patch_non_python_file(script_path, repo_root):
    """--patch should work for non-Python files (hunk excerpts)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(NON_PYTHON_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "other.txt" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Help text includes --patch
# ---------------------------------------------------------------------------

def test_help_includes_patch(script_path):
    """Help text should document --patch."""
    res = run_gitdiffshow(script_path, ["--help"])
    assert res.returncode == 0
    assert "--patch" in res.stdout
    assert "stdin" in res.stdout.lower() or "- for stdin" in res.stdout


# ---------------------------------------------------------------------------
# Multi-commit patch with repeated paths and filtering
# ---------------------------------------------------------------------------

# Two commits touching the same file, with an unrelated file in between
# that will be filtered out by --relative when run from tests/.
MULTI_COMMIT_PATCH = textwrap.dedent("""\
    diff --git a/docs/readme.txt b/docs/readme.txt
    index aaa1111..bbb2222 100644
    --- a/docs/readme.txt
    +++ b/docs/readme.txt
    @@ -1,2 +1,3 @@
     some docs
    +added line
     end
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    index abc1234..def5678 100644
    --- a/tests/fixtures/simple.py
    +++ b/tests/fixtures/simple.py
    @@ -1,3 +1,4 @@
     def hello():
    -    pass
    +    print("hello")
    +    return True
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    index def5678..ghi9012 100644
    --- a/tests/fixtures/simple.py
    +++ b/tests/fixtures/simple.py
    @@ -2,3 +2,4 @@
     def hello():
         print("hello")
    +    print("world")
         return True
""")


# ---------------------------------------------------------------------------
# Pure-deletion hunk with context (regression test)
# ---------------------------------------------------------------------------

# Patch that removes a line from a Python function, leaving context around it.
# The hunk has new_count > 0 but NO '+' lines — only context and one '-'.
PURE_DELETION_PATCH = textwrap.dedent("""\
    diff --git a/tests/fixtures/simple.py b/tests/fixtures/simple.py
    index abc1234..def5678 100644
    --- a/tests/fixtures/simple.py
    +++ b/tests/fixtures/simple.py
    @@ -1,4 +1,3 @@
     def hello():
    -    print("hello")
         return True
""")


def test_patch_pure_deletion_with_context(script_path, repo_root):
    """A hunk that only deletes lines (with surrounding context) must still be shown."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(PURE_DELETION_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        assert res.returncode == 0
        assert "simple.py" in res.stdout
        # The file should NOT be skipped — the hunk must produce a changed-line anchor
        assert "changed file(s) from patch" in res.stdout
        # There must be some analysis output (FUNC or NONFUNC or excerpt)
        # for the file, proving the deletion was detected
        assert "hello" in res.stdout
    finally:
        os.unlink(patch_path)


# ---------------------------------------------------------------------------
# Path traversal with .. is blocked
# ---------------------------------------------------------------------------

DOTDOT_PATCH = textwrap.dedent("""\
    diff --git a/../../etc/passwd b/../../etc/passwd
    index abc1234..def5678 100644
    --- a/../../etc/passwd
    +++ b/../../etc/passwd
    @@ -1,2 +1,3 @@
     root:x:0:0
    +injected
     daemon:x:1:1
""")


def test_patch_dotdot_traversal_blocked(script_path, repo_root):
    """Patch paths containing .. that escape the base dir must be filtered out."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(DOTDOT_PATCH)
        patch_path = f.name
    try:
        res = run_gitdiffshow(script_path, ["--patch", patch_path, "--no-color"])
        # The traversal path should be silently filtered; no crash, no output for it
        assert res.returncode == 0
        assert "etc/passwd" not in res.stdout
        assert "No files found in patch" in res.stdout
    finally:
        os.unlink(patch_path)


def test_patch_repeated_path_with_filtering(script_path, repo_root):
    """Multi-commit patch: both entries for a repeated path should use the correct diff section."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".patch", delete=False) as f:
        f.write(MULTI_COMMIT_PATCH)
        patch_path = f.name
    try:
        # Run from tests/ so docs/readme.txt is filtered out by --relative.
        # Both simple.py entries should still resolve to the correct diff section.
        res = run_gitdiffshow(
            script_path,
            ["--patch", patch_path, "--relative", "--diff", "--no-color"],
            cwd=os.path.join(repo_root, "tests"),
        )
        assert res.returncode == 0
        # The first simple.py entry's diff has "print("hello")"
        # The second simple.py entry's diff has "print("world")"
        # Both must appear; if the index is wrong, the second would show
        # the first entry's diff again (missing "world").
        assert 'print("hello")' in res.stdout
        assert 'print("world")' in res.stdout
        # docs/readme.txt should be filtered out
        assert "readme.txt" not in res.stdout
    finally:
        os.unlink(patch_path)
