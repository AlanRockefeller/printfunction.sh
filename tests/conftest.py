import pytest
import os
import shutil
import sys

@pytest.fixture
def script_path():
    path = os.path.abspath("printfunction.sh")
    assert os.path.exists(path), "printfunction.sh not found"
    return path

@pytest.fixture
def fixtures_dir():
    return os.path.abspath("tests/fixtures")
