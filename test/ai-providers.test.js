'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  PROVIDERS, providers, providerOf, buildRequest, readResponse, usageOf,
} = require('../lib/ai-providers');

const TOOL = {
  name: 'quote_extract',
  description: 'Physical facts for a 3D-print quote',
  input_schema: { type: 'object', properties: { grams: { type: 'number' } } },
};

const settings = (ai) => ({ ai: Object.assign({ apiKey: 'k' }, ai) });
const ask = (id, extra) => buildRequest(settings(Object.assign({ provider: id }, extra)),
  { system: 'sys', prompt: 'hello', tool: TOOL, maxTokens: 500 });

/* ============================================================
   Shaping — every provider spells structured output differently
   ============================================================ */

test('each provider is asked for a tool call in its own dialect', () => {
  // A free-text reply cannot go into a quote, so every one of these features
  // asks for structured output. All three support it; none of them agree on
  // how to say so.
  assert.equal(ask('anthropic').body.tools[0].name, 'quote_extract');
  assert.equal(ask('openai').body.tools[0].function.name, 'quote_extract');
  assert.equal(ask('google').body.tools[0].functionDeclarations[0].name, 'quote_extract');
});

test('each provider is forced to use the tool rather than offered it', () => {
  // Without this they answer in prose when they feel like it, and the caller
  // gets nothing it can put in a form.
  assert.deepEqual(ask('anthropic').body.tool_choice, { type: 'tool', name: 'quote_extract' });
  assert.equal(ask('openai').body.tool_choice.function.name, 'quote_extract');
  assert.equal(ask('google').body.toolConfig.functionCallingConfig.mode, 'ANY');
});

test('the key never travels in the URL', () => {
  // Google documents a `?key=` query parameter. A URL carrying a secret ends up
  // in logs, proxies and error reports.
  for (const id of ['anthropic', 'openai', 'google']) {
    assert.equal(ask(id).url.includes('k'), ask(id).url.includes('k'));
    assert.match(JSON.stringify(ask(id).headers), /k/,
      `${id} does not put the key in a header`);
    assert.doesNotMatch(ask(id).url, /[?&]key=/, `${id} put the key in the URL`);
  }
});

test('an attached photo reaches every provider', () => {
  const img = 'AAAA';
  const one = buildRequest(settings({ provider: 'anthropic' }),
    { prompt: 'p', tool: TOOL, maxTokens: 10, image: img });
  assert.equal(one.body.messages[0].content[1].source.data, img);

  const two = buildRequest(settings({ provider: 'openai' }),
    { prompt: 'p', tool: TOOL, maxTokens: 10, image: img });
  assert.match(two.body.messages[1].content[1].image_url.url, /^data:image\/png;base64,AAAA$/);

  const three = buildRequest(settings({ provider: 'google' }),
    { prompt: 'p', tool: TOOL, maxTokens: 10, image: img });
  assert.equal(three.body.contents[0].parts[1].inline_data.data, img);
});

test('the system prompt is not dropped by the two that have no system field', () => {
  // OpenAI takes it as a message and Google as `systemInstruction`. Lost, the
  // model stops being told it may not invent facts.
  assert.equal(ask('openai').body.messages[0].role, 'system');
  assert.equal(ask('openai').body.messages[0].content, 'sys');
  assert.equal(ask('google').body.systemInstruction.parts[0].text, 'sys');
});

/* ============================================================
   Reading — one shape out, whatever went in
   ============================================================ */

test('every provider yields the same draft', () => {
  const out = {
    anthropic: readResponse(settings({ provider: 'anthropic' }),
      { content: [{ type: 'tool_use', input: { grams: 42 } }] }),
    openai: readResponse(settings({ provider: 'openai' }),
      { choices: [{ message: { tool_calls: [{ function: { arguments: '{"grams":42}' } }] } }] }),
    google: readResponse(settings({ provider: 'google' }),
      { candidates: [{ content: { parts: [{ functionCall: { args: { grams: 42 } } }] } }] }),
  };
  for (const [id, r] of Object.entries(out)) {
    assert.equal(r.ok, true, `${id} did not read its own reply`);
    assert.deepEqual(r.draft, { grams: 42 }, `${id} produced a different draft`);
  }
});

test("OpenAI's arguments are a STRING and are parsed", () => {
  // The one difference here that fails at the far end rather than at the
  // boundary: handing the JSON string through gives `undefined` for every
  // field, which reads as the model having answered nothing.
  const r = readResponse(settings({ provider: 'openai' }),
    { choices: [{ message: { tool_calls: [{ function: { arguments: '{"grams":7}' } }] } }] });
  assert.equal(typeof r.draft, 'object');
  assert.equal(r.draft.grams, 7);
});

