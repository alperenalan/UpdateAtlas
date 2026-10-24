# Update Atlas website

The static product site at <https://updateatlas.alperenalan.com/>. It also serves the two files
installed apps depend on:

- `site/appcast.xml` — the signed Sparkle feed for Update Atlas's own updates.
- `site/api/update-atlas/catalog-v1.json` — the public, data-only software catalog the app
  downloads at launch and every six hours.

Cloudflare Pages (project `updateatlas-git`) builds this folder from `main`: repository root
`Web`, output directory `site`. A push to `main` that changes anything under `Web/**` deploys to
production automatically; preview deployments are off, and pushes outside `Web/` do not build.
The build command validates the catalog contract, checks that the generated pages are current,
checks site translation reviews and runs the public-tree scan; any failure stops the deployment
and the previous site stays live.

## Editing the pages

The seven locale pages (`en`, `tr`, `ru`, `de`, `fr`, `zh-Hans`, `ja`) and their privacy pages are
generated. Edit the copy in `site_copy.psv` (one row per key, one column per language) or the
template in `generate_site.py`, then run:

```sh
python3 Web/generate_site.py            # write the pages
python3 Web/generate_site.py --check    # fail if a committed page is stale
python3 Web/generate_site.py --launch-preview .temporary_files/site-preview   # every launch switch on
python3 -m http.server 8765 --directory Web/site
```

`PUBLIC_REPO`, `RELEASED`, `SPONSORS` and `BREW` at the top of `generate_site.py` turn on the
GitHub, download, GitHub Sponsors and Homebrew elements once each destination exists. Asset links
carry a content hash so a fresh page never mixes with a cached stylesheet. The site has no
analytics, cookies or third-party scripts; the language and theme choices stay in local storage.

App screenshots live in `site/assets/shots/` as `main-light.png`/`main-dark.png` and
`menubar-light.png`/`menubar-dark.png`; a pair is shown only when both files exist.

## Publishing a catalog revision

Every published snapshot must raise `revision` and keep every existing entry ID. Stage and
validate it with `__Assets__/Scripts/Apple/stage_channel.py`, copy the staged catalog and its
contract into `Web/`, deploy, then compare the live bytes with the staged SHA-256. See the
[catalog guide](../__Assets__/Docs/catalog.md). The local [catalog editor](catalog-editor/README.md)
helps prepare a candidate; it never publishes.
