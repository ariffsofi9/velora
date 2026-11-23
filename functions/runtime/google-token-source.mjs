import {WorkerEntrypoint} from 'cloudflare:workers';
import {OAUTH_PROTOCOL_VERSION} from '../backend/pre-auth-settlement.mjs';

const project = 'velora-73222';
const tokenEndpoint = 'https://oauth2.googleapis.com/token';
const scopes = 'https://www.googleapis.com/auth/identitytoolkit https://www.googleapis.com/auth/datastore';
const signingAlgorithm = 'RSASSA-PKCS1-v1_5';
const timeoutMs = 3000;
const refreshMarginSeconds = 65; // The consumer keeps its own 60-second reserve.
const maxRefreshes = 2;
const maxBytes = 16_384;
const encoder = new TextEncoder();
const unavailable = () => new Error('unavailable');

// Only completed token values cross invocations. Each refresh owns its I/O.
let credentialVersion, cached;
let activeRefreshes = 0;

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function wallTime() {
  const time = Date.now();
  if (!Number.isSafeInteger(time) || time < 0 || time > 253402297199000) throw unavailable();
  return time;
}

function remaining(token, wall, monotonic) {
  if (!token || wall < token.issued || monotonic < token.started) return 0;
  return Math.floor((token.lifetimeMs - Math.max(wall - token.issued, monotonic - token.started)) / 1000);
}

async function signAssertion(secret, issued) {
  const credential = JSON.parse(secret);
  if (credential?.type !== 'service_account' || credential.project_id !== project ||
      typeof credential.client_email !== 'string' ||
      credential.client_email.trim() !== credential.client_email ||
      !/^[a-z0-9-]{1,64}@velora-73222\.iam\.gserviceaccount\.com$/.test(credential.client_email) ||
      typeof credential.private_key !== 'string') throw unavailable();
  const pem = /^-----BEGIN PRIVATE KEY-----\r?\n([A-Za-z0-9+/=\r\n]+)\r?\n-----END PRIVATE KEY-----\r?\n?$/
    .exec(credential.private_key);
  if (!pem) throw unavailable();
  const bytes = Uint8Array.from(atob(pem[1]), character => character.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', bytes, {name: signingAlgorithm, hash: 'SHA-256'}, false, ['sign']);
  if (key.algorithm.modulusLength < 2048 || key.algorithm.modulusLength > 4096) throw unavailable();
  const iat = Math.floor(issued / 1000);
  const header = {alg: 'RS256', typ: 'JWT'};
  const claims = {iss: credential.client_email, scope: scopes, aud: tokenEndpoint, iat, exp: iat + 300};
  const unsigned = [header, claims].map(value => base64url(encoder.encode(JSON.stringify(value)))).join('.');
  const signature = await crypto.subtle.sign(signingAlgorithm, key, encoder.encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

async function readTokenResponse(response, signal, boundary) {
  if (response.status !== 200 || response.redirected || response.url !== tokenEndpoint) {
    await response.body?.cancel();
    throw unavailable();
  }
  const reader = response.body?.getReader();
  if (!reader) throw unavailable();
  const decoder = new TextDecoder('utf-8', {fatal: true});
  let size = 0, json = '';
  let ended = false;
  try {
    for (;;) {
      signal.throwIfAborted();
      const {done, value} = await reader.read();
      if (done) { ended = !signal.aborted; break; }
      size += value.byteLength;
      if (size > maxBytes) throw unavailable();
      json += decoder.decode(value, {stream: true});
    }
    return JSON.parse(json + decoder.decode());
  } finally {
    try { await reader.cancel(); }
    finally { reader.releaseLock(); }
    if (ended) boundary.observed = true;
  }
}

async function exchange(secret, issued, started, signal, boundary) {
  function checkDeadline() {
    signal.throwIfAborted();
    const now = wallTime();
    if (now < issued || now - issued >= timeoutMs || performance.now() - started >= timeoutMs) throw unavailable();
  }

  const assertion = await signAssertion(secret, issued);
  checkDeadline();
  boundary.observed = false;
  const response = await fetch(tokenEndpoint, {
    method: 'POST', redirect: 'manual', signal,
    headers: {'content-type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion}),
  });
  const {access_token: token, token_type: type, expires_in: lifetime} = await readTokenResponse(response, signal, boundary);
  checkDeadline();
  if (type !== 'Bearer' || typeof token !== 'string' || token.trim() !== token ||
      !/^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(token) ||
      !Number.isSafeInteger(lifetime) || lifetime <= 60 || lifetime > 3600) throw unavailable();
  return {token, issued, started, lifetimeMs: lifetime * 1000};
}

async function refresh(version, issued, started, observe) {
  if (activeRefreshes >= maxRefreshes) throw unavailable();
  activeRefreshes++;
  const controller = new AbortController();
  let timer;
  try {
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(unavailable());
      }, timeoutMs);
    });
    // Keep the slot occupied until the underlying work settles even after timeout.
    const boundary = {observed: true};
    const work = exchange(version.secret, issued, started, controller.signal, boundary).finally(() => activeRefreshes--);
    if (observe) observe(work.then(() => boundary.observed, () => boundary.observed));
    return await Promise.race([work, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

// Local qualification can observe underlying work through this module function.
// The named RPC accepts only the project and never exposes observation promises.
export async function acquireGoogleToken(env, projectId, observe) {
  try {
    if (projectId !== project) throw unavailable();
    const secret = env.VELORA_GOOGLE_SERVICE_ACCOUNT_KEY;
    if (typeof secret !== 'string' || !secret.length || secret.length > maxBytes) {
      credentialVersion = undefined;
      cached = undefined;
      throw unavailable();
    }
    if (secret !== credentialVersion?.secret) {
      credentialVersion = {secret};
      cached = undefined;
    }
    const version = credentialVersion;
    const issued = wallTime();
    const started = performance.now();
    let value = cached;
    let expires = remaining(value, issued, started);
    if (expires <= refreshMarginSeconds) {
      cached = undefined;
      value = await refresh(version, issued, started, observe);
      expires = remaining(value, wallTime(), performance.now());
      if (version !== credentialVersion || expires <= 60) throw unavailable();
      if (expires > refreshMarginSeconds && (!cached || value.started >= cached.started)) cached = value;
    }
    return {projectId: project, access_token: value.token, token_type: 'Bearer', expires_in: expires};
  } catch {
    throw unavailable();
  }
}

export class GoogleTokenSource extends WorkerEntrypoint {
  async acquire(projectId) {
    if (projectId !== project) throw unavailable();
    return acquireGoogleToken(this.env, projectId);
  }

  trackedOAuthVersion() {
    return this.env.OAUTH_ACK ? OAUTH_PROTOCOL_VERSION : null;
  }

  async acquireTracked(projectId, version, id) {
    if (projectId !== project || version !== OAUTH_PROTOCOL_VERSION ||
        typeof id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(id)) throw unavailable();
    const ack = this.env.OAUTH_ACK;
    if (!ack) throw unavailable();
    try {
      const grant = await ack.start(version, id);
      if (typeof grant !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(grant)) throw unavailable();
      let completion;
      try {
        const result = await acquireGoogleToken(this.env, projectId, work => { completion = work; });
        return result;
      } finally {
        if (completion === undefined || await completion) {
          if (await ack.acknowledge(version, id, grant) !== 'settled') throw unavailable();
        }
      }
    } catch {
      throw unavailable();
    }
  }
}

// Wrangler needs a default export to bundle a module Worker. RPC stays named-only.
export default {};
