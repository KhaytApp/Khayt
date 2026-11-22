'use strict';
/**
 * The right-click menu, and the spellchecker behind it.
 *
 * Electron ships NO default context menu. Chromium still spellchecks and still
 * draws the red underline, so a shop typing a product description saw its
 * mistakes marked and had no way to reach a correction — right-click did
 * nothing at all. Reported exactly that way: "I get spelling errors highlighted
 * but I can't right click to get the correct spelling?"
 *
 * The same absence costs more than spelling: there was no Cut, Copy, Paste or
 * Select All anywhere in the app either. On macOS the keyboard shortcuts work
 * from the application menu, so this reads as a small omission; on Windows and
 * Linux, right-click IS how people copy text.
 *
 * ── The part that matters for an Arabic shop ────────────────────────────────
 * Chromium has NO ARABIC DICTIONARY. Checked against this Electron build:
 * `availableSpellCheckerLanguages` contains six English variants and no `ar` at
 * all — nor Japanese or Chinese. The default is `en-GB`, chosen by Chromium and
 * never told what language the app is in.
 *
 * So a shop writing Arabic had EVERY WORD underlined by an English dictionary,
 * with no menu to dismiss any of it. That is not a spellchecker being unhelpful,
 * it is a wall of red under correct text.
 *
 * Hence `applyLanguage`: on Windows and Linux, match the app's language to a
 * Chromium dictionary where one exists and TURN SPELLCHECK OFF where none does.
 * Off is the honest state — an underline that cannot be right is worse than no
 * underline, and a suggestion list built from the wrong language would be worse
 * still.
 *
 * macOS is left alone, deliberately: it uses NSSpellChecker, which picks the
 * language itself and DOES support Arabic. Applying the rule above there would
 * have disabled a spellchecker that was working correctly.
 *
 * Pure-ish: takes Electron's pieces as arguments so the menu construction can be
 * exercised without a window.
 */

/** Languages Khayt ships, mapped to the dictionary to prefer when one exists. */
const PREFERRED = {
  en: ['en-GB', 'en-US', 'en'],
  ar: [],          // Chromium has no Arabic dictionary
  de: ['de-DE', 'de'],
  es: ['es-ES', 'es'],
  fr: ['fr-FR', 'fr'],
  tr: ['tr'],
  ja: [],          // none
  zh: [],          // none
};

/**
 * Pick the dictionary for an app language, or null when there is none.
 * @returns {string|null}
 */
function dictionaryFor(lang, available) {
  const avail = Array.isArray(available) ? available : [];
  const want = PREFERRED[String(lang || 'en').toLowerCase().slice(0, 2)] || [];
  for (const code of want) if (avail.includes(code)) return code;
  return null;
}

/**
 * Point the session's spellchecker at the app's language, or switch it off.
 *
 * Returns what it did so the caller can log or test it, rather than being a
 * void function whose effect can only be observed by typing.
 */
function applyLanguage(session, lang, platform) {
  if (!session) return { enabled: false, language: null, reason: 'no session' };
  const plat = platform || (typeof process !== 'undefined' ? process.platform : '');

  /* macOS IS A DIFFERENT MACHINE HERE, and getting this wrong would have made
   * things worse rather than better.
   *
   * Electron delegates to NSSpellChecker on macOS: `setSpellCheckerLanguages`
   * is a SILENT no-op — verified, no error and no change — because the OS picks
   * the language itself, per-field, as you type. And NSSpellChecker supports
   * Arabic, which Chromium does not.
   *
   * So the disable branch below, written for Chromium's missing dictionaries,
   * would have switched OFF a spellchecker that was working correctly for the
   * exact language it was meant to protect. On macOS the right move is to leave
   * it alone.
   */
  if (plat === 'darwin') {
    return { enabled: true, language: 'os', reason: 'macOS uses the system spellchecker, which picks its own language' };
  }

  let available = [];
  try { available = session.availableSpellCheckerLanguages || []; } catch (e) { available = []; }
  const dict = dictionaryFor(lang, available);
  try {
    if (!dict) {
      // No dictionary for this language. Underlining it with another language's
      // is not a degraded service, it is a wrong answer on every word.
      session.setSpellCheckerEnabled(false);
      return { enabled: false, language: null, reason: 'no dictionary for ' + lang };
    }
    session.setSpellCheckerEnabled(true);
    session.setSpellCheckerLanguages([dict]);
    return { enabled: true, language: dict, reason: 'ok' };
  } catch (e) {
    return { enabled: false, language: null, reason: String((e && e.message) || e) };
  }
}

