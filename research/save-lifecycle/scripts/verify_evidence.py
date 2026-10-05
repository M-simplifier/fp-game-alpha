#!/usr/bin/env python3
"""Compatibility entrypoint; evidence path is always caller-selectable."""
import os
import pathlib
import sys
sys.dont_write_bytecode = True
from run_experiment import REPO, verify
if len(sys.argv) > 2:
    raise SystemExit('usage: verify_evidence.py [RUN_DIR]')
verify(pathlib.Path(sys.argv[1] if len(sys.argv) == 2 else os.environ.get('RUN_DIR', str(REPO / '.build/save-lifecycle'))).resolve())
