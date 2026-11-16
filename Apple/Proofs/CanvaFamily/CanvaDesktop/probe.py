#!/usr/bin/env python3
"""Separate PoC for Canva Desktop."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_common import probe
probe("Canva.app", "com.canva.CanvaDesktop", "canva")
