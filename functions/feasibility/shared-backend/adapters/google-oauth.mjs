import {failure} from './http.mjs';
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
export function createOAuth({email, sign, http, now = Date.now}) {
  if (typeof email !== 'string' || !/^[a-z0-9-]+@velora-spark-test\.iam\.gserviceaccount\.com$/.test(email) ||
      typeof sign !== 'function' || typeof http !== 'function') throw failure('configuration');
  let cached; let pending;
  return async () => {
    if (cached && cached.until > now() + 60000) return cached.token;
    if (pending) return pending;
    pending = (async () => {
      const time = Math.floor(now() / 1000);
      const unsigned = `${encode({alg: 'RS256', typ: 'JWT'})}.${encode({iss: email,
        scope: 'https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/identitytoolkit',
        aud: 'https://oauth2.googleapis.com/token', iat: time, exp: time + 3600})}`;
      const signature = await sign(new TextEncoder().encode(unsigned));
      const assertion = `${unsigned}.${Buffer.from(signature).toString('base64url')}`;
      const r = await http('https://oauth2.googleapis.com/token', {method: 'POST',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: new URLSearchParams({grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion}).toString()});
      if (r.status !== 200 || r.data.token_type !== 'Bearer' || typeof r.data.access_token !== 'string' ||
          !/^[\x21-\x7e]{1,8192}$/.test(r.data.access_token) || !Number.isInteger(r.data.expires_in) ||
          r.data.expires_in <= 60 || r.data.expires_in > 3600) throw failure();
      cached = {token: r.data.access_token, until: now() + r.data.expires_in * 1000}; return cached.token;
    })();
    try { return await pending; } catch { cached = undefined; throw failure(); } finally { pending = undefined; }
  };
}
