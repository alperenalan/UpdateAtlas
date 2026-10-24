#!/usr/bin/env python3
"""Generate the seven static product pages from reviewed, local copy."""

from __future__ import annotations

import hashlib
import html
import argparse
import shutil
from pathlib import Path


HERE = Path(__file__).resolve().parent
SITE = HERE / "site"
def load_copy() -> dict[str, dict[str, str]]:
    rows = (HERE / "site_copy.psv").read_text(encoding="utf-8").splitlines()
    columns = rows[0].split("|")
    assert columns == ["key", "en", "tr", "ru", "de", "fr", "zh-Hans", "ja"]
    data = {language: {} for language in columns[1:]}
    for line in rows[1:]:
        if not line.strip():
            continue
        cells = line.split("|")
        assert len(cells) == len(columns), f"bad translation row: {cells[0]}"
        key = cells[0]
        for language, value in zip(columns[1:], cells[1:]):
            assert value.strip(), f"empty translation: {language}/{key}"
            data[language][key] = value
    return data


COPY = load_copy()
LANGUAGES = {
    "en": "English",
    "tr": "Türkçe",
    "ru": "Русский",
    "de": "Deutsch",
    "fr": "Français",
    "zh-Hans": "简体中文",
    "ja": "日本語",
}
BASE = "https://updateatlas.alperenalan.com"
GITHUB = "https://github.com/alperenalan/UpdateAtlas"
# Launch switches. Turn each on only once its destination really exists, so the
# site never links to a private repository, an empty release or an inactive profile.
PUBLIC_REPO = True
RELEASED = True
SPONSORS = False
# Every GitHub Release carries this stable asset name, so /latest/download/ resolves.
DOWNLOAD = f"{GITHUB}/releases/latest/download/Update-Atlas.dmg"
BREW = ""  # for example "brew install --cask alperenalan/tap/update-atlas", once the tap exists
CREATOR = "https://alperenalan.com/"
COFFEE = "https://buymeacoffee.com/alperenalan"
SPONSORS_URL = "https://github.com/sponsors/alperenalan"
SHOTS = SITE / "assets" / "shots"

ICONS = {
    "stack": '<path d="M12 3 3 7.5l9 4.5 9-4.5L12 3Z"/><path d="m3 12 9 4.5 9-4.5"/><path d="m3 16.5 9 4.5 9-4.5"/>',
    "seal": '<path d="M12 2.8 14.4 5l3.2-.4.6 3.2 2.8 1.6-1.4 2.9 1.4 2.9-2.8 1.6-.6 3.2-3.2-.4L12 21.2 9.6 19l-3.2.4-.6-3.2L3 14.6l1.4-2.9L3 8.8l2.8-1.6.6-3.2 3.2.4L12 2.8Z"/><path d="m8.6 12 2.3 2.3 4.5-4.6"/>',
    "arrow": '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v9"/><path d="m8 12.5 4 4 4-4"/>',
    "menubar": '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 8.5h18"/><path d="M16.5 6.2h1.5"/>',
    "tree": '<rect x="3" y="3.5" width="7" height="6" rx="1.5"/><rect x="14" y="10" width="7" height="5" rx="1.5"/><rect x="14" y="17" width="7" height="4" rx="1.5"/><path d="M6.5 9.5v9h7.5"/><path d="M6.5 12.5h7.5"/>',
    "lock": '<rect x="4.5" y="10.5" width="15" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
    "heart": '<path d="M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.2a4.3 4.3 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20Z"/>',
}
GITHUB_MARK = (
    '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path fill="currentColor" '
    'd="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94'
    '-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07'
    '-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0'
    ' 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54'
    '.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>'
)


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def icon(name: str) -> str:
    return ('<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">{ICONS[name]}</svg>')


def current_attribute(code: str, selected: str) -> str:
    return ' aria-current="page"' if code == selected else ""


