'use strict';

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {run} = require('../scripts/test-groq-local');

// Synthetic credentials only. Never send a network request in these tests.
test('local Groq probe handles success and safe failures without network access', async (t) => {
  const original = process.env.GROQ_API_KEY;
  t.after(() => {
    if (original === undefined) delete process.env.GROQ_API_KEY;
    else process.env.GROQ_API_KEY = original;
  });
  const fakeKey = 'synthetic-test-credential';
  async function check(fetchImpl, expected, fragment) {
    const messages = [];
    const code = await run({fetchImpl, out: (v) => messages.push(v),
      error: (v) => messages.push(v)});
    assert.equal(code, expected);
    assert.ok(messages.join('\n').includes(fragment));
    assert.ok(!messages.join('\n').includes(fakeKey));
  }

  delete process.env.GROQ_API_KEY;
  await check(() => assert.fail('Missing key must not call fetch'), 1, 'Set GROQ_API_KEY');
  process.env.GROQ_API_KEY = fakeKey;
  await check(async (url, options) => {
    assert.equal(url, 'https://api.groq.com/openai/v1/chat/completions');
    assert.equal(options.headers.Authorization, `Bearer ${fakeKey}`);
    assert.equal(options.headers['Content-Type'], 'application/json');
    assert.equal(options.redirect, 'error');
    assert.equal(options.method, 'POST');
    assert.ok(options.signal instanceof AbortSignal);
    const body = JSON.parse(options.body);
    assert.equal(body.model, 'openai/gpt-oss-20b');
    assert.equal(body.messages.length, 1);
    assert.equal(body.messages[0].role, 'user');
    assert.equal(typeof body.messages[0].content, 'string');
    assert.ok(body.messages[0].content.includes('smoothie'));
    assert.equal(body.temperature, 0.2);
    assert.equal(body.max_completion_tokens, 1024);
    assert.equal(body.reasoning_effort, 'low');
    assert.equal(body.include_reasoning, false);
    assert.ok(!Object.hasOwn(body, 'reasoning_format'));
    assert.ok(!options.body.includes(fakeKey));
    return {ok: true, status: 200, json: async () => ({choices: [{finish_reason: 'stop', message: {
      content: `Banana smoothie\nBlend banana and milk. ${fakeKey}\x1b`,
    }}]})};
  }, 0, 'SUCCESS: Groq connectivity confirmed.');
  for (const [status, explanation] of [
    [400, 'Bad request. Check the configured model and request parameters.'],
    [401, 'Authentication failed. Check GROQ_API_KEY in this terminal.'],
    [403, 'Access forbidden. Check account and model permissions.'],
    [404, 'Endpoint or model not found. Check the configured endpoint and model.'],
    [429, 'Rate limit or quota reached. Try again later.'],
    [500, 'Groq server error. Try again later.'],
    [502, 'Groq server error. Try again later.'],
    [503, 'Groq server error. Try again later.'],
    [599, 'Groq server error. Try again later.'],
    [418, 'Unexpected HTTP response.'],
  ]) {
    await t.test(`HTTP ${status} has an exact safe diagnosis`, async () => {
      let sensitiveReads = 0;
      const messages = [];
      const sensitive = () => { sensitiveReads++; return fakeKey; };
      const code = await run({fetchImpl: async () => ({status, ok: false,
        json: sensitive, text: sensitive,
        get headers() { return sensitive(); },
        get statusText() { return sensitive(); },
      }), out: (v) => messages.push(v), error: (v) => messages.push(v)});
      assert.equal(code, 1);
      assert.deepEqual(messages, [`Groq test failed: HTTP ${status}: ${explanation}`]);
      assert.equal(sensitiveReads, 0);
    });
  }
  await check(async () => ({ok: false, status: fakeKey}), 1, 'Invalid HTTP response');
  await check(async () => { throw Error(fakeKey); }, 1, 'Network request failed');
  await check(async () => { throw {name: 'TimeoutError', message: fakeKey}; }, 1, 'timed out');
  await check(async () => { throw {name: 'AbortError', message: fakeKey}; }, 1, 'timed out');
  for (const name of ['TimeoutError', 'AbortError']) {
    await check(async () => ({ok: true,
      json: async () => { throw {name, message: fakeKey}; }}), 1, 'timed out');
  }
  await check(async () => ({ok: true, json: async () => { throw Error(fakeKey); }}),
    1, 'Invalid response');
  for (const data of [null, {}, {choices: [{message: {content: ' '}}]}]) {
    await check(async () => ({ok: true, json: async () => data}), 1, 'Invalid response');
  }
  for (const [name, finish, content, expected] of [
    ['reasoning-only exhaustion', 'length', null, 'Completion token limit reached'],
    ['partial answer exhaustion', 'length', 'partial recipe', 'Completion token limit reached'],
    ['reasoning without answer', 'stop', null, 'Final recipe text is missing'],
    ['empty answer', 'stop', '', 'content=empty'],
    ['whitespace answer', 'stop', '  ', 'content=empty'],
    ['invalid content type', 'stop', ['not text'], 'content=invalid-type'],
    ['oversized answer', 'stop', 'x'.repeat(10001), 'local output length limit'],
    ['terminal controls only', 'stop', '\x1b', 'no printable text'],
    ['filtered answer', 'content_filter', null, 'Completion was filtered'],
    ['unexpected tool', 'tool_calls', null, 'Unexpected tool/function response'],
    ['unexpected function', 'function_call', null, 'Unexpected tool/function response'],
    ['missing finish', undefined, 'answer', 'finish=missing'],
    ['untrusted finish', fakeKey, 'answer', 'finish=unknown'],
  ]) {
    await t.test(`safe completion diagnosis: ${name}`, async () => {
      const messages = [];
      const code = await run({fetchImpl: async () => ({ok: true, status: 200,
        json: async () => ({choices: [{finish_reason: finish, message: {
          content, reasoning: `PRIVATE_REASONING ${fakeKey}`,
        }}]})}), out: (v) => messages.push(v), error: (v) => messages.push(v)});
      assert.equal(code, 1);
      assert.equal(messages.length, 1);
      assert.ok(messages[0].includes(expected));
      assert.ok(messages[0].includes('HTTP=200'));
      assert.ok(messages[0].includes('reasoning_present=true'));
      for (const secret of [fakeKey, 'PRIVATE_REASONING', 'partial recipe', 'answer']) {
        assert.ok(!messages[0].includes(secret));
      }
    });
  }
  await t.test('reasoning is never printed with a valid final recipe', async () => {
    const messages = [];
    assert.equal(await run({fetchImpl: async () => ({ok: true, status: 200,
      json: async () => ({choices: [{finish_reason: 'stop', message: {
        content: 'Banana smoothie: blend banana, milk, oats and ice.',
        reasoning: `PRIVATE_REASONING ${fakeKey}`,
      }}]})}), out: (v) => messages.push(v), error: (v) => messages.push(v)}), 0);
    assert.deepEqual(messages, ['SUCCESS: Groq connectivity confirmed.\n\n' +
      'Banana smoothie: blend banana, milk, oats and ice.']);
  });
});
