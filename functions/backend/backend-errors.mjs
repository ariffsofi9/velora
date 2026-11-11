// Public failures contain no dependency messages, URLs, bodies or credentials.
export class BackendError extends Error {
  constructor(kind, code, outcomeUnknown = false) {
    super(code);
    this.name = 'BackendError';
    this.kind = kind;
    this.code = code;
    this.outcomeUnknown = outcomeUnknown;
    this.uncertain = outcomeUnknown;
  }
}

export function requireTestProject(projectId) {
  if (projectId !== 'velora-spark-test') throw new BackendError('configuration', 'invalid-configuration');
  return projectId;
}

// Also bounds injected work that ignores cancellation. Late completions cannot
// resume the caller. No retries and no dependency exception retention.
export async function bounded(action, timeoutMs, kind, code = 'unavailable') {
  let timer;
  try {
    return await Promise.race([
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new BackendError(kind, code)), timeoutMs);
      }),
      Promise.resolve().then(action),
    ]);
  } catch {
    throw new BackendError(kind, code);
  } finally {
    clearTimeout(timer);
  }
}

export function validBudget(ms) {
  return Number.isInteger(ms) && ms >= 1 && ms <= 15000;
}
