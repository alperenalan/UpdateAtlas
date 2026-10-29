#!/usr/bin/env python3
"""Standalone PoC entry point for the Gemini Mac application."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from google_app_probe import probe
probe("Gemini.app", "com.google.GeminiMacOS", "google-gemini")
