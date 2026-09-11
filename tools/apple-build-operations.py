#!/usr/bin/python3 -B
"""Explicit, evidence-bound Apple build maintenance operations."""

import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from apple_build_operations import main

if __name__ == "__main__":
    sys.exit(main())
