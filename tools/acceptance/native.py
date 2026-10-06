"""Test-only access to the real native executable; never a product fallback."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def binary_path(value=None):
    candidate = value or os.environ.get('FP_GAME_BINARY')
    path = Path(candidate) if candidate else ROOT / '.build/tools' / ('fp-game.exe' if os.name == 'nt' else 'fp-game')
    path = path.resolve()
    if not path.is_file():
        raise ValueError('Bootstrap the native CLI first; see docs/native-tooling.md. Missing: ' + str(path))
    return path


def invoke(action, *arguments, binary=None, foundation=ROOT):
    result = subprocess.run([str(binary_path(binary)), action, *map(str, arguments),
                             '--project', str(foundation), '--json'], cwd=foundation,
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=300)
    value = json.loads(result.stdout)
    if result.returncode != 0 or value.get('exit_code') != result.returncode or result.stderr:
        raise RuntimeError('Native test setup failed: ' + result.stdout + result.stderr)
    return value


def create_game(name, destination, title=None, binary=None, foundation=ROOT):
    destination = Path(destination)
    arguments = [name, destination]
    if title is not None:
        arguments.extend(['--title', title])
    invoke('create', *arguments, binary=binary, foundation=foundation)
    return destination
