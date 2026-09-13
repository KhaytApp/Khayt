'use strict';
(function () {

/**
 * AI task registry — the SINGLE SOURCE OF TRUTH for how each AI feature presents
 * itself to the model, plus the shared request-policy helpers the main process
 * needs (retry, stop-reason, error text).
 *
 * WHY THIS EXISTS: every AI feature routes through one IPC handler
 * (`hub:ai-extract`). That handler used to hard-code a single tool definition —
 * name 'quote_extract', description 'Physical facts for a 3D-print quote' — for
 * ALL of them. So a customer-reply draft reached the model as a tool named
 * quote_extract whose schema was {subject, body}. The tool name and description
 * are among the strongest signals the model has for what it is being asked to
 * do, so three of the four features were being actively mis-framed.
 *
 * The fix is a task id per feature. Schemas still live next to the prompt
 * builders that own them (lib/ai-quote.js, ai-price.js, ai-reply.js,
 * ai-assistant.js); this module owns the framing and the policy.
 *
 * Pure (no DOM, no network, no globals) so all of it is unit-testable.
 */

/**
 * One entry per AI feature. `name` is what the model sees as the tool name and
 * `description` is what it sees as the tool's purpose — both must describe THAT
 * feature, not quoting. `maxTokens` is sized to the shape of the output: a
 * structured extraction needs far less room than a free-text assistant answer,
 * and a too-small cap truncates mid-object and surfaces as a parse failure.
 *
 * These budgets were raised 4x when the default model moved to `claude-opus-5`,
 * and the reason is not that answers got longer. On that model **thinking is on
 * unless you ask for it not to be**, and `max_tokens` caps thinking PLUS the
 * answer — so a budget sized around the answer alone can now be spent before
 * the tool call is ever emitted. That surfaces exactly as the truncation this
 * comment already warned about, which is why the numbers moved rather than the
 * warning. A cap is not a charge: only tokens actually produced are billed, so
 * headroom costs nothing on the calls that do not need it.
 */
const AI_TASKS = {
  quote: {
    name: 'quote_extract',
    description: 'Record the physical facts of a 3D-print job (quantity, material, weight, print time) for the shop calculator to price.',
    maxTokens: 4096,
  },
  price: {
    name: 'suggest_price',
    description: 'Recommend a profit margin and price for a job, grounded in the shop\'s own comparable realized margins.',
    maxTokens: 4096,
  },
  reply: {
    name: 'draft_customer_message',
    description: 'Draft a message from the shop to a customer about their order, for the owner to review and edit before sending.',
    maxTokens: 8192,
  },
  assistant: {
    name: 'answer_shop_question',
    description: 'Answer the shop owner\'s question using only the supplied summary of their own shop data.',
    maxTokens: 16000,
  },
};

/** Fallback when a caller sends no task id (older call site, or a bad payload). */
const DEFAULT_TASK = 'quote';

/**
 * Build the Anthropic tool definition + token budget for a task.
 * Unknown/missing ids fall back to the default task rather than throwing: a
 * mislabelled call should still produce a quote, not break the feature.
 * @returns {{ tool: {name,description,input_schema}, maxTokens: number, task: string }}
 */
function resolveTool(task, schema) {
  const id = Object.prototype.hasOwnProperty.call(AI_TASKS, task) ? task : DEFAULT_TASK;
  const spec = AI_TASKS[id];
  return {
    task: id,
    maxTokens: spec.maxTokens,
    tool: {
      name: spec.name,
      description: spec.description,
      input_schema: (schema && typeof schema === 'object') ? schema : { type: 'object', properties: {} },
    },
  };
}

/**
 * Whether an HTTP status is worth retrying. 429 is rate limiting, 529 is
 * "overloaded", 5xx is a server fault — all transient. Everything else (401 bad
 * key, 400 bad schema, 404 bad model) will fail identically on a retry, so
 * retrying only delays the error the owner needs to see.
 */
function shouldRetry(status) {
  return status === 429 || status === 529 || (status >= 500 && status < 600);
}

/**
 * Backoff for attempt N (0-based), in ms. Honors the server's `retry-after`
 * (seconds) when present, since that is authoritative; otherwise exponential
 * 1s, 2s, 4s. Capped so a wedged request can't outlive the caller's patience.
 */
function retryDelayMs(attempt, retryAfterHeader) {
  const secs = Number(retryAfterHeader);
  if (Number.isFinite(secs) && secs > 0) return Math.min(secs * 1000, 30000);
  return Math.min(1000 * Math.pow(2, attempt), 30000);
}

/**
 * Turn an error response into something the owner can act on. The handler used
 * to report bare 'HTTP 400', which is indistinguishable between a malformed
 * schema and an expired key — two problems with completely different fixes.
 * `body` is the parsed JSON error envelope when we managed to read one.
 */
function describeHttpError(status, body) {
  const detail = String((body && body.error && body.error.message) || '').trim();
  const suffix = detail ? ` — ${detail}` : '';
  if (status === 401) return 'AI key rejected. Check the API key in Settings.' + suffix;
  if (status === 403) return 'This AI key lacks access to that model.' + suffix;
  if (status === 404) return 'Unknown model. Check the model name in Settings.' + suffix;
  if (status === 400) return 'The AI request was rejected as invalid.' + suffix;
  if (status === 413) return 'The AI request was too large. Try a shorter description.' + suffix;
  if (status === 429) return 'AI rate limit reached. Try again shortly.' + suffix;
  if (status === 529) return 'The AI service is overloaded. Try again shortly.' + suffix;
  if (status >= 500) return `AI service error (HTTP ${status}). Try again shortly.` + suffix;
  return `AI API error: HTTP ${status}` + suffix;
}

/**
 * A response can be a successful HTTP 200 and still carry no usable tool call.
 * `stop_reason` says why, and the three failure modes need different messages —
 * they were all collapsed into 'No structured output returned', which reads to
 * the owner as an unexplained failure.
 * @returns {string|null} an error message, or null when the turn ended normally.
 */
function describeStop(stopReason) {
  if (stopReason === 'refusal') return 'The AI declined this request. Rephrase it, or fill the form in manually.';
  if (stopReason === 'max_tokens') return 'The AI answer was cut off before it finished. Try a shorter request.';
  if (stopReason === 'pause_turn') return 'The AI paused before finishing. Try again.';
  return null;
}

const api = {
  AI_TASKS,
  DEFAULT_TASK,
  resolveTool,
  shouldRetry,
  retryDelayMs,
  describeHttpError,
  describeStop,
};

// Dual export: CommonJS (node tests + main process) and global (renderer script tag).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiTools = api;

})();
