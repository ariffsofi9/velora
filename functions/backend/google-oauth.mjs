import {BackendError, bounded, requireTestProject, validBudget} from './backend-errors.mjs';
import {OAUTH_URL} from './google-http.mjs';

const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const tokenShape = value => typeof value === 'string' && value.trim() === value &&
  /^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(value);

// A signer is injected for offline qualification only. Selecting/creating a live
// credential or service-account key is a separate activation decision.
export function createGoogleOAuth({projectId, email, sign, http, now = Date.now,
  timeoutMs = 5000} = {}) {
  requireTestProject(projectId);
  if (typeof email !== 'string' || email.trim() !== email ||
      !new RegExp(`^[a-z0-9-]{1,64}@${projectId}\\.iam\\.gserviceaccount\\.com$`).test(email) ||
      typeof sign !== 'function' || typeof http !== 'function' || http.projectId !== projectId ||
      typeof now !== 'function' || !validBudget(timeoutMs)) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  let cached, pending;
  function clock() {
    const time = now();
    if (!Number.isSafeInteger(time) || time < 0 || time > 253402297199000) throw Error();
    return time;
  }
  const accessToken = async () => {
    try {
      const start = clock();
      if (cached && start >= cached.issued && cached.until > start + 60000) return cached.token;
      if (!pending) {
        let active = true;
        const flight = bounded(async () => {
          const seconds = Math.floor(start / 1000);
          const unsigned = `${encode({alg: 'RS256', typ: 'JWT'})}.${encode({iss: email,
            scope: 'https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/identitytoolkit',
            aud: OAUTH_URL, iat: seconds, exp: seconds + 3600})}`;
          const signature = await sign(new TextEncoder().encode(unsigned));
          if (!(signature instanceof Uint8Array) || signature.length < 256 || signature.length > 1024) throw Error();
          // A signer that finishes after the deadline must not dispatch OAuth.
          if (!active || clock() < start || clock() - start >= timeoutMs) throw Error();
          const assertion = `${unsigned}.${Buffer.from(signature).toString('base64url')}`;
          const r = await http(OAUTH_URL, {method: 'POST',
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: new URLSearchParams({grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion}).toString()});
          const data = r.data;
          if (r.status !== 200 || !data || data.token_type !== 'Bearer' || !tokenShape(data.access_token) ||
              !Number.isSafeInteger(data.expires_in) || data.expires_in <= 60 || data.expires_in > 3600 ||
              !active || clock() < start || clock() - start >= timeoutMs) throw Error();
          // Request start is conservative: response latency never extends TTL.
          return {token: data.access_token, issued: start, until: start + data.expires_in * 1000};
        }, timeoutMs, 'oauth').finally(() => { active = false; });
        pending = flight;
        // Cache only the winning bounded promise; a late response cannot cache.
        flight.then(value => { cached = value; }, () => { cached = undefined; })
          .finally(() => { if (pending === flight) pending = undefined; });
      }
      const value = await pending;
      if (clock() < value.issued || clock() + 60000 >= value.until) throw Error();
      return value.token;
    } catch {
      throw new BackendError('oauth', 'unavailable');
    }
  };
  return Object.freeze(Object.assign(accessToken, {projectId}));
}
