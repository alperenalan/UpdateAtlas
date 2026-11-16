# Cloudflare CLI proof

Run `python3 Apple/Proofs/CloudflareCLI/probe.py`. The probe reads the global npm package manifest and checks the `cf` symlink. It does not call `cf`, npm, a registry, or an updater. Its `notChecked` result means this proof does not establish whether a newer release exists.
