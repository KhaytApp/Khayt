'use strict';
(function () {

/**
 * AI assist — customer message drafting (Phase: AI assist, expansion).
 *
 * Pure + transport-injected like lib/ai-quote.js: this module only builds the
 * system/request prompts + the structured-output schema, and extracts the
 * drafted message from a model result. The actual model call happens via the
 * app's aiExtract IPC (or a mock in tests). It NEVER invents facts — the prompt
 * forbids inventing prices/dates and tells the model to use only what's given.
 *
 * The draft is always shown to the owner to edit before sending; nothing is sent
 * automatically.
 */

/** Structured-output contract: the model returns a single message string. */
const REPLY_SCHEMA = {
  type: 'object',
  required: ['message'],
  properties: { message: { type: 'string' } },
};

/** Supported intents (id + default English label for the picker). */
const REPLY_INTENTS = [
  { id: 'status_update', label: 'Status update' },
  { id: 'ready_pickup', label: 'Ready for pickup / delivery' },
  { id: 'quote_followup', label: 'Quote follow-up' },
  { id: 'payment_reminder', label: 'Payment reminder' },
  { id: 'delay_apology', label: 'Delay / apology' },
  { id: 'custom', label: 'Custom (use my note)' },
];

const INTENT_GUIDANCE = {
  status_update: 'Give the customer a brief, reassuring update on their order status.',
  ready_pickup: 'Let the customer know their order is ready for pickup or delivery.',
  quote_followup: 'Politely follow up on the quote you sent and invite them to approve or ask questions.',
  payment_reminder: 'Send a friendly, non-pushy reminder about the outstanding amount.',
  delay_apology: 'Apologise for a delay and reassure them you are on it; do not promise a date unless one is given.',
  custom: 'Follow the shop owner’s note below for what to say.',
};

/** System prompt: tone, language, and the no-inventing-facts guardrail. */
function buildReplySystem(opts = {}) {
  const shopName = opts.shopName || 'a 3D-printing shop';
  const language = opts.lang === 'ar' ? 'Arabic' : 'English';
  return [
    `You write short, warm, professional customer messages for ${shopName}.`,
    `Write the message in ${language}.`,
    'Keep it to 2–4 sentences: friendly, clear, and specific to the facts given.',
    'Use ONLY the facts provided. Never invent prices, dates, tracking numbers, or details.',
    'If a useful detail is missing, omit it gracefully — do not use placeholders like [name] or [date].',
    'Do not include a subject line. Output only the message text, ready to send.',
  ].join(' ');
}

/** Build the request from order + client + intent context (facts only). */
function buildReplyRequest(opts = {}) {
  const order = opts.order || {};
  const client = opts.client || {};
  const facts = [];
  if (client.name) facts.push(`Customer name: ${client.name}`);
  if (order.id) facts.push(`Order reference: ${order.id}`);
  if (order.project) facts.push(`Project: ${order.project}`);
  if (order.status) facts.push(`Current status: ${order.status}`);
  if (order.dueDate) facts.push(`Due / ready date: ${order.dueDate}`);
  if (order.price != null && order.price !== '') {
    facts.push(`Amount: ${order.price}${opts.currency ? ' ' + opts.currency : ''}`);
  }
  if (order.paidAmount != null && order.price != null) {
    const outstanding = (+order.price || 0) - (+order.paidAmount || 0);
    if (outstanding > 0) facts.push(`Outstanding balance: ${outstanding}${opts.currency ? ' ' + opts.currency : ''}`);
  }
  const intent = INTENT_GUIDANCE[opts.intent] ? opts.intent : 'status_update';
  const lines = [
    `Write a customer message. Intent: ${INTENT_GUIDANCE[intent]}`,
    '',
    facts.length ? 'Facts you may use:\n' + facts.map((f) => `- ${f}`).join('\n') : 'No specific order facts were provided.',
  ];
  if (opts.extra && String(opts.extra).trim()) {
    lines.push('', `Note from the shop owner (follow this): ${String(opts.extra).trim()}`);
  }
  return lines.join('\n');
}

/** Extract the drafted message from a model result (object or raw string). */
function pickMessage(result) {
  if (!result) return '';
  const m = typeof result === 'string' ? result : result.message;
  return String(m == null ? '' : m).trim();
}

const api = { REPLY_SCHEMA, REPLY_INTENTS, INTENT_GUIDANCE, buildReplySystem, buildReplyRequest, pickMessage };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiReply = api;

})();