def shot(name: str, alt: str, css: str) -> str:
    """A light/dark screenshot pair, omitted until both captures exist."""
    light, dark = SHOTS / f"{name}-light.png", SHOTS / f"{name}-dark.png"
    if not (light.exists() and dark.exists()):
        return ""
    width, height = png_size(light)
    return (f'<figure class="{css}"><picture>'
            f'<source srcset="../assets/shots/{name}-dark.png" media="(prefers-color-scheme: dark)" />'
            f'<img src="../assets/shots/{name}-light.png" alt="{alt}" width="{width}" height="{height}" decoding="async" />'
            '</picture></figure>')


def png_size(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[16:24]
    return int.from_bytes(header[:4], "big"), int.from_bytes(header[4:], "big")


def render(lang: str, t: dict[str, str], css_hash: str, base_hash: str, tokens_hash: str, js_hash: str,
           page: str = "home") -> str:
    def x(key: str) -> str:
        return esc(t[key])

    language_links = "".join(
        f'<a href="/{code}/{"" if page == "home" else page + "/"}" hreflang="{code}" lang="{code}" data-set-locale="{code}"'
        f'{current_attribute(code, lang)}>{esc(name)}</a>'
        for code, name in LANGUAGES.items()
    )
    suffix = "" if page == "home" else f"{page}/"
    alternates = "\n".join(
        f'  <link rel="alternate" hreflang="{code}" href="{BASE}/{code}/{suffix}" />' for code in LANGUAGES
    )
    privacy = f"/{lang}/privacy/"

    nav_github = f'<a href="{GITHUB}">GitHub</a>' if PUBLIC_REPO else ""
    primary = (f'<a class="button button-primary" href="{DOWNLOAD}">{icon("arrow")}{x("download")}</a>'
               if RELEASED else "")
    secondary = (f'<a class="button button-secondary" href="{GITHUB}">{GITHUB_MARK}{x("github")}</a>'
                 if PUBLIC_REPO else "")
    actions = f'<div class="actions">{primary}{secondary}</div>' if primary or secondary else ""
    soon = "" if RELEASED else f'<p class="hero-soon">{x("coming_soon")}</p>'
    brew = (f'<div class="brew"><span>{x("brew_label")}</span><code translate="no">{esc(BREW)}</code>'
            f'<button type="button" class="copy" data-copy="{esc(BREW)}" data-copied="{x("copied")}">{x("copy")}</button></div>'
            if BREW and RELEASED else "")

    features = "".join(
        f'<li class="feature">{icon(name)}<h3>{x(f"f{n}_title")}</h3><p>{x(f"f{n}_body")}</p></li>'
        for n, name in enumerate(("stack", "seal", "arrow", "menubar", "tree", "lock"), start=1)
    )
    faq = "".join(f'<details><summary>{x(f"q{n}")}</summary><p>{x(f"a{n}")}</p></details>' for n in range(1, 6))
    support_buttons = "".join(filter(None, [
        f'<a class="button button-primary" href="{SPONSORS_URL}">{icon("heart")}{x("sponsor_github")}</a>' if SPONSORS else "",
        f'<a class="button {"button-secondary" if SPONSORS else "button-primary"}" href="{COFFEE}">{x("sponsor_coffee")}</a>',
        f'<a class="button button-secondary" href="{GITHUB}">{GITHUB_MARK}{x("star_github")}</a>' if PUBLIC_REPO else "",
    ]))
    footer_links = "".join(filter(None, [
        f'<a href="{privacy}">{x("privacy_link")}</a>',
        f'<a href="{GITHUB}/blob/main/LICENSE">{x("license")}</a>' if PUBLIC_REPO else "",
        f'<a href="{GITHUB}">{x("source")}</a>' if PUBLIC_REPO else "",
    ]))
    main_shot = shot("main", x("shot_alt"), "screenshot")
    menu_shot = shot("menubar", x("menubar_alt"), "side-shot")
    cli = ('<span class="prompt">$ </span>update-atlas check --updates-only\n'
           '<span class="prompt">$ </span>update-atlas scan --offline | jq \'.summary\'\n'
           '<span class="prompt">$ </span>update-atlas skill &gt; SKILL.md')
    solo = "" if menu_shot else " split-solo"
    up = "../" if page == "home" else "../../"
    home_main = f"""  <main id="main">
    <section class="hero">
      <div class="container hero-inner">
        <img class="hero-icon" src="{up}assets/update-atlas-icon.png" alt="" width="128" height="128" />
        <h1>{x('hero_title')}</h1>
        <p class="lead">{x('hero_body')}</p>
        {actions}{soon}
        <p class="hero-note">{x('download_note')}</p>
        {brew}
      </div>
      <div class="container">{main_shot}</div>
    </section>
    <section id="features" class="features"><div class="container">
      <div class="section-head"><h2>{x('features_title')}</h2><p>{x('features_body')}</p></div>
      <ul class="feature-grid">{features}</ul>
    </div></section>
    <section class="split"><div class="container split-inner{solo}">
      <div class="split-copy"><h2>{x('menubar_title')}</h2><p>{x('menubar_body')}</p></div>
      {menu_shot}
    </div></section>
    <section class="split split-cli"><div class="container split-inner">
      <div class="split-copy"><h2>{x('cli_title')}</h2><p>{x('cli_body')}</p></div>
      <pre class="terminal" translate="no"><code>{cli}</code></pre>
    </div></section>
    <section id="support" class="support"><div class="container support-inner">
      <h2>{x('oss_title')}</h2>
      <p>{x('oss_body')}</p>
      <div class="actions">{support_buttons}</div>
    </div></section>
    <section id="faq" class="faq"><div class="container faq-inner">
      <h2>{x('faq_title')}</h2>
      <div class="faq-list">{faq}</div>
    </div></section>
  </main>
"""
    privacy_main = f"""  <main id="main" class="legal"><div class="container legal-inner">
    <h1>{x('privacy_title')}</h1>
    <p class="legal-updated">{x('privacy_updated')}</p>
    <p class="lead">{x('privacy_intro')}</p>
    {"".join(f"<h2>{x(f'p_{k}_title')}</h2><p>{x(f'p_{k}_body')}</p>" for k in ("local", "network", "catalog", "never", "site", "contact"))}
    <p><a class="text-link" href="/{lang}/">{x('back_home')}</a></p>
  </div></main>
"""
    home = "" if page == "home" else f"/{lang}/"
    main = home_main if page == "home" else privacy_main
    title = f"Update Atlas: {t['hero_title']}" if page == "home" else f"{t['privacy_title']}: Update Atlas"
    title = esc(title)
    description = x("meta") if page == "home" else x("privacy_intro")
    return f"""<!doctype html>
<html lang="{lang}">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="{description}" />
  <meta name="theme-color" content="#f5f5f7" media="(prefers-color-scheme: light)" />
  <meta name="theme-color" content="#111113" media="(prefers-color-scheme: dark)" />
  <meta property="og:type" content="website" />
  <meta property="og:site_name" content="Update Atlas" />
  <meta property="og:title" content="{title}" />
  <meta property="og:description" content="{description}" />
  <meta property="og:url" content="{BASE}/{lang}/{suffix}" />
  <meta property="og:image" content="{BASE}/assets/update-atlas-icon.png" />
  <meta name="twitter:card" content="summary" />
  <link rel="canonical" href="{BASE}/{lang}/{suffix}" />
{alternates}
  <link rel="alternate" hreflang="x-default" href="{BASE}/en/{suffix}" />
  <link rel="icon" type="image/png" href="{up}assets/update-atlas-icon.png" />
  <link rel="apple-touch-icon" href="{up}assets/update-atlas-icon.png" />
  <link rel="stylesheet" href="{up}tokens.css?v={tokens_hash}" />
  <link rel="stylesheet" href="{up}base.css?v={base_hash}" />
  <link rel="stylesheet" href="{up}styles.css?v={css_hash}" />
  <script defer src="/site.js?v={js_hash}"></script>
  <title>{title}</title>
</head>
<body>
  <a class="skip-link" href="#main">{x('skip')}</a>
  <header class="site-header"><div class="container header-inner">
    <a class="brand" href="/{lang}/"><img src="{up}assets/update-atlas-icon.png" alt="" width="28" height="28" />Update Atlas</a>
    <nav class="header-links" aria-label="{x('nav_label')}"><a href="{home}#features">{x('nav_features')}</a><a href="{home}#faq">{x('nav_faq')}</a>{nav_github}<a class="nav-support" href="{home}#support">{icon("heart")}<span>{x('nav_support')}</span></a></nav>
    <div class="header-controls">
      <button class="theme-toggle" type="button" aria-label="{x('theme_toggle')}" title="{x('theme_toggle')}"><svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor"/></svg></button>
      <details class="language-menu"><summary aria-label="{x('language_label')}"><span class="language-name">{esc(LANGUAGES[lang])}</span><span class="language-code" aria-hidden="true">{lang.split('-')[0].upper()}</span><svg viewBox="0 0 12 12" aria-hidden="true" focusable="false"><path d="m3 4.5 3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></summary><div class="language-options">{language_links}</div></details>
    </div>
  </div></header>
{main}  <footer class="footer"><div class="container footer-inner">
    <div class="footer-brand"><img src="{up}assets/update-atlas-icon.png" alt="" width="20" height="20" />Update Atlas</div>
    <p><a href="{CREATOR}">{x('footer_made')}</a></p>
    <nav class="footer-links" aria-label="Update Atlas">{footer_links}</nav>
  </div></footer>
</body></html>
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if committed pages need regeneration")
    parser.add_argument("--launch-preview", type=Path, metavar="DIR",
                        help="render a copy with every launch switch on into DIR, for review only")
    args = parser.parse_args()
    if args.launch_preview:
        global PUBLIC_REPO, RELEASED, SPONSORS, BREW
        PUBLIC_REPO = RELEASED = SPONSORS = True
        BREW = BREW or "brew install --cask alperenalan/tap/update-atlas"
        shutil.rmtree(args.launch_preview, ignore_errors=True)
        shutil.copytree(SITE, args.launch_preview)
    assert set(COPY) == set(LANGUAGES)
    keys = set(COPY["en"])
    for language, strings in COPY.items():
        assert set(strings) == keys, f"missing copy in {language}: {keys ^ set(strings)}"
    css_hash = hashlib.sha256((SITE / "styles.css").read_bytes()).hexdigest()[:12]
    base_hash = hashlib.sha256((SITE / "base.css").read_bytes()).hexdigest()[:12]
    tokens_hash = hashlib.sha256((SITE / "tokens.css").read_bytes()).hexdigest()[:12]
    js_hash = hashlib.sha256((SITE / "site.js").read_bytes()).hexdigest()[:12]
    for language, strings in COPY.items():
        dest = (args.launch_preview or SITE) / language / "index.html"
        for page, target in (("home", dest), ("privacy", dest.parent / "privacy" / "index.html")):
            output = render(language, strings, css_hash, base_hash, tokens_hash, js_hash, page)
            if args.check:
                assert target.read_text(encoding="utf-8") == output, f"stale page: {target}"
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(output, encoding="utf-8")
    root = (HERE / "root.html").read_text(encoding="utf-8")
    root = root.replace("{{CSS_HASH}}", css_hash).replace("{{BASE_HASH}}", base_hash).replace("{{TOKENS_HASH}}", tokens_hash).replace("{{JS_HASH}}", js_hash)
    if args.check:
        assert (SITE / "index.html").read_text(encoding="utf-8") == root, "stale root page"
    else:
        (SITE / "index.html").write_text(root, encoding="utf-8")


if __name__ == "__main__":
    main()
