# Ollama CLI proof

Run `python3 Apple/Proofs/OllamaCLI/probe.py`. The probe reads the app's `Info.plist` and verifies that `/usr/local/bin/ollama` resolves to its bundled executable. It does not start Ollama, contact its server, check for updates, or modify the app.