test('arguments that are not JSON are a refusal, not a crash', () => {
  const r = readResponse(settings({ provider: 'openai' }),
    { choices: [{ message: { tool_calls: [{ function: { arguments: 'not json' } }] } }] });
  assert.equal(r.ok, false);
  assert.equal(r.stop, 'malformed_arguments');
});

test('a reply with no tool call carries the reason it had none', () => {
  // Refused, ran out of room, or paused — three different fixes.
  assert.equal(readResponse(settings({ provider: 'anthropic' }),
    { content: [{ type: 'text', text: 'no' }], stop_reason: 'max_tokens' }).stop, 'max_tokens');
  assert.equal(readResponse(settings({ provider: 'openai' }),
    { choices: [{ message: {}, finish_reason: 'length' }] }).stop, 'length');
  assert.equal(readResponse(settings({ provider: 'google' }),
    { candidates: [{ content: { parts: [] }, finishReason: 'SAFETY' }] }).stop, 'SAFETY');
});

test('usage is normalised, because none of them count the same way', () => {
  // A shop on its own key cannot decide whether the assistant is worth two
  // riyals a month or two hundred without this.
  const want = { inputTokens: 100, outputTokens: 20 };
  assert.deepEqual(usageOf('anthropic', { usage: { input_tokens: 100, output_tokens: 20 } }), want);
  assert.deepEqual(usageOf('openai', { usage: { prompt_tokens: 100, completion_tokens: 20 } }), want);
  assert.deepEqual(usageOf('google',
    { usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 20 } }), want);
});

test('a reply with no usage block is null, not zero', () => {
  // Zero would go into the month's spend as a free call.
  assert.equal(usageOf('anthropic', {}), null);
  assert.equal(usageOf('openai', {}), null);
  assert.equal(usageOf('google', {}), null);
});

/* ============================================================
   Choosing one
   ============================================================ */

test('a shop that has chosen nothing gets Anthropic', () => {
  // What every existing install is already using.
  assert.equal(providerOf({}).id, 'anthropic');
  assert.equal(providerOf({ ai: {} }).id, 'anthropic');
  assert.equal(providerOf({ ai: { provider: 'nonsense' } }).id, 'anthropic');
});

test('every provider offers a model by default, except the one that cannot', () => {
  for (const p of providers()) {
    if (p.id === 'compatible') {
      assert.equal(p.defaultModel, '', 'a self-hosted model cannot be guessed at');
    } else {
      assert.ok(p.defaultModel, `${p.id} has no default model`);
    }
  }
});

test('no key is a configuration fault, stated as one', () => {
  // Not a network error to retry: retrying tells the shop nothing.
  assert.throws(() => buildRequest({ ai: { provider: 'openai', apiKey: '' } },
    { prompt: 'p', tool: TOOL, maxTokens: 10 }), /No API key for OpenAI/);
});

test('a compatible provider with no address is refused', () => {
  // A blank base URL silently reaching api.openai.com would send a shop's data
  // to a vendor it did not choose — which is the whole reason this entry
  // exists.
  assert.throws(() => buildRequest({ ai: { provider: 'compatible', model: 'llama', apiKey: 'k' } },
    { prompt: 'p', tool: TOOL, maxTokens: 10 }), /needs its address/);
});

test('a compatible provider speaks OpenAI at the address it was given', () => {
  const r = buildRequest(
    { ai: { provider: 'compatible', apiKey: 'k', model: 'llama3', baseUrl: 'http://localhost:11434/' } },
    { prompt: 'p', tool: TOOL, maxTokens: 10 });
  // The trailing slash a shop pastes must not become a double slash.
  assert.equal(r.url, 'http://localhost:11434/v1/chat/completions');
  assert.equal(r.body.tools[0].function.name, 'quote_extract');
});

test('a base URL overrides the vendor address for the others too', () => {
  // A proxy inside the Kingdom, or a gateway that logs spend.
  const r = buildRequest({ ai: { provider: 'anthropic', apiKey: 'k', baseUrl: 'https://gw.example.sa' } },
    { prompt: 'p', tool: TOOL, maxTokens: 10 });
  assert.equal(r.url, 'https://gw.example.sa/v1/messages');
});

test('the chosen model is reported back with the request', () => {
  assert.equal(ask('openai').model, PROVIDERS.openai.defaultModel);
  assert.equal(ask('openai', { model: 'gpt-5-mini' }).model, 'gpt-5-mini');
});
