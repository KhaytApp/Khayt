'use strict';
/**
 * The currencies a shop can price in.
 *
 * A shared module because the invoice formats money against this table and
 * the Mac app prints the invoice: with the table in the renderer, the Mac had
 * a one-row stand-in that knew SAR and nothing else, so a shop pricing in
 * euros would have printed "EUR" where the document prints "€".
 *
 * PURE: data only. Formatting lives with whoever formats.
 */
(function (global) {

  const CURRENCIES = {
    SAR: { symbol: 'SAR', label: 'Saudi Riyal (SAR)', pos: 'after' },
    AED: { symbol: 'AED', label: 'UAE Dirham (AED)', pos: 'after' },
    KWD: { symbol: 'KWD', label: 'Kuwaiti Dinar (KWD)', pos: 'after' },
    BHD: { symbol: 'BHD', label: 'Bahraini Dinar (BHD)', pos: 'after' },
    QAR: { symbol: 'QAR', label: 'Qatari Riyal (QAR)', pos: 'after' },
    OMR: { symbol: 'OMR', label: 'Omani Rial (OMR)', pos: 'after' },
    EGP: { symbol: 'EGP', label: 'Egyptian Pound (EGP)', pos: 'after' },
    MAD: { symbol: 'MAD', label: 'Moroccan Dirham (MAD)', pos: 'after' },
    TND: { symbol: 'TND', label: 'Tunisian Dinar (TND)', pos: 'after' },
    DZD: { symbol: 'DZD', label: 'Algerian Dinar (DZD)', pos: 'after' },
    IQD: { symbol: 'IQD', label: 'Iraqi Dinar (IQD)', pos: 'after' },
    JOD: { symbol: 'JOD', label: 'Jordanian Dinar (JOD)', pos: 'after' },
    USD: { symbol: '$', label: 'US Dollar (USD)', pos: 'before' },
    EUR: { symbol: '€', label: 'Euro (EUR)', pos: 'before' },
    GBP: { symbol: '£', label: 'British Pound (GBP)', pos: 'before' },
    CAD: { symbol: 'CA$', label: 'Canadian Dollar (CAD)', pos: 'before' },
    AUD: { symbol: 'A$', label: 'Australian Dollar (AUD)', pos: 'before' },
    CHF: { symbol: 'CHF', label: 'Swiss Franc (CHF)', pos: 'before' },
    TRY: { symbol: '₺', label: 'Turkish Lira (TRY)', pos: 'before' },
    INR: { symbol: '₹', label: 'Indian Rupee (INR)', pos: 'before' },
    JPY: { symbol: '¥', label: 'Japanese Yen (JPY)', pos: 'before' },
    CNY: { symbol: '¥', label: 'Chinese Yuan (CNY)', pos: 'before' },
    KRW: { symbol: '₩', label: 'South Korean Won (KRW)', pos: 'before' },
    BRL: { symbol: 'R$', label: 'Brazilian Real (BRL)', pos: 'before' },
    MXN: { symbol: '$', label: 'Mexican Peso (MXN)', pos: 'before' },
    ZAR: { symbol: 'R', label: 'South African Rand (ZAR)', pos: 'before' },
    NGN: { symbol: '₦', label: 'Nigerian Naira (NGN)', pos: 'before' },
  };

  const api = { CURRENCIES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCurrencies = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
