'use strict';
(function (global) {

/**
 * Which AI a shop uses, and what its wire format looks like.
 *
 * Khayt's AI features were Anthropic and nothing else: the URL, the auth
 * header, the tool shape and the reply parsing were all written inline in one
 * IPC handler. A shop that already pays OpenAI, or that must keep its data
 * inside the Kingdom on a local model, could not use any of them — and "bring
 * your own key" meant "bring your own key to the one vendor we picked".
 *
 * ── WHAT IS THE SAME EVERYWHERE, AND WHAT IS NOT ───────────────────────────
 *
 * Every one of these features asks for STRUCTURED OUTPUT — a tool call with a
 * JSON schema — because a free-text reply cannot be put into a quote. All three
 * major providers support that and all three spell it differently:
 *
 *   Anthropic  tools[{name, description, input_schema}] + tool_choice
 *              -> content[] entry of type 'tool_use', .input
 *   OpenAI     tools[{type:'function', function:{name, parameters}}]
 *              -> choices[0].message.tool_calls[0].function.arguments, a STRING
 *   Google     tools[{functionDeclarations:[{name, parameters}]}]
 *              -> candidates[0].content.parts[].functionCall.args
 *
 * The differences are entirely in shaping and parsing, which is what this
 * module is. The fetch itself stays with the caller — the main process has one,
 * the Mac app has URLSession, and neither belongs in lib/.
 *
 * ── OPENAI-COMPATIBLE IS NOT A FOURTH VENDOR ───────────────────────────────
 *
 * It is the same wire format at an address the shop chooses, which is how
 * OpenRouter, Together, Groq, Azure, vLLM and Ollama all present themselves.
 * One entry covers every local and self-hosted option, and a shop that must not
 * send its book outside the building has somewhere to point.
 *
 * Pure: builds requests and reads replies. No fetch, no keys, no storage.
 */

/** The usage block, normalised. Every provider counts, none of them agree. */
function usageOf(provider, data) {
  const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
  if (provider === 'anthropic') {
    const u = data && data.usage;
    if (!u) return null;
    return { inputTokens: n(u.input_tokens), outputTokens: n(u.output_tokens) };
  }
  if (provider === 'google') {
    const u = data && data.usageMetadata;
    if (!u) return null;
    return { inputTokens: n(u.promptTokenCount), outputTokens: n(u.candidatesTokenCount) };
  }
  const u = data && data.usage;
  if (!u) return null;
  return { inputTokens: n(u.prompt_tokens), outputTokens: n(u.completion_tokens) };
}

/** The address rule, shared with the cloud's own base-URL field. */
const baseRules = () => (typeof global.KhaytBaseUrl !== 'undefined')
  ? global.KhaytBaseUrl
  : (function () { try { return require('./base-url.js'); } catch (e) { return null; } })();

/**
 * The address to send this request to, checked before a key travels to it.
 *
 * A shop's own address is accepted — that is the point of the compatible
 * provider, and of a gateway inside the Kingdom in front of the others. What is
 * NOT accepted is `http://` to a public host: the key rides in an
 * `authorization` header, and this used to concatenate whatever was typed
 * straight into the fetch with no check at all. `lib/base-url.js` has the rule
 * and the reasoning; loopback and RFC1918 keep working, because a model running
 * on the bench through Ollama is the case the option exists for.
 *
 * A blank address is not an error here — every vendor has a default. Only a
 * given one is checked.
 */
function base(url, fallback) {
  const v = String(url == null ? '' : url).trim().replace(/\/+$/, '');
  if (!v) return fallback;
  const rules = baseRules();
  // No silent pass-through if the module is missing: an unchecked address is
  // the thing being fixed.
  if (!rules) throw new Error('Cannot check that address');
  return rules.validateBaseUrl(v, { what: 'address', secret: 'API key' });
}

const PROVIDERS = {
  anthropic: {
    id: 'anthropic',
    label: 'Anthropic',
    defaultModel: 'claude-opus-5',
    /** Shown in settings so a shop knows where to get one. */
    keysAt: 'https://console.anthropic.com/settings/keys',
    needsBaseUrl: false,

    request({ apiKey, model, system, prompt, image, tool, maxTokens, baseUrl }) {
      const content = [{ type: 'text', text: String(prompt) }];
      if (image) {
        content.push({
          type: 'image',
          source: { type: 'base64', media_type: 'image/png', data: String(image) },
        });
      }
      return {
        url: `${base(baseUrl, 'https://api.anthropic.com')}/v1/messages`,
        headers: {
          'content-type': 'application/json',
          'x-api-key': String(apiKey),
          'anthropic-version': '2023-06-01',
        },
        body: {
          model, max_tokens: maxTokens, system: String(system || ''),
          tools: [tool],
          tool_choice: { type: 'tool', name: tool.name },
          messages: [{ role: 'user', content }],
        },
      };
    },

    parse(data) {
      const call = ((data && data.content) || []).find((c) => c && c.type === 'tool_use');
      if (call && call.input) {
        return { ok: true, draft: call.input, model: data.model || null };
      }
      return { ok: false, stop: data && data.stop_reason };
    },
  },

  openai: {
    id: 'openai',
    label: 'OpenAI',
    defaultModel: 'gpt-5',
    keysAt: 'https://platform.openai.com/api-keys',
    needsBaseUrl: false,

    request({ apiKey, model, system, prompt, image, tool, maxTokens, baseUrl }) {
      const content = [{ type: 'text', text: String(prompt) }];
      if (image) {
        content.push({
          type: 'image_url',
          image_url: { url: `data:image/png;base64,${String(image)}` },
        });
      }
      return {
        url: `${base(baseUrl, 'https://api.openai.com')}/v1/chat/completions`,
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${String(apiKey)}`,
        },
        body: {
          model,
          max_completion_tokens: maxTokens,
          messages: [
            { role: 'system', content: String(system || '') },
            { role: 'user', content },
          ],
          tools: [{
            type: 'function',
            function: {
              name: tool.name,
              description: tool.description,
              parameters: tool.input_schema,
            },
          }],
          tool_choice: { type: 'function', function: { name: tool.name } },
        },
      };
    },

    parse(data) {
      const choice = ((data && data.choices) || [])[0];
      const call = ((choice && choice.message && choice.message.tool_calls) || [])[0];
      // ARGUMENTS ARE A STRING HERE, not an object — the one difference in this
      // file that fails at the far end rather than at the boundary. Handing a
      // JSON string to a caller expecting a record produces `undefined` for
      // every field, which reads as the model having answered nothing.
      if (call && call.function && call.function.arguments) {
        try {
          return { ok: true, draft: JSON.parse(call.function.arguments), model: data.model || null };
        } catch (e) {
          return { ok: false, stop: 'malformed_arguments' };
        }
      }
      return { ok: false, stop: choice && choice.finish_reason };
    },
  },

  google: {
    id: 'google',
    label: 'Google Gemini',
    defaultModel: 'gemini-2.5-pro',
    keysAt: 'https://aistudio.google.com/apikey',
    needsBaseUrl: false,

    request({ apiKey, model, system, prompt, image, tool, maxTokens, baseUrl }) {
      const parts = [{ text: String(prompt) }];
      if (image) {
        parts.push({ inline_data: { mime_type: 'image/png', data: String(image) } });
      }
      return {
        // The key goes in a header, not the query string: a URL carrying a
        // secret ends up in logs and error reports.
        url: `${base(baseUrl, 'https://generativelanguage.googleapis.com')}`
          + `/v1beta/models/${encodeURIComponent(model)}:generateContent`,
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': String(apiKey),
        },
        body: {
          systemInstruction: { parts: [{ text: String(system || '') }] },
          contents: [{ role: 'user', parts }],
          tools: [{
            functionDeclarations: [{
              name: tool.name,
              description: tool.description,
              parameters: tool.input_schema,
            }],
          }],
          toolConfig: {
            functionCallingConfig: { mode: 'ANY', allowedFunctionNames: [tool.name] },
          },
          generationConfig: { maxOutputTokens: maxTokens },
        },
      };
    },

    parse(data) {
      const candidate = ((data && data.candidates) || [])[0];
      const parts = (candidate && candidate.content && candidate.content.parts) || [];
      const call = parts.find((p) => p && p.functionCall);
      if (call && call.functionCall && call.functionCall.args) {
        return { ok: true, draft: call.functionCall.args, model: data.modelVersion || null };
      }
      return { ok: false, stop: candidate && candidate.finishReason };
    },
  },
};

// OpenAI-compatible: the same wire format at an address the shop names. One
// entry for OpenRouter, Together, Groq, Azure, vLLM and Ollama — and the only
// option for a shop that must not send its book out of the building.
PROVIDERS.compatible = Object.assign({}, PROVIDERS.openai, {
  id: 'compatible',
  label: 'OpenAI-compatible',
  defaultModel: '',
  keysAt: '',
  needsBaseUrl: true,
  request(opts) {
    // No default address. A blank base URL silently reaching api.openai.com
    // would send a shop's data to a vendor it did not choose.
    if (!String(opts.baseUrl || '').trim()) {
      throw new Error('An OpenAI-compatible provider needs its address');
    }
    return PROVIDERS.openai.request(opts);
  },
});

/** Every provider, for a settings list. */
function providers() {
  return Object.keys(PROVIDERS).map((id) => ({
    id,
    label: PROVIDERS[id].label,
    defaultModel: PROVIDERS[id].defaultModel,
    keysAt: PROVIDERS[id].keysAt,
    needsBaseUrl: !!PROVIDERS[id].needsBaseUrl,
  }));
}

/** The one a shop has chosen, falling back to Anthropic. */
function providerOf(settings) {
  const id = settings && settings.ai && settings.ai.provider;
  return Object.prototype.hasOwnProperty.call(PROVIDERS, id) ? PROVIDERS[id] : PROVIDERS.anthropic;
}

/**
 * Everything the caller needs to make one request.
 *
 * Throws rather than returning a half-built request: a call with no key is a
 * configuration fault the shop has to see, not a network error to retry.
 */
function buildRequest(settings, opts) {
  const provider = providerOf(settings);
  const ai = (settings && settings.ai) || {};
  const apiKey = String((opts && opts.apiKey) || ai.apiKey || '').trim();
  if (!apiKey && provider.id !== 'compatible') {
    throw new Error(`No API key for ${provider.label}`);
  }
  const model = String((opts && opts.model) || ai.model || provider.defaultModel || '').trim();
  if (!model) throw new Error(`No model chosen for ${provider.label}`);

  const built = provider.request(Object.assign({}, opts, {
    apiKey, model, baseUrl: ai.baseUrl,
  }));
  return Object.assign({ provider: provider.id, model }, built);
}

/** Read one reply. `draft` is the structured answer; `usage` is what it cost. */
function readResponse(settings, data) {
  const provider = providerOf(settings);
  const out = provider.parse(data || {});
  return Object.assign({ provider: provider.id, usage: usageOf(provider.id, data) }, out);
}

const api = { PROVIDERS, providers, providerOf, buildRequest, readResponse, usageOf };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytAiProviders = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
