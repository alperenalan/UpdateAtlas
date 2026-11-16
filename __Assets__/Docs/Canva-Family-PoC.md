# Canva company desktop apps: proof of concept (2026-10-30)

Five separate, read-only probes live under `Apple/Proofs/CanvaFamily/`: `Affinity`,
`AffinityDesigner2`, `AffinityPhoto2`, `AffinityPublisher2`, and `CanvaDesktop`. They share only
metadata-reading code. No probe installs software, changes updater preferences, or starts an app.

| Product | Local observation | Release evidence and Update Atlas result |
| --- | --- | --- |
| Affinity by Canva | `/Applications/Affinity.app`, bundle `com.canva.affinity`, version 3.3.1, build 4940, team `5HD2ARTBFS`. Strict signature check passed with normal filesystem access. | The installed app's Sparkle preference points to `https://things.seriflabs.com/affinity-update-mac-retail-studiopro`; the public feed returned version 3.3.1/build 4940. [Homebrew Cask](https://formulae.brew.sh/api/cask/affinity.json) agreed. The bundled rule compares the appcast build first and uses the cask only if the feed fails. The app owns installation; Update Atlas has no eligible native Sparkle action because this bundle does not embed `SUFeedURL` and `SUPublicEDKey`. |
| Affinity Designer 2 | Not installed here | [Cask](https://formulae.brew.sh/api/cask/affinity-designer.json) is deprecated and frozen at 2.6.5/build 3782. [Canva says](https://www.affinity.studio/download) earlier Affinity products will receive no further updates. Keep the existing bundle identity but show unsupported, without a freshness check. |
| Affinity Photo 2 | Not installed here | [Cask](https://formulae.brew.sh/api/cask/affinity-photo.json) is deprecated at 2.6.5/build 3782. Same unsupported legacy handling. |
| Affinity Publisher 2 | Not installed here | [Cask](https://formulae.brew.sh/api/cask/affinity-publisher.json) is deprecated at 2.6.5/build 3782. Same unsupported legacy handling. |
| Canva Desktop | Not installed here | [Cask](https://formulae.brew.sh/api/cask/canva.json) tracks 1.126.2. [Canva documents](https://www.canva.com/en_gb/help/canva-desktop-app/) an in-app Update App confirmation. The existing `com.canva.CanvaDesktop` rule remains separate from Affinity and uses the cask for version comparison. Update Atlas does not trigger Canva's updater. |

All five catalog entries now use Canva as the publisher for presentation grouping. Their persisted
catalog IDs and bundle IDs stay unchanged. Catalog-matched Affinity 2 installations remain
discoverable, while their frozen cask versions can no longer produce a misleading Up to Date
result. An installation with a Mac App Store receipt is classified by the App Store path before
catalog matching; that path has not been changed here. If either the Affinity feed or a
Canva-family cask is behind an installed version, the check remains source pending.

The first Affinity signature check failed in the restricted shell; the same strict check passed
when repeated with normal filesystem access. The earlier result was an environment error. No
install or update action was attempted. The production web catalog remains revision 14. This
worktree's bundled catalog is revision 16/366 and has not been published or built into an app.
