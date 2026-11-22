/**
 * App security helpers — recovery codes, PIN rules (Node + tests).
 */
const crypto = require('crypto');

const RECOVERY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const WEAK_PINS = new Set(['0000', '1111', '2222', '3333', '4444', '5555', '6666', '7777', '8888', '9999', '1234', '4321', '1212', '0123']);

function hashSecret(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function randomBlock(size = 4) {
  let out = '';
  for (let i = 0; i < size; i++) {
    const idx = crypto.randomInt(0, RECOVERY_ALPHABET.length);
    out += RECOVERY_ALPHABET[idx];
  }
  return out;
}

function generateRecoveryCode() {
  return `KHAYT-${randomBlock()}-${randomBlock()}-${randomBlock()}`;
}

function normalizeRecoveryCode(code) {
  return String(code || '').toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/^KHAYT/, '');
}

function formatRecoveryCode(code) {
  const raw = normalizeRecoveryCode(code);
  if (raw.length !== 12) return String(code || '').trim().toUpperCase();
  return `KHAYT-${raw.slice(0, 4)}-${raw.slice(4, 8)}-${raw.slice(8, 12)}`;
}

function isValidRecoveryCode(code) {
  return normalizeRecoveryCode(code).length === 12;
}

function verifyRecoveryCode(code, hash) {
  if (!hash || !isValidRecoveryCode(code)) return false;
  try {
    const a = Buffer.from(hashSecret(normalizeRecoveryCode(code)), 'utf8');
    const b = Buffer.from(String(hash), 'utf8');
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

function isValidPin(pin) {
  return /^\d{4,8}$/.test(String(pin || ''));
}

function isWeakPin(pin) {
  const p = String(pin || '');
  if (!isValidPin(p)) return true;
  if (WEAK_PINS.has(p)) return true;
  if (/^(\d)\1+$/.test(p)) return true;
  return false;
}

function buildRecoveryCodeFile({ code, businessName, createdAt }) {
  const formatted = formatRecoveryCode(code);
  // The date printed in the file the owner saves, so it must be their calendar
  // day — a UTC one reads as yesterday for the first three hours of every day in
  // the Gulf, on a document whose whole job is to be trustworthy later.
  const now = new Date();
  const date = createdAt
    || `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  const biz = businessName || 'Khayt';
  return [
    'Khayt Recovery Code',
    `Business: ${biz}`,
    `Created: ${date}`,
    '',
    `Recovery code: ${formatted}`,
    '',
    'Keep this file private. Anyone with this code can reset your admin PIN.',
    'If you lose both your PIN and this code, the only option is a full data wipe.',
  ].join('\n');
}

module.exports = {
  hashSecret,
  generateRecoveryCode,
  normalizeRecoveryCode,
  formatRecoveryCode,
  isValidRecoveryCode,
  verifyRecoveryCode,
  isValidPin,
  isWeakPin,
  buildRecoveryCodeFile,
};
