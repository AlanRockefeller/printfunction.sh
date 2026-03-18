"""Tests for gitdiffshow --patch mode."""
import os
import subprocess
import tempfile
import textwrap

import pytest


@pytest.fixture
def script_path():
    path = os.path.abspath("gitdiffshow.bash")
    assert os.path.exists(path), "gitdiffshow.bash not found"
    os.chmod(path, 0o755)
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
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        input=stdin_data,
    )
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

def test_patch_file_missing(script_path):
    """--patch with a nonexistent file should produce an error."""
    res = run_gitdiffshow(script_path, ["--patch", "/tmp/nonexistent_patch_abc123.patch"])
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
