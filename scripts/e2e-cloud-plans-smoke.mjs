#!/usr/bin/env node
/**
 * E2E: the Khayt Cloud price ladder renders, and says the right thing.
 *
 * lib/cloud-plans.js is unit-tested, but a plan table that no screen ever paints
 * is worth nothing — and the specific failure this guards is one a unit test
 * cannot see: settings.js is shared with the other flavor, so the module is
 * loaded from renderer/index.html only and every use is guarded on the global.
 * Drop the script tag and the unit tests still pass while the section silently
 * renders empty.
 *
 * It also pins the two claims the UI is making to a shop:
 *
 *   1. Paid prices are STRUCK THROUGH and accompanied by "Free during beta".
 *      Rendering a live price while nothing can collect it would be a lie in the
 *      expensive direction.
 *   2. The struck-through figure is still the real one. "Free during beta" that
 *      hides the future price defeats the point of showing it early.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { applyDesignTheme, dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

/**
 * The cloud card lives inside the "online" panel, not a panel of its own —
 * so drive the app's own navigation rather than guessing a selector, which is
 * how this was wrong the first time.
 */
async function openCloudPanel(window) {
  await switchTab(window, 'settings-tab');
  // The cloud card sits in the "online" panel and carries .pro-only itself — in any
  // other mode the panel is display:none even once it is the active one. The
  // wizard does not leave a fresh profile in Professional, so ask for it.
  await window.evaluate(() => {
    settings.mode = 'professional';
    applyMode();
    renderCloudSettings();
    // Khayt Cloud lives under `online` — it moved out of `automation`, which is
    // for WhatsApp templates and scheduled email rather than the online surface.
    openSettingsSection('online');
  });
  await window.waitForSelector('#cloudSettingsSection');
  await window.waitForFunction(() =>
    document.querySelector('#cloudSettingsSection')?.innerText.includes('Khayt Cloud'));
}

/** Read the rendered ladder back out of the DOM, not out of the module. */
const readLadder = (window) => window.evaluate(() => {
  const sec = document.querySelector('#cloudSettingsSection');
  const cards = [...sec.querySelectorAll('div')].filter((d) => d.querySelector('ul') && d.querySelector('s, span'));
  return {
    text: sec.innerText,
    struck: [...sec.querySelectorAll('s')].map((s) => s.textContent.trim()),
    cardCount: cards.length,
  };
});

async function testLadderRenders(window) {
  const { text, struck } = await readLadder(window);

  // The module is loaded at all — the guarded-global failure mode.
  const loaded = await window.evaluate(() => typeof KhaytCloudPlans !== 'undefined');
  if (!loaded) throw new Error('KhaytCloudPlans is not loaded in index.html — the section renders empty');

  for (const tier of ['Free', 'Maker', 'Creator', 'Studio']) {
    if (!text.includes(tier)) throw new Error(`the "${tier}" tier is not on screen`);
  }
  if (!text.includes('Free during beta')) {
    throw new Error('"Free during beta" is missing — a shop cannot tell it is not being charged');
  }
  if (text.includes('Not built yet')) {
    throw new Error('a tier says it is unbuilt, but every tier is live on the cloud');
  }
  return struck;
}

/** The prices shown must be the real ones, struck through — not hidden, not live. */
async function testPricesAreStruckThroughAndReal(window, struck) {
  if (struck.length !== 3) {
    throw new Error(`expected exactly 3 struck-through prices (maker + creator + studio), got ${struck.length}: ${struck.join(', ')}`);
  }
  const expected = await window.evaluate(() =>
    ['maker', 'creator', 'studio'].map((id) => {
      const p = KhaytCloudPlans.planPrice(id, settings.currency);
      return p.currency === 'USD' ? `$${p.amount}` : `${p.amount} ${p.currency}`;
    }));
  for (const want of expected) {
    if (!struck.includes(want)) {
      throw new Error(`price ${want} is not struck through on screen; struck = ${struck.join(', ')}`);
    }
  }
  // Free is never struck through: there is no future price to reveal.
  if (struck.some((s) => /^\D*0\b/.test(s))) {
    throw new Error(`a zero price is struck through, which implies it will start costing: ${struck.join(', ')}`);
  }
}

