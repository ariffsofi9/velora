'use strict';

// Local only: no Firebase imports, dotenv loading, files, or automatic retries.
// From the repository root: node .\functions\scripts\test-groq-local.js
async function run({fetchImpl = globalThis.fetch, out = console.log,
  error = console.error} = {}) {
  const key = process.env.GROQ_API_KEY?.trim();
  const fail = (message) => {
    error(`Groq test failed: ${message}`);
    return 1;
  };
  if (!key) return fail('Set GROQ_API_KEY in this terminal first.');
  if (typeof fetchImpl !== 'function') return fail('Use Node.js 22 or newer.');

  try {
    const response = await fetchImpl('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      redirect: 'error',
      signal: AbortSignal.timeout(20000),
      headers: {'Content-Type': 'application/json', Authorization: `Bearer ${key}`},
      body: JSON.stringify({
        // Groq retired Llama 3.1 8B for free/developer tiers on 2026-08-16.
        // https://console.groq.com/docs/deprecations
        model: 'openai/gpt-oss-20b',
        messages: [{role: 'user', content:
          'Suggest one simple cafe banana oat smoothie for one serving. ' +
          'Use banana, oats, milk and ice. Give a title, quantities and three short steps. ' +
          'Keep the whole recipe under 150 words.'}],
        temperature: 0.2,
        reasoning_effort: 'low',
        include_reasoning: false,
        max_completion_tokens: 1024,
      }),
    });
    if (!response.ok) {
      const status = response.status;
      const explanations = {
        400: 'Bad request. Check the configured model and request parameters.',
        401: 'Authentication failed. Check GROQ_API_KEY in this terminal.',
        403: 'Access forbidden. Check account and model permissions.',
        404: 'Endpoint or model not found. Check the configured endpoint and model.',
        429: 'Rate limit or quota reached. Try again later.',
      };
      // Only print a validated numeric status and locally defined text.
      if (!Number.isInteger(status) || status < 100 || status > 599) {
        return fail('Invalid HTTP response from Groq.');
      }
      const explanation = explanations[status] ?? (status >= 500 ?
        'Groq server error. Try again later.' : 'Unexpected HTTP response.');
      return fail(`HTTP ${status}: ${explanation}`);
    }

    let data;
    try {
      data = await response.json();
    } catch (cause) {
      if (cause?.name === 'TimeoutError' || cause?.name === 'AbortError') throw cause;
      return fail('Invalid response: Groq response could not be parsed as JSON.');
    }
    const choice = Array.isArray(data?.choices) ? data.choices[0] : undefined;
    const recipe = choice?.message?.content;
    const knownReasons = ['stop', 'length', 'content_filter', 'tool_calls', 'function_call'];
    const finish = knownReasons.includes(choice?.finish_reason) ? choice.finish_reason :
      choice?.finish_reason == null ? 'missing' : 'unknown';
    const content = typeof recipe === 'string' ?
      (recipe.trim() ? 'text' : 'empty') : recipe == null ? 'missing' : 'invalid-type';
    // Only locally defined labels, booleans, and validated numbers reach diagnostics.
    // Never use reasoning as a recipe or print any provider-supplied error text.
    const status = Number.isInteger(response.status) && response.status >= 100 &&
      response.status <= 599 ? response.status : 'unknown';
    const metadata = `HTTP=${status}; finish=${finish}; content=${content}; ` +
      `content_length=${typeof recipe === 'string' ? recipe.length : 0}; ` +
      `reasoning_present=${typeof choice?.message?.reasoning === 'string' &&
        choice.message.reasoning.length > 0}`;
    const invalid = (why) => fail(`Invalid response: ${why} (${metadata}).`);
    if (finish === 'length') {
      return invalid('Completion token limit reached; no complete recipe received');
    }
    if (finish === 'content_filter') return invalid('Completion was filtered');
    if (finish === 'tool_calls' || finish === 'function_call') {
      return invalid('Unexpected tool/function response; no recipe accepted');
    }
    if (finish !== 'stop') return invalid('Missing or unrecognized completion finish reason');
    if (content !== 'text') return invalid('Final recipe text is missing, empty or invalid');
    if (recipe.length > 10000) return invalid('Recipe exceeds the local output length limit');
    // Never echo the credential, even if an upstream response unexpectedly includes it.
    // Remove terminal controls (including ESC) from model-generated text.
    const safeRecipe = recipe.split(key).join('[REDACTED]')
        .replace(/[\x00-\x08\x0B-\x1F\x7F-\x9F]/g, '');
    if (!safeRecipe.trim()) return invalid('Recipe contains no printable text');
    out(`SUCCESS: Groq connectivity confirmed.\n\n${safeRecipe.trim()}`);
    return 0;
  } catch (cause) {
    // Do not print exceptions, request headers, keys, or provider error bodies.
    return fail(cause?.name === 'TimeoutError' || cause?.name === 'AbortError' ?
      'Request timed out. Try again later.' :
      'Network request failed. Check your connection and try again.');
  }
}

if (require.main === module) {
  run().then((code) => { process.exitCode = code; }).catch(() => {
    console.error('Groq test failed: Unexpected local error.');
    process.exitCode = 1;
  });
}

module.exports = {run};
