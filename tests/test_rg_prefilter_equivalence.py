import pytest
import subprocess
import os
import sys
import shutil

@pytest.fixture
def script_path():
    path = os.path.abspath("printfunction.sh")
    os.chmod(path, 0o755)
    return path

@pytest.fixture
def fixtures_dir(tmp_path):
    return str(tmp_path)

def run_script(script_path, args, cwd, env=None):
    if env is None:
        env = os.environ.copy()
    
    # Enable test debug output
    env["PF_TEST_RG_USED"] = "1"
    
    # Ensure script is executable
    os.chmod(script_path, 0o755)
    
    cmd = [script_path] + args
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True
    )
    return result

def create_file(root, path, content="def target(): pass\n"):
    full_path = os.path.join(root, path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w") as f:
        f.write(content)
    return full_path

def test_restrictive_glob_does_not_broaden(script_path, fixtures_dir):
    create_file(fixtures_dir, "a/a.py", "def target(): pass\n")
    create_file(fixtures_dir, "b/b.py", "def target(): pass\n")
    
    # Run with RG
    res_rg = run_script(script_path, ["target", "a/*.py"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    assert "a/a.py" in res_rg.stdout
    assert "b/b.py" not in res_rg.stdout
    assert "DEBUG: RG USED" in res_rg.stderr
    
    # Run without RG
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "a/*.py"], cwd=fixtures_dir, env=env)
    
    assert res_rg.stdout == res_no_rg.stdout
    assert "DEBUG: RG USED" not in res_no_rg.stderr

def test_directory_yielding_glob_no_false_warning(script_path, fixtures_dir):
    create_file(fixtures_dir, "pkg/mod.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "pkg/**"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    assert "glob matched no files" not in res_rg.stderr
    assert "DEBUG: RG USED" in res_rg.stderr
    
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "pkg/**"], cwd=fixtures_dir, env=env)
    
    assert res_rg.stdout == res_no_rg.stdout
    assert res_rg.stderr.replace("DEBUG: RG USED\n", "") == res_no_rg.stderr

def test_ignored_only_glob_behavior(script_path, fixtures_dir):
    create_file(fixtures_dir, "verify_venv/x.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "verify_venv/**"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    assert "glob matched no files" not in res_rg.stderr
    assert "verify_venv/x.py" in res_rg.stdout
    assert "DEBUG: RG USED" in res_rg.stderr
    
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "verify_venv/**"], cwd=fixtures_dir, env=env)
    
    # Parity check
    assert res_rg.stdout == res_no_rg.stdout
    assert res_rg.stderr.replace("DEBUG: RG USED\n", "") == res_no_rg.stderr

def test_non_py_only_glob_warns(script_path, fixtures_dir):
    create_file(fixtures_dir, "data/x.txt", "def target(): pass\n")
    create_file(fixtures_dir, "valid.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "data/**", "valid.py"], cwd=fixtures_dir)
    # rg finds valid.py. data/** matches x.txt (filtered).
    # expand_roots behavior: no warning if glob matches anything (even if filtered).
    assert "Warning: glob matched no files: data/**" not in res_rg.stderr
    assert res_rg.returncode == 0
    assert "DEBUG: RG USED" in res_rg.stderr

def test_warning_formatting_regression(script_path, fixtures_dir):
    create_file(fixtures_dir, "valid.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "NO_SUCH_FILE.py", "really_no_match/nonexistent*", "valid.py"], cwd=fixtures_dir)
    
    assert "Warning: file not found: NO_SUCH_FILE.py" in res_rg.stderr
    assert "Warning: glob matched no files: really_no_match/nonexistent*" in res_rg.stderr
    assert "Warning: file not found: glob matched no files" not in res_rg.stderr
    assert "DEBUG: RG USED" in res_rg.stderr
    
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "NO_SUCH_FILE.py", "really_no_match/nonexistent*", "valid.py"], cwd=fixtures_dir, env=env)
    
    assert res_rg.stderr.replace("DEBUG: RG USED\n", "") == res_no_rg.stderr

def test_rg_error_fallback_single_line(script_path, fixtures_dir):
    import tempfile
    tmp_bin = tempfile.mkdtemp()
    rg_shim = os.path.join(tmp_bin, "rg")
    with open(rg_shim, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("echo 'Some Error' >&2\n")
        f.write("exit 2\n")
    os.chmod(rg_shim, 0o755)
    
    env = os.environ.copy()
    env["PATH"] = f"{tmp_bin}{os.pathsep}{env.get('PATH', '')}"
    env["PF_TEST_RG_USED"] = "1"
    
    create_file(fixtures_dir, "a.py", "def target(): pass\n")
    
    res = run_script(script_path, ["target", "."], cwd=fixtures_dir, env=env)
    
    assert "Warning: rg failed (exit 2): Some Error; falling back to full scan." in res.stderr
    assert "def target():" in res.stdout
    assert res.returncode == 0
    # RG failed, so PF_RG_USED should NOT be set (or at least not passed to python success path)
    assert "DEBUG: RG USED" not in res.stderr
    
    shutil.rmtree(tmp_bin)

def test_rg_success_empty_json(script_path, fixtures_dir):
    # Test 7: Rg succeeds but empty output (e.g. no matches)
    # Should fall back to full scan (because file_targets empty)
    # And PF_RG_USED should be set in bash, but Python "if file_targets" is false.
    # So "DEBUG: RG USED" will be printed if it's outside "if file_targets".
    # I placed it at top of Run.
    # So it should be printed.
    
    import tempfile
    tmp_bin = tempfile.mkdtemp()
    rg_shim = os.path.join(tmp_bin, "rg")
    with open(rg_shim, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("exit 0\n") 
    os.chmod(rg_shim, 0o755)
    
    env = os.environ.copy()
    env["PATH"] = f"{tmp_bin}{os.pathsep}{env.get('PATH', '')}"
    env["PF_TEST_RG_USED"] = "1"
    
    create_file(fixtures_dir, "a.py", "def target(): pass\n")
    
    try:
        res = run_script(script_path, ["target", "."], cwd=fixtures_dir, env=env)
        assert res.returncode == 0
        assert "def target():" in res.stdout
        assert "DEBUG: RG USED" in res.stderr
    finally:
        shutil.rmtree(tmp_bin)

def test_output_ordering_parity(script_path, fixtures_dir):
    # Test 6: Output ordering parity
    create_file(fixtures_dir, "a1.py", "def target(): pass\n")
    create_file(fixtures_dir, "a2.py", "def target(): pass\n")
    create_file(fixtures_dir, "b1.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "**/*.py"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "**/*.py"], cwd=fixtures_dir, env=env)
    assert res_no_rg.returncode == 0
    
    assert res_rg.stdout == res_no_rg.stdout

def test_bracket_glob_handling(script_path, fixtures_dir):
    create_file(fixtures_dir, "x/a.py", "def target(): pass\n")
    create_file(fixtures_dir, "x/b.py", "def target(): pass\n")
    create_file(fixtures_dir, "x/c.py", "def target(): pass\n")
    
    res_rg = run_script(script_path, ["target", "x/[ab].py"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    assert "x/a.py" in res_rg.stdout
    assert "x/b.py" in res_rg.stdout
    assert "x/c.py" not in res_rg.stdout
    assert "DEBUG: RG USED" in res_rg.stderr
    
    env = os.environ.copy()
    env["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target", "x/[ab].py"], cwd=fixtures_dir, env=env)
    
    assert res_rg.stdout == res_no_rg.stdout
    assert res_rg.stderr.replace("DEBUG: RG USED\n", "") == res_no_rg.stderr
