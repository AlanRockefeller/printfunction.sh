import pytest
import subprocess
import os
import sys
import shutil

def run_script(script_path, args, cwd=None, env=None):
    """Run the printfunction.sh script and return stdout, stderr, returncode."""
    if env is None:
        env = os.environ.copy()
    
    # Ensure the script is executable
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

def test_help(script_path):
    res = run_script(script_path, ["--help"])
    assert res.returncode == 0
    assert "Usage:" in res.stdout

def test_simple_match(script_path, fixtures_dir):
    res = run_script(script_path, ["hello", "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def hello():" in res.stdout
    assert "==> simple.py:hello (line 1) <==" in res.stdout

def test_async_match(script_path, fixtures_dir):
    res = run_script(script_path, ["async_func", "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "async def async_func():" in res.stdout

def test_class_method_match(script_path, fixtures_dir):
    # Match specific method in class
    res = run_script(script_path, ["MyClass.method", "class_test.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "class MyClass:" not in res.stdout 
    assert "def method(self):" in res.stdout
    assert "==> class_test.py:MyClass.method" in res.stdout

def test_toplevel_vs_method(script_path, fixtures_dir):
    # Match top level method
    res = run_script(script_path, ["method", "class_test.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def method(self):" in res.stdout
    assert "def method():" in res.stdout

def test_no_match_exit_code(script_path, fixtures_dir):
    res = run_script(script_path, ["nonexistent", "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 1
    assert "def nonexistent" not in res.stdout

def test_syntax_error(script_path, fixtures_dir):
    res = run_script(script_path, ["broken", "bad/syntax_error.py"], cwd=fixtures_dir)
    assert res.returncode == 2
    assert "Error parsing" in res.stderr

def test_false_positive_optimization(script_path, fixtures_dir):
    # optimization 1: precheck.
    # "hello" is in comments in false_positive.py, but not as a def.
    # AST parse would filter it out anyway.
    # But we want to ensure we don't accidentally match it or crash.
    res = run_script(script_path, ["hello", "false_positive.py"], cwd=fixtures_dir)
    assert res.returncode == 1

def test_ignore_dirs(script_path, fixtures_dir):
    # .venv should be ignored by default
    cwd = os.path.join(fixtures_dir, "ignore_test_env")
    res = run_script(script_path, ["ignored_func", "."], cwd=cwd)
    assert res.returncode == 1
    
    # explicit file in ignored dir should work?
    res = run_script(script_path, ["ignored_func", ".venv/lib.py"], cwd=cwd)
    assert res.returncode == 0

def test_fast_path_skips_syntax_error(script_path, fixtures_dir):
    # Search for "hello" in bad/syntax_error.py
    # syntax_error.py has "def broken", so it does NOT have "def hello" or "hello".
    # Fast path (opt 1) should skip parsing.
    # RG path (opt 2) should also not match it.
    # So we expect exit 1 (no match), not exit 2 (error).
    
    # Ensure syntax_error.py exists
    assert os.path.exists(os.path.join(fixtures_dir, "bad/syntax_error.py"))
    
    res = run_script(script_path, ["hello", "bad/syntax_error.py"], cwd=fixtures_dir)
    if res.returncode == 2:
        pytest.fail(f"Fast path failed to skip syntax error file without target. Stderr: {res.stderr}")
    assert res.returncode == 1

def test_rg_globs(script_path, fixtures_dir):
    # Test that globs work with RG optimization
    # If we pass "**/*.py", RG should run.
    os.makedirs(os.path.join(fixtures_dir, "subdir/deep"), exist_ok=True)
    with open(os.path.join(fixtures_dir, "subdir/deep/test.py"), "w") as f:
        f.write("def deep_func(): pass\n")
        
    res = run_script(script_path, ["deep_func", "**/*.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def deep_func():" in res.stdout

def test_recursive_ignores(script_path, fixtures_dir):
    # Test that ignored dirs are recursively ignored
    # node_modules/pkg/ignored.py should be ignored
    os.makedirs(os.path.join(fixtures_dir, "node_modules/pkg"), exist_ok=True)
    with open(os.path.join(fixtures_dir, "node_modules/pkg/ignored.py"), "w") as f:
        f.write("def should_be_ignored(): pass\n")
        
    res = run_script(script_path, ["should_be_ignored", "."], cwd=fixtures_dir)
    assert res.returncode == 1

def test_pyw_coverage(script_path, fixtures_dir):
    # Test .pyw files are found
    os.makedirs(os.path.join(fixtures_dir, "hidden"), exist_ok=True)
    with open(os.path.join(fixtures_dir, "hidden/test.pyw"), "w") as f:
        f.write("def hidden_func(): pass\n")
        
    res = run_script(script_path, ["hidden_func", "."], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def hidden_func():" in res.stdout

def test_rg_vs_no_rg(script_path, fixtures_dir):
    # We want to run the exact same command with RG enabled (default if installed) and disabled.
    # We disable RG by hiding it from PATH.
    
    # Run with rg (normal environment)
    res_rg = run_script(script_path, ["hello", "."], cwd=fixtures_dir)
    
    # Run without rg
    # Use the internal env var PF_DISABLE_RG=1
    env_no_rg = os.environ.copy()
    env_no_rg["PF_DISABLE_RG"] = "1"
    
    res_no_rg = run_script(script_path, ["hello", "."], cwd=fixtures_dir, env=env_no_rg)
    
    assert res_rg.returncode == res_no_rg.returncode
    
    # Extract headers
    headers_rg = sorted([l for l in res_rg.stdout.splitlines() if l.startswith("==>")])
    headers_no_rg = sorted([l for l in res_no_rg.stdout.splitlines() if l.startswith("==>")])
    
    assert headers_rg == headers_no_rg
    assert "def hello():" in res_rg.stdout

def test_type_filter_all(script_path, fixtures_dir):
    # default type=py
    res = run_script(script_path, ["hello", "other.txt"], cwd=fixtures_dir)
    assert res.returncode == 1 # skipped other.txt
    
    # type=all
    res = run_script(script_path, ["--type", "all", "lines", "1-3", "other.txt"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "This is not a python file" in res.stdout

def test_list_mode(script_path, fixtures_dir):
    res = run_script(script_path, ["--list", "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "hello" in res.stdout
    assert "world" in res.stdout

def test_regex_mode(script_path, fixtures_dir):
    res = run_script(script_path, ["--regex", "h.*", "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def hello():" in res.stdout
    assert "def world():" not in res.stdout

def test_at_mode(script_path, fixtures_dir):
    # --at 'print\("Hello"\)' should find hello function
    res = run_script(script_path, ["--at", r'print\("Hello"\)', "simple.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def hello():" in res.stdout

def test_colon_in_filename(script_path, fixtures_dir):
    # Test file with colon in path
    target_file = os.path.join(fixtures_dir, "weird:dir/file.py")
    if not os.path.exists(target_file):
        # pytest.skip("Skipping colon test because fixture creation failed or OS doesn't support colons")
        # Try creating it again here to be sure
        try:
            os.makedirs(os.path.dirname(target_file), exist_ok=True)
            with open(target_file, "w") as f:
                f.write("def weird_func(): pass\n")
        except OSError:
             pytest.skip("Cannot create file with colon")
    
    res = run_script(script_path, ["weird_func", target_file], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def weird_func():" in res.stdout
    assert "weird:dir/file.py" in res.stdout

def test_missing_root_warnings(script_path, fixtures_dir):
    # Ensure warnings are printed for missing roots
    res = run_script(script_path, ["hello", "nonexistent_file.py"], cwd=fixtures_dir)
    assert res.returncode == 1
    assert "Warning: file not found: nonexistent_file.py" in res.stderr

def test_many_matches_performance(script_path, fixtures_dir):
    # Performance correctness check
    # Create file if not exists
    many_file = os.path.join(fixtures_dir, "many_matches.py")
    if not os.path.exists(many_file):
        with open(many_file, "w") as f:
            f.write("def many_matches_func(): pass\n")
            for i in range(1000):
                f.write(f"def func_{i}(): pass\n")

    res = run_script(script_path, ["many_matches_func", "many_matches.py"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "def many_matches_func():" in res.stdout
    # Should not print the 1000 other funcs
    assert "def func_1():" not in res.stdout

def test_rg_fallback_on_failure(script_path, fixtures_dir):
    # Mock rg failure by using a wrapper script that exits 2
    import tempfile
    
    tmp_bin = tempfile.mkdtemp()
    rg_shim = os.path.join(tmp_bin, "rg")
    with open(rg_shim, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("echo 'Simulated RG Error' >&2\n")
        f.write("exit 2\n")
    os.chmod(rg_shim, 0o755)
    
    env = os.environ.copy()
    env["PATH"] = f"{tmp_bin}{os.pathsep}{env.get('PATH', '')}"
    
    try:
        res = run_script(script_path, ["hello", "simple.py"], cwd=fixtures_dir, env=env)
        # Should fall back to python and succeed
        assert res.returncode == 0
        assert "def hello():" in res.stdout
        # Should see warning
        assert "Warning: rg failed (exit 2)" in res.stderr
        assert "Simulated RG Error" in res.stderr
    finally:
        shutil.rmtree(tmp_bin)

def test_no_duplicate_missing_root_warnings(script_path, fixtures_dir):
    # Test that missing root warning appears exactly once
    res = run_script(script_path, ["hello", "simple.py", "nonexistent_root.py"], cwd=fixtures_dir)
    assert res.returncode == 0 # simple.py matches
    assert res.stderr.count("Warning: file not found: nonexistent_root.py") == 1

def test_glob_no_files_warning_with_rg(script_path, fixtures_dir):
    # Test that glob warning appears even when rg succeeds on other files
    # rg succeeds for simple.py
    # glob *.missing fails
    res = run_script(script_path, ["hello", "simple.py", "*.missing_extension"], cwd=fixtures_dir)
    assert res.returncode == 0
    assert "Warning: glob matched no files: *.missing_extension" in res.stderr

def test_rg_disabled_for_type_all(script_path, fixtures_dir):
    # Ensure rg is NOT called when --type all is used
    import tempfile
    
    tmp_bin = tempfile.mkdtemp()
    rg_shim = os.path.join(tmp_bin, "rg")
    with open(rg_shim, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("echo 'RG WAS CALLED' >&2\n")
        f.write("exit 2\n") # Fail if called
    os.chmod(rg_shim, 0o755)
    
    env = os.environ.copy()
    env["PATH"] = f"{tmp_bin}{os.pathsep}{env.get('PATH', '')}"
    
    try:
        # Case 1: type all -> rg should NOT be called
        res_all = run_script(script_path, ["--type", "all", "hello", "simple.py"], cwd=fixtures_dir, env=env)
        assert res_all.returncode == 0
        assert "RG WAS CALLED" not in res_all.stderr
        
        # Case 2: type py -> rg SHOULD be called (and fail with warning, but fallback succeeds)
        res_py = run_script(script_path, ["hello", "simple.py"], cwd=fixtures_dir, env=env)
        assert res_py.returncode == 0
        assert "RG WAS CALLED" in res_py.stderr
        assert "Warning: rg failed" in res_py.stderr
        
    finally:
        shutil.rmtree(tmp_bin)

def test_output_equivalence(script_path, fixtures_dir):
    # Compare output with and without rg for a glob query
    # Ensure make_hdrop case (recursive glob) works
    
    # Setup recursive structure
    os.makedirs(os.path.join(fixtures_dir, "recur/sive"), exist_ok=True)
    with open(os.path.join(fixtures_dir, "recur/sive/target.py"), "w") as f:
        f.write("def target_func():\n    pass\n")
        
    # Run with RG (default)
    res_rg = run_script(script_path, ["target_func", "**/*.py"], cwd=fixtures_dir)
    assert res_rg.returncode == 0
    
    # Run without RG
    env_no_rg = os.environ.copy()
    env_no_rg["PF_DISABLE_RG"] = "1"
    res_no_rg = run_script(script_path, ["target_func", "**/*.py"], cwd=fixtures_dir, env=env_no_rg)
    assert res_no_rg.returncode == 0
    
    assert res_rg.stdout == res_no_rg.stdout