/**
 * Build the menu template for one right-click.
 *
 * Separated from `attach` so the shape can be asserted without spawning a
 * window — the reason the missing menu went unnoticed is that nothing could
 * look at it.
 *
 * @param {object} params  Electron's context-menu params
 * @param {object} deps    { replaceMisspelling, addToDictionary, t }
 */
function buildTemplate(params, deps) {
  const p = params || {};
  const d = deps || {};
  const t = typeof d.t === 'function' ? d.t : (_k, fallback) => fallback;
  const flags = p.editFlags || {};
  const items = [];

  // Suggestions first: the shop right-clicked a red underline to fix a word, so
  // the fix goes where the pointer already is rather than below Cut and Copy.
  const suggestions = Array.isArray(p.dictionarySuggestions) ? p.dictionarySuggestions : [];
  if (p.misspelledWord) {
    if (suggestions.length) {
      for (const word of suggestions.slice(0, 5)) {
        items.push({ label: word, click: () => d.replaceMisspelling && d.replaceMisspelling(word) });
      }
    } else {
      // A misspelling Chromium cannot suggest for is still worth acknowledging:
      // an empty menu reads as a broken right-click, which is what was reported.
      items.push({ label: t('menu.no_suggestions', 'No suggestions'), enabled: false });
    }
    items.push({ type: 'separator' });
    items.push({
      label: t('menu.add_to_dictionary', 'Add to dictionary'),
      click: () => d.addToDictionary && d.addToDictionary(p.misspelledWord),
    });
    items.push({ type: 'separator' });
  }

  // The ordinary editing verbs, gated on what is actually possible here so the
  // menu never offers Paste over a label or Copy with nothing selected.
  if (p.isEditable || p.selectionText) {
    items.push({ label: t('menu.cut', 'Cut'), role: 'cut', enabled: !!flags.canCut });
    items.push({ label: t('menu.copy', 'Copy'), role: 'copy', enabled: !!flags.canCopy });
    items.push({ label: t('menu.paste', 'Paste'), role: 'paste', enabled: !!flags.canPaste });
    items.push({ type: 'separator' });
    items.push({ label: t('menu.select_all', 'Select all'), role: 'selectAll', enabled: !!flags.canSelectAll });
  }

  return items;
}

/**
 * Attach the handler to a window's webContents.
 *
 * @param {object} win        BrowserWindow
 * @param {object} electron   { Menu }
 * @param {function} translate optional (key, fallback) => string
 */
function attach(win, electron, translate) {
  if (!win || !win.webContents || !electron || !electron.Menu) return false;
  win.webContents.on('context-menu', (_event, params) => {
    const template = buildTemplate(params, {
      replaceMisspelling: (w) => win.webContents.replaceMisspelling(w),
      addToDictionary: (w) => win.webContents.session.addWordToSpellCheckerDictionary(w),
      t: translate,
    });
    // Nothing worth showing — a right-click on empty chrome. Showing an empty
    // menu would be its own small bug.
    if (!template.length) return;
    electron.Menu.buildFromTemplate(template).popup({ window: win });
  });
  return true;
}

module.exports = { PREFERRED, dictionaryFor, applyLanguage, buildTemplate, attach };
