import {BackendError, requireTestProject, validBudget} from './backend-errors.mjs';

const expiryReserveMs = 60_000;
const maxLifetimeSeconds = 3600;
const unavailable = () => new BackendError('oauth', 'unavailable');
const validToken = token => typeof token === 'string' &&
  /^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(token) && token.trim() === token;

/**
 * The trusted source must be injected explicitly. It receives an AbortSignal
 * and returns the OAuth response shape: access_token, token_type, expires_in.
 * The callable returned here also accepts an optional per-caller AbortSignal
 * via accessToken({signal}). One caller cannot cancel another caller's refresh.
 */
export function createWorkloadAccessToken({projectId, acquire, now = Date.now, timeoutMs = 5000} = {}) {
  requireTestProject(projectId);
  if (typeof acquire !== 'function' || typeof now !== 'function' || !validBudget(timeoutMs)) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  let cached, pending, lastTime;

  function clock() {
    const time = now();
    if (!Number.isSafeInteger(time) || time < 0 || time > 253402297199000) throw unavailable();
    const previous = lastTime;
    lastTime = time;
    if (previous !== undefined && time < previous) {
      cached = undefined;
      pending?.controller.abort();
      throw unavailable();
    }
    return time;
  }

  function fresh(value, time) {
    return time >= value.issued && time + expiryReserveMs < value.until &&
      performance.now() + expiryReserveMs < value.monotonicUntil;
  }

  function refresh(issued) {
    const controller = new AbortController();
    const {signal} = controller;
    const started = performance.now();
    const flight = {controller, waiters: 0};
    pending = flight;
    flight.result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      const onAbort = () => {
        clearTimeout(timer);
        reject(unavailable());
      };
      signal.addEventListener('abort', onAbort, {once: true});
      const acquireToken = async () => {
        try {
          signal.throwIfAborted();
          const response = await acquire({signal});
          signal.throwIfAborted();
          const {access_token: token, token_type: type, expires_in: lifetime} = response ?? {};
          const completed = clock();
          if (type !== 'Bearer' || !validToken(token) || !Number.isSafeInteger(lifetime) ||
              lifetime <= expiryReserveMs / 1000 || lifetime > maxLifetimeSeconds ||
              completed < issued || completed - issued >= timeoutMs ||
              performance.now() - started >= timeoutMs) throw unavailable();
          const value = {token, issued, until: issued + lifetime * 1000, monotonicUntil: started + lifetime * 1000};
          if (!fresh(value, completed) || signal.aborted) throw unavailable();
          cached = value;
          resolve(value);
        } catch {
          reject(unavailable());
        } finally {
          clearTimeout(timer);
          signal.removeEventListener('abort', onAbort);
          pending = undefined;
        }
      };
      // Keep the slot until acquisition actually settles, even if its caller
      // has already timed out and the source does not cooperate with abort.
      void Promise.resolve().then(acquireToken);
    });
    return flight;
  }

  async function waitFor(flight, signal) {
    let onAbort, released = false;
    flight.waiters++;
    function release() {
      if (released) return;
      released = true;
      if (onAbort) signal.removeEventListener('abort', onAbort);
      if (--flight.waiters === 0 && pending === flight) flight.controller.abort();
    }
    try {
      if (!signal) return await flight.result;
      return await new Promise((resolve, reject) => {
        onAbort = () => {
          release();
          reject(unavailable());
        };
        signal.addEventListener('abort', onAbort, {once: true});
        flight.result.then(resolve, reject);
      });
    } finally {
      release();
    }
  }

  const accessToken = async ({signal} = {}) => {
    try {
      if (signal !== undefined && !(signal instanceof AbortSignal)) throw unavailable();
      signal?.throwIfAborted();
      const time = clock();
      if (cached && fresh(cached, time)) return cached.token;
      cached = undefined;
      const flight = pending ?? refresh(time);
      if (flight.controller.signal.aborted) throw unavailable();
      const value = await waitFor(flight, signal);
      signal?.throwIfAborted();
      if (!fresh(value, clock())) throw unavailable();
      return value.token;
    } catch {
      throw unavailable();
    }
  };
  return Object.freeze(Object.assign(accessToken, {projectId}));
}
