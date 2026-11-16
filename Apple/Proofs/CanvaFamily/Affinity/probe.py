#!/usr/bin/env python3
"""Separate PoC for current Affinity by Canva."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_common import probe
probe("Affinity.app", "com.canva.affinity", "affinity", affinity_feed=True)
