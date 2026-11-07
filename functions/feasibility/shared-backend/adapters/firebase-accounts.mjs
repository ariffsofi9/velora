import {failure} from './http.mjs';
export function createAccounts({http, accessToken}) {
  return async uid => {
    try {
      if (typeof uid !== 'string' || !uid || uid.length > 128) throw failure();
      const r = await http('https://identitytoolkit.googleapis.com/v1/projects/velora-spark-test/accounts:lookup', {
        method: 'POST', headers: {authorization: `Bearer ${await accessToken()}`, 'content-type': 'application/json'},
        body: JSON.stringify({localId: [uid]})});
      const users = r.data?.users;
      if (r.status !== 200 || !Array.isArray(users) || users.length !== 1) throw failure();
      const u = users[0];
      if (u.localId !== uid || (u.disabled !== undefined && typeof u.disabled !== 'boolean') ||
          u.disabled === true || u.emailVerified !== true || typeof u.email !== 'string' ||
          !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(u.email) || !/^\d+$/.test(u.validSince ?? '') ||
          !Number.isSafeInteger(Number(u.validSince)) || Number(u.validSince) > 253402300799) throw failure();
      return {uid, disabled: false, emailVerified: true, email: u.email,
        tokensValidAfterTime: new Date(Number(u.validSince) * 1000).toISOString()};
    } catch { throw failure('unauthenticated'); }
  };
}
