'use strict';
/**
 * A saved message, with this job's facts put into it.
 *
 * ── WHY THIS IS SHARED AND THE FORMATTING IS NOT ──────────────────────────
 *
 * A shop writes its own templates once — "Hi {{client}}, your order {{id}} is
 * ready!" — and then sends them from whichever app it happens to have open.
 * If the two apps knew different placeholder names, a template written in one
 * would go out of the other with `{{due}}` printed literally, to a customer.
 * So WHICH placeholders exist, and what fills in for a blank, is one rule.
 *
 * What a price looks like is not: that is a currency, a locale and a digit
 * system, and each host already has its own answer that the rest of its screen
 * agrees with. So this takes VALUES THAT ARE ALREADY TEXT and only puts them
 * in place.
 *
 * PURE: no clock, no globals, no formatting.
 */
(function (global) {

  /** Every placeholder a template may use, in the order the editor lists them. */
  //
  // `shop`, `tracking` and `carrier` came with the WhatsApp milestone updates
  // (`lib/whatsapp-message.js`): a "your parcel is on its way" message without
  // the tracking number is the one message a customer would reply to asking
  // for it. Added at the END so an editor listing them in order keeps the six
  // a shop already knows where they were.
  const PLACEHOLDERS = ['client', 'id', 'price', 'currency', 'due', 'status', 'shop', 'tracking', 'carrier'];

  /**
   * What is printed when a value is missing.
   *
   * Not the same mark for both, and not an empty gap. A nameless customer gets
   * `...` because the sentence is addressed to somebody and has to keep its
   * shape — "Hi ..., your order is ready" reads as a template somebody forgot
   * to fill, which is exactly what it is and what the shop should notice
   * before sending. A missing DATE gets an em dash, because that is the mark
   * this app uses everywhere else for a figure it does not have.
   */
  const BLANKS = { client: '...', due: '—' };

  /**
   * @param {string} body    the template, with `{{name}}` placeholders
   * @param {object} values  already-formatted text per placeholder
   * @returns {string}
   */
  const PATTERN = new RegExp('\\{\\{(' + PLACEHOLDERS.join('|') + ')\\}\\}', 'g');

  function fillTemplate(body, values) {
    const v = values || {};
    // ── ONE PASS, AND A FUNCTION FOR THE REPLACEMENT ───────────────────────
    //
    // Both matter, and the obvious spelling gets both wrong.
    //
    // A chain of `.replace()` calls — one per placeholder, which is how this
    // was written — runs over its OWN OUTPUT: a value inserted by the first
    // call is searched by the second. A customer whose name is `{{price}}`
    // would have a price printed as their name. One pass cannot do that,
    // because nothing inserted is looked at again.
    //
    // And the replacement is a FUNCTION, not a string. In a string, `$&`
    // means "the whole match" and `$'` means "everything after it" — so a
    // value carrying either would rewrite the message around it. A function's
    // return value is taken literally.
    return String(body == null ? '' : body).replace(PATTERN, function (whole, key) {
      const given = v[key] == null ? '' : String(v[key]);
      return given || BLANKS[key] || '';
    });
  }

  /**
   * Whether a template mentions a placeholder — so a host can skip resolving
   * a figure nothing is going to print.
   */
  function usesPlaceholder(body, key) {
    return String(body == null ? '' : body).indexOf('{{' + key + '}}') !== -1;
  }

  const api = { PLACEHOLDERS, BLANKS, fillTemplate, usesPlaceholder };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWaTemplate = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
