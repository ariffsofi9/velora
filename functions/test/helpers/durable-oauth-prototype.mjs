export {createOAuthLedger} from '../../backend/durable-oauth.mjs';

// Explicitly model an upstream response boundary separately from abort.
export async function runSyntheticTokenSource(source, id, transport, signal) {
  const grant = await source.start(id);
  let upstreamAttempted = false, bodyCompleted = false, cleaned = true;
  try {
    signal?.throwIfAborted();
    const cached = transport.cached();
    if (cached !== undefined) return cached;
    const assertion = await transport.sign();
    signal?.throwIfAborted();
    upstreamAttempted = true;
    const response = await transport.fetch(assertion, signal);
    cleaned = false;
    try {
      const token = await response.read();
      bodyCompleted = true;
      signal?.throwIfAborted();
      return token;
    } finally {
      await response.cleanup();
      cleaned = true;
    }
  } finally {
    // All execution paths have left the only dispatch site. An ambiguous
    // upstream failure or failed cleanup deliberately leaves the row started.
    if (!upstreamAttempted || (bodyCompleted && cleaned)) await source.acknowledge(id, grant);
  }
}
