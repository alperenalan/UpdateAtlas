#!/usr/bin/env python3
"""Separate PoC for discontinued Affinity Designer 2."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_common import probe
probe("Affinity Designer 2.app", "com.seriflabs.affinitydesigner2", "affinity-designer")
