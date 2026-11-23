import {createApplication} from '../backend/application.mjs';
import {createRealWorkerAccess, REAL_PROJECT_ID} from '../backend/backend-errors.mjs';
import {exactHttpsOrigin} from '../backend/http-policy.mjs';
import {createWorkloadAccessToken} from '../backend/workload-access-token.mjs';
import {recordAdmission} from '../backend/admission-telemetry.mjs';
import {createPreAuthSettlement, OAUTH_PROTOCOL_VERSION} from '../backend/pre-auth-settlement.mjs';
import {attemptWindowMs, uuid, unavailable, unavailableResponse, projectFor, integer,
  namespaceFor} from './admission-coordinator.mjs';

export {AdmissionCoordinator, OAuthAcknowledgement} from './admission-coordinator.mjs';

async function rpc(action, timeoutMs, signal) {
  if (signal?.aborted) throw unavailable();
  let timer, onAbort;
  try {
    return await Promise.race([new Promise((_, reject) => {
      onAbort = () => reject(unavailable());
      timer = setTimeout(onAbort, timeoutMs);
      signal?.addEventListener('abort', onAbort, {once: true});
    }), Promise.resolve().then(() => {
      if (signal?.aborted) throw unavailable();
      return action();
    })]);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }
}

export function createWorkerAdmission(env) {
  const projectId = projectFor(env);
  const namespace = namespaceFor(env);
  const objectId = namespace.idFromName(projectId);
  const timeoutMs = integer(env.ADMISSION_RPC_TIMEOUT_MS, 1000, 5000);
  const tracked = projectId === REAL_PROJECT_ID && env.VELORA_DURABLE_OAUTH === 'true';
  return Object.freeze({projectId, async acquire(signal) {
    const attempt = crypto.randomUUID();
    const replayUntil = Date.now() + attemptWindowMs;
    const stub = namespace.get(objectId);
    const token = await rpc(() => stub.reserve(attempt, replayUntil), timeoutMs, signal);
    if (token === null) return null;
    if (!uuid(token)) throw unavailable();
    let expectedTracked = false;
    const release = () => rpc(() => namespace.get(objectId).finish(attempt, token, expectedTracked), timeoutMs);
    const finish = async () => {
      try {
        let result;
        try { result = await release(); }
        catch {
          // A lost acknowledgement can follow a successful release. Retry once
          // with a fresh stub and the same pair, which SQLite can close only once.
          result = await release();
        }
        if (projectId === REAL_PROJECT_ID) {
          recordAdmission(result === true ? 'release-acknowledged' : 'release-unconfirmed');
        }
        return result;
      } catch (error) {
        if (projectId === REAL_PROJECT_ID) recordAdmission('release-unconfirmed');
        throw error;
      }
    };
    try {
      if (await rpc(() => stub.claim(attempt, token), timeoutMs, signal) !== true || signal?.aborted) throw unavailable();
    } catch {
      // This invocation never dispatched work. Closing the exact token is safe
      // whether claim ran, is still pending, or never reached the coordinator.
      try { await finish(); } catch { /* No dispatch, and no unsafe slot reuse. */ }
      throw unavailable();
    }
    // Only this successful claim can mint the local tracker for this pair.
    const preAuth = projectId === REAL_PROJECT_ID ? createPreAuthSettlement() : undefined;
    const acquireOAuth = tracked ? async signal => {
      const source = env.VELORA_GOOGLE_TOKEN_SOURCE;
      if (await rpc(() => source.trackedOAuthVersion(), timeoutMs, signal) !== OAUTH_PROTOCOL_VERSION) throw unavailable();
      signal.throwIfAborted();
      if (expectedTracked || preAuth.status() !== 'open') throw unavailable();
      expectedTracked = true;
      const id = await rpc(() => stub.registerOAuth(attempt, token), timeoutMs, signal);
      if (!uuid(id)) throw unavailable();
      signal.throwIfAborted();
      if (preAuth.status() !== 'open') throw unavailable();
      const response = await source.acquireTracked(projectId, OAUTH_PROTOCOL_VERSION, id);
      signal.throwIfAborted();
      if (response?.projectId !== projectId) throw unavailable();
      return response;
    } : undefined;
    return Object.freeze({finish, preAuth, acquireOAuth, async attribute(uid, requestSignal) {
      if (typeof uid !== 'string' || !uid.length || uid.length > 128 || requestSignal?.aborted) throw unavailable();
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${projectId}\0${uid}`));
      const uidKey = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
      return rpc(() => stub.attribute(attempt, token, uidKey), timeoutMs, requestSignal);
    }});
  }});
}

const denyDependency = async () => { throw unavailable(); };
export function createWorkerApplication(env, testDependencies) {
  const projectId = projectFor(env);
  const publicOrigin = env.VELORA_PUBLIC_ORIGIN;
  const admission = createWorkerAdmission(env);
  if (projectId === REAL_PROJECT_ID) {
    const source = env.VELORA_GOOGLE_TOKEN_SOURCE;
    if (testDependencies !== undefined || !exactHttpsOrigin(publicOrigin) || typeof source?.acquire !== 'function') {
      throw unavailable();
    }
    const {hostname, port} = new URL(publicOrigin);
    if (port || !/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/.test(hostname) ||
        hostname.endsWith('.invalid') || hostname.endsWith('.localhost')) throw unavailable();

    // This private binding is explicitly provisioned by the operator. Never
    // pass request data, discover ambient credentials or accept a static token.
    const acquire = Object.assign(async ({signal}) => {
      signal.throwIfAborted();
      const response = await source.acquire(projectId);
      signal.throwIfAborted();
      if (response?.projectId !== projectId) throw unavailable();
      return response;
    }, {projectId});
    const realWorker = createRealWorkerAccess({projectId, acquire, admission});
    return createApplication({projectId, realWorker, publicOrigin, allowedOrigins: [publicOrigin], admission,
      enableLocalFrontend: env.VELORA_ENABLE_LOCAL_FRONTEND === 'true',
      createRealAccessToken: createWorkloadAccessToken,
      // Workers support manual redirects. The Google adapter rejects every 3xx
      // and unexpected response URL without replaying the original request.
      transport: (url, init) => fetch(url, {...init, redirect: 'manual'})});
  }
  const {transport = denyDependency, accessToken} = testDependencies ?? {};
  return createApplication({projectId, publicOrigin, allowedOrigins: [publicOrigin], transport,
    accessToken: accessToken ?? Object.assign(() => denyDependency(), {projectId}),
    admission});
}

let application, bindingSnapshot;
export default {async fetch(request, env, ctx) {
  try {
    // Isolates can survive a bindings-only release. Do not retain the previous
    // origin, coordinator or credential binding after the new values arrive.
    const bindings = [env.VELORA_ENVIRONMENT, env.VELORA_FIREBASE_PROJECT, env.VELORA_PUBLIC_ORIGIN,
      env.VELORA_ENABLE_LOCAL_FRONTEND, env.ADMISSION, env.ADMISSION_RPC_TIMEOUT_MS,
      env.VELORA_GOOGLE_TOKEN_SOURCE, env.VELORA_DURABLE_OAUTH];
    if (!bindingSnapshot || bindings.some((value, index) => value !== bindingSnapshot[index])) {
      application = createWorkerApplication(env);
      bindingSnapshot = bindings;
    }
    return await application.fetch(request, work => ctx.waitUntil(work));
  } catch { return unavailableResponse(); }
}};
