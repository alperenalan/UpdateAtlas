# Security Policy

## Reporting a vulnerability

Please do not publish exploitable details in a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/alperenalan/UpdateAtlas/security/advisories/new)
or email [hi@alperenalan.com](mailto:hi@alperenalan.com). Do not attach personal software
inventories or credentials to a public issue.

## Security boundaries

Update Atlas treats remote catalogs as untrusted data. Catalogs may describe identities, versions, HTTPS sources, and ownership relationships, but must never carry commands or executable installation recipes.

The app performs read-only scans. Explicit GUI actions can request updates for a narrowly
verified Sparkle app, Homebrew-owned package or supported Microsoft AutoUpdate app; App Store
items open their matched product page. These paths must recheck identity and ownership before
asking the original updater or package manager to act. The official remote catalog is data-only
and cannot add arbitrary commands or installation recipes.

Supported security fixes target the latest released version.
