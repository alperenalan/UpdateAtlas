# Android Studio proof of concept

Run `python3 Apple/Proofs/AndroidStudio/probe.py` to inspect the current Android Studio bundle, its version-specific user and bundled plugins, and locally installed SDK packages. Add `--check` to ask Android CLI for SDK update status and JetBrains Marketplace for versions compatible with the installed IDE build. Output is JSON; no update is installed.

The configured SDK path comes from Android Studio's `options/android.sdk.path.xml`; `--sdk` overrides it. The probe reads `plugin.xml` from a plugin directory or its JAR. A plugin directory does not prove the plugin is enabled. Bundled plugins are reported as IDE-managed. Marketplace checks apply to user plugins only and use the IDE build for compatibility. SDK `noUpdateReported` means the CLI did not list an update in its current channel, not that the package is current on every channel.

The probe is intentionally a separate executable so its findings can be checked before implementing the same discovery in Update Atlas. The user interface and any update action still need a separate decision.