/**
 * The prices must follow the shop's currency, because a Saudi shop reading "$7"
 * has to do arithmetic to know what it will pay.
 */
async function testCurrencyFollowsTheShop(window) {
  for (const [currency, want] of [['SAR', '25 SAR'], ['USD', '$7']]) {
    await window.evaluate((cur) => { settings.currency = cur; renderCloudSettings(); }, currency);
    const { struck } = await readLadder(window);
    if (!struck.includes(want)) {
      throw new Error(`with currency=${currency} the Maker tier should read "${want}"; struck = ${struck.join(', ')}`);
    }
  }
}

/**
 * The beta.18 low-stock regression shipped because a token was a hex literal and
 * only the default dark theme was ever rendered. This block uses --success and
 * --warning, neither of which every theme defines, so paint it in a LIGHT theme
 * and assert the text colour is the theme's normal foreground rather than a
 * colour token used directly as text.
 */
async function testLightThemeDoesNotColourTheText(window) {
  await applyDesignTheme(window, { designId: 'flow', appearance: 'light' });
  await window.evaluate(() => renderCloudSettings());

  const bad = await window.evaluate(() => {
    const sec = document.querySelector('#cloudSettingsSection');
    const body = getComputedStyle(document.body).color;
    const out = [];
    for (const el of sec.querySelectorAll('div, span, s')) {
      if (!el.textContent.trim()) continue;
      const c = getComputedStyle(el).color;
      // #f5a623 / #16a34a used directly as text is the failure mode.
      if (/^rgb\(245, 166, 35\)$/.test(c) || /^rgb\(22, 163, 74\)$/.test(c)) {
        out.push({ text: el.textContent.trim().slice(0, 40), color: c, body });
      }
    }
    return out;
  });
  if (bad.length) {
    throw new Error('colour tokens are used as TEXT colour in a light theme: ' + JSON.stringify(bad));
  }
}

/**
 * The portal trial must not bite during beta — in the running app, not just in
 * a unit test.
 *
 * The failure this guards is a whole class: ship a correct countdown, and every
 * shop quietly loses a working feature. Both halves are checked, because they
 * fail independently — the gate could refuse while the banner stays hidden, or
 * the clock could start silently and only expire 30 days later, long after
 * anyone would connect it to this release.
 */
async function testTrialDoesNotBiteDuringBeta(window) {
  const loaded = await window.evaluate(() => typeof KhaytPortalTrial !== 'undefined');
  if (!loaded) throw new Error('KhaytPortalTrial is not loaded in index.html');

  const state = await window.evaluate(() => {
    settings.cloud = settings.cloud || {};
    return KhaytPortalTrial.portalTrialState({
      betaFree: KhaytCloudPlans.isBetaFree(),
      subscribed: false,
      startedAt: settings.cloud.portalTrialStartedAt || null,
      now: Date.now(),
    });
  });
  if (state.state !== 'beta') throw new Error(`trial state is "${state.state}", expected "beta"`);
  if (state.available !== true) throw new Error('the portal is not available during beta');

  // The gate says yes, and — the part that would go unnoticed — starts no clock.
  const gate = await window.evaluate(() => {
    delete settings.cloud.portalTrialStartedAt;
    const allowed = portalTrialAllows();
    return { allowed, startedAt: settings.cloud.portalTrialStartedAt || null };
  });
  if (!gate.allowed) throw new Error('publishing is blocked during beta — this removes a working feature');
  if (gate.startedAt) {
    throw new Error(`beta publishing started the trial clock (${gate.startedAt}); a year of beta would leave a shop expired on day one of billing`);
  }

  // And no banner, because the plans block below already says free during beta.
  const text = await window.evaluate(() => {
    renderCloudSettings();
    return document.querySelector('#cloudSettingsSection').innerText;
  });
  if (/trial/i.test(text) && /days left/i.test(text)) {
    throw new Error('a trial countdown is on screen during beta, contradicting "Free during beta"');
  }
}

