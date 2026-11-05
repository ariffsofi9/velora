'use strict';
const {PROJECT, RecipeError} = require('./recipe-service');

// Request-bound token: never stored in the cached service or sent to the provider.
async function verifyRequestIdentity(auth, uid, identity) {
  try {
    if (!identity || identity.uid !== uid || typeof identity.bearer !== 'string' || !identity.bearer) throw Error();
    const token = await auth.verifyIdToken(identity.bearer, true);
    if (token.uid !== uid || token.sub !== uid || token.aud !== PROJECT ||
        token.iss !== `https://securetoken.google.com/${PROJECT}` ||
        !Number.isSafeInteger(token.auth_time) || token.auth_time < 0) throw Error();
    // Retain an explicit disabled-account check, independent of SDK behavior.
    const user = await auth.getUser(uid);
    if (user.disabled) throw Error();
    if (user.tokensValidAfterTime != null) {
      const validAfter = Date.parse(user.tokensValidAfterTime);
      if (!Number.isFinite(validAfter) || token.auth_time * 1000 < validAfter) throw Error();
    }
  } catch (_) {
    throw new RecipeError('unauthenticated', 'Disposable identity is invalid, disabled or revoked.');
  }
}
module.exports = {verifyRequestIdentity};
