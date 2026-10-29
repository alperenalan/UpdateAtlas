#!/usr/bin/env python3
"""Standalone PoC entry point for the Antigravity application."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from google_app_probe import probe
probe("Antigravity.app", "com.google.antigravity", "antigravity")