/**
 * What the shop will actually see AFTER the flag flips — exercised now, while
 * anyone can still fix it cheaply.
 *
 * Everything the trial adds is dormant during beta, so without this the banner
 * and the refusal are code that has never once rendered. `isBetaFree` is a
 * function on the module object, so it can be stubbed here to look at the far
 * side of the flip without shipping it.
 */
async function testPostBetaTrialSurfaces(window) {
  const out = await window.evaluate(() => {
    const orig = KhaytCloudPlans.isBetaFree;
    try {
      KhaytCloudPlans.isBetaFree = () => false;
      settings.cloud = settings.cloud || {};
      settings.cloud.planActive = false;

      // 10 days in: the countdown should be on screen, and publishing allowed.
      settings.cloud.portalTrialStartedAt = new Date(Date.now() - 10 * 86400000).toISOString();
      renderCloudSettings();
      const active = {
        text: document.querySelector('#cloudSettingsSection').innerText,
        allowed: portalTrialAllows(),
      };

      // 40 days in: expired. The banner changes and publishing is refused.
      settings.cloud.portalTrialStartedAt = new Date(Date.now() - 40 * 86400000).toISOString();
      renderCloudSettings();
      // The contrast sweep above ran before this banner existed, so check it
      // here, where it is actually on screen and in a LIGHT theme.
      const banner = [...document.querySelectorAll('#cloudSettingsSection p')]
        .find((p) => /has ended/i.test(p.innerText));
      const expired = {
        text: document.querySelector('#cloudSettingsSection').innerText,
        allowed: portalTrialAllows(),
        bannerColor: banner ? getComputedStyle(banner).color : null,
        bodyColor: getComputedStyle(document.body).color,
      };

      // Paying restores it immediately, without touching the trial date.
      settings.cloud.planActive = true;
      renderCloudSettings();
      const subscribed = {
        text: document.querySelector('#cloudSettingsSection').innerText,
        allowed: portalTrialAllows(),
      };
      return { active, expired, subscribed };
    } finally {
      KhaytCloudPlans.isBetaFree = orig;
      delete settings.cloud.portalTrialStartedAt;
      delete settings.cloud.planActive;
      renderCloudSettings();
    }
  });

  if (!/20 days left/i.test(out.active.text)) {
    throw new Error(`day 10 of 30 should read "20 days left"; got: ${out.active.text.slice(0, 200)}`);
  }
  if (out.active.allowed !== true) throw new Error('publishing refused while the trial is still running');

  if (!/has ended/i.test(out.expired.text)) {
    throw new Error(`an expired trial should say so; got: ${out.expired.text.slice(0, 200)}`);
  }
  if (out.expired.allowed !== false) {
    throw new Error('an expired trial still allows publishing — the trial means nothing');
  }
  if (out.expired.bannerColor && out.expired.bannerColor !== out.expired.bodyColor) {
    throw new Error(
      `the expiry banner sets its own text colour (${out.expired.bannerColor} vs body ${out.expired.bodyColor}); `
      + 'tint the background instead — a colour token used as text is the beta.18 contrast failure',
    );
  }

  if (out.subscribed.allowed !== true) throw new Error('a subscriber cannot publish');
  if (/has ended/i.test(out.subscribed.text)) {
    throw new Error('a paying shop is still being shown the expiry notice');
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await openCloudPanel(window);

  const struck = await testLadderRenders(window);
  await testPricesAreStruckThroughAndReal(window, struck);
  await testCurrencyFollowsTheShop(window);
  await testLightThemeDoesNotColourTheText(window);
  await testTrialDoesNotBiteDuringBeta(window);
  await testPostBetaTrialSurfaces(window);

  console.log('e2e-cloud-plans: ok (ladder renders, prices real + struck through, currency follows the shop, light theme safe, trial dormant during beta and correct after it)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
