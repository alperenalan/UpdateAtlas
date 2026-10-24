(function () {
  "use strict";
  const supported = new Set(["en", "tr", "ru", "de", "fr", "zh-Hans", "ja"]);
  const storage = {
    get(key) {
      try { return localStorage.getItem(key); } catch (_) { return null; }
    },
    set(key, value) {
      try { localStorage.setItem(key, value); } catch (_) { /* private mode */ }
    }
  };
  function languageFor(value) {
    const code = String(value || "").toLowerCase();
    if (code === "zh-tw" || code === "zh-hk" || code === "zh-mo" || code === "zh-hant") return null;
    if (code.startsWith("zh")) return "zh-Hans";
    const primary = code.split("-")[0];
    return supported.has(primary) ? primary : null;
  }
  function chooseLanguage(preferences) {
    for (const preference of preferences) {
      const match = languageFor(preference);
      if (match) return match;
    }
    return "en";
  }
  const theme = storage.get("updateatlas-theme");
  if (theme === "dark" || theme === "light") document.documentElement.dataset.theme = theme;
  for (const link of document.querySelectorAll("[data-set-locale]")) {
    link.addEventListener("click", () => storage.set("updateatlas-locale", link.dataset.setLocale));
  }
  const toggle = document.querySelector(".theme-toggle");
  if (toggle) {
    toggle.addEventListener("click", () => {
      const active = document.documentElement.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      const next = active === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      storage.set("updateatlas-theme", next);
    });
  }
  if (location.pathname === "/" || location.pathname === "/index.html") {
    const saved = storage.get("updateatlas-locale");
    const preferences = saved && supported.has(saved) ? [saved] : (navigator.languages || [navigator.language]);
    const locale = chooseLanguage(preferences);
    location.replace("/" + locale + "/" + location.search + location.hash);
  }
  if (typeof module !== "undefined") module.exports = { languageFor, chooseLanguage };
})();
