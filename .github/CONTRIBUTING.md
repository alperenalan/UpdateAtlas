# Contributing

Thanks for helping improve Update Atlas. The app is free, has no ads and does not track usage,
and it is maintained by one person, so focused issues and small pull requests are the easiest to
review. Use the issue forms: **Missing or wrong app** for catalog coverage, **Bug report** for
everything else.

## Before opening a change

- Search existing issues first.
- Keep update-source detection deterministic and evidence based.
- Never add shell commands, installer scripts, credentials, or executable rules to the remote catalog.
- Prefer bundle identifiers and signing team identifiers over display names.
- Separate detection support from installation support in both code and documentation.
- Do not post a personal software inventory, local paths, account names or credentials in a public issue.

## Development

Requirements: macOS 14+, Xcode 26 or later, and XcodeGen.

```sh
cd Apple
xcodegen generate
xcodebuild -project UpdateAtlas.xcodeproj -scheme UpdateAtlas \
  -configuration Debug -derivedDataPath ../.temporary_files/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Edit `Apple/project.yml`, then regenerate the Xcode project. Do not hand-edit the generated `.xcodeproj`.

## Catalog contributions

Catalog changes should include the vendor's canonical source, a stable bundle identifier, and signing-team evidence when available. Validate entries against `__Assets__/Contentgen/Catalog/catalog-v1.schema.json` and explain how the source was verified.

## Pull requests

Keep pull requests focused. Include test coverage for classification or validation behavior and screenshots for visible UI changes.
Only submit work you have the right to license under GPL-3.0-only. Preserve existing
copyright notices and identify any third-party material and its license in the pull request.
