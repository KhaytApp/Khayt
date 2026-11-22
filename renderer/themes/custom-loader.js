/**
 * Registers the themes a shop has installed.
 *
 * TWO PLACES, FOR ONE REASON
 *
 * A custom theme can live in two places, and only one of them a user can reach.
 *
 *   themes/custom/    inside the app. Fetchable, and read-only: it is inside
 *                     app.asar and replaced whole on every update. Useful when
 *                     running from source, useless to anybody who installed
 *                     Khayt — which is why its index has always read
 *                     {"themes": []}.
 *
 *   userData/themes/  where an installed theme actually goes. Writable, and it
 *                     survives an update because the installer does not own it.
 *
 * The second cannot be fetched. It is outside the app's origin, and the CSP that
 * stops a stray <link> reaching the network stops it reaching the disk as well —
 * correctly, because "the renderer may read arbitrary local files" is not a
 * property worth trading for a stylesheet. So its CSS comes over IPC as text and
 * is injected as a <style> element.
 *
 * The bundled path stays, unchanged, because it is how a theme is developed.
 */
(function (global) {
  const INDEX_PATH = 'themes/custom/index.json';

  /** Themes bundled with the app — developer route, fetched and linked. */
  async function loadBundledThemes(reg) {
    const loaded = [];
    try {
      const res = await fetch(INDEX_PATH, { cache: 'no-cache' });
      if (!res.ok) return loaded;
      const data = await res.json();
      for (const entry of data.themes || []) {
        const folder = entry.folder || entry.id;
        const manifestRes = await fetch(`themes/custom/${folder}/manifest.json`, { cache: 'no-cache' });
        if (!manifestRes.ok) continue;
        const result = reg.registerCustomTheme(await manifestRes.json(), 'themes/custom');
        if (result.ok) loaded.push(result.id);
      }
    } catch (e) {
      console.warn('[themes] bundled theme load failed', e);
    }
    return loaded;
  }

  /** Themes the shop installed — the real route, read over IPC and injected. */
  async function loadInstalledThemes(reg) {
    const api = global.hubAPI;
    if (!api || typeof api.themesList !== 'function') return [];
    const loaded = [];
    try {
      const listing = await api.themesList();
      for (const t of (listing && listing.themes) || []) {
        // A theme whose manifest will not parse is listed so it can be removed,
        // and skipped so it cannot be applied. Both, deliberately: hiding it
        // would leave the owner with something they cannot delete.
        if (t.broken) continue;
        const read = await api.themesRead({ id: t.id });
        if (!read || !read.ok) {
          // The main process re-checks the CSS on every read, so this is the
          // path a theme takes when it was edited on disk after being installed.
          console.warn(`[themes] "${t.id}" was not loaded:`, read && read.error);
          continue;
        }
        const result = reg.registerCustomTheme(read.manifest, null, read.css);
        if (result.ok) loaded.push(result.id);
      }
    } catch (e) {
      console.warn('[themes] installed theme load failed', e);
    }
    return loaded;
  }

  /**
   * Never throws. A theme that will not load must cost the shop a design, not
   * the app: this runs during boot, and an exception here would take the whole
   * renderer down over somebody's stylesheet.
   */
  async function loadCustomThemes() {
    const reg = global.KhaytThemeRegistry;
    if (!reg) return [];
    const bundled = await loadBundledThemes(reg);
    const installed = await loadInstalledThemes(reg);
    return bundled.concat(installed);
  }

  global.KhaytCustomThemes = { loadCustomThemes, loadBundledThemes, loadInstalledThemes };
})(typeof window !== 'undefined' ? window : globalThis);
