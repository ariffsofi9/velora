// Offline composition only: no listener, identity/store defaults or credentials.
import invitations from '../src/workspace-invitations.js';
import {createAuthenticatedJsonHttp} from './authenticated-json-http.mjs';
import {BackendError, bounded, requireTestProject, validBudget} from '../backend/backend-errors.mjs';

// Internal factory, never an HTTP enumeration route. Email only locates a UID;
// the existing fresh, project-bound account directory validates that exact UID.
export function createInvitationAccountResolver({projectId, http, accessToken, getAccount, timeoutMs = 5000} = {}) {
  requireTestProject(projectId);
  if ([http, accessToken, getAccount].some(fn => typeof fn !== 'function' || fn.projectId !== projectId) ||
      !validBudget(timeoutMs)) throw new BackendError('configuration', 'invalid-configuration');
  const resolve = async email => {
    let active = true;
    try {
      return await bounded(async () => {
        if (typeof email !== 'string' || email.length > 254 || email.trim().toLowerCase() !== email ||
            !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /\p{Cc}/u.test(email)) throw Error();
        const token = await accessToken();
        if (!active || typeof token !== 'string' || token.trim() !== token ||
            !/^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(token)) throw Error();
        const r = await http(`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`, {
          method: 'POST', headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'},
          body: JSON.stringify({email: [email]})});
        if (!active || r.status !== 200 || !Array.isArray(r.data?.users) || r.data.users.length > 1) throw Error();
        if (!r.data.users.length) return null;
        const uid = r.data.users[0]?.localId;
        if (typeof uid !== 'string' || !uid || uid.length > 128 || uid.trim() !== uid ||
            ['.', '..'].includes(uid) || /[\\/\p{Cc}]/u.test(uid)) throw Error();
        const user = await getAccount(uid);
        if (!active || !user || user.uid !== uid || user.disabled !== false || user.emailVerified !== true ||
            typeof user.email !== 'string' || user.email.trim().toLowerCase() !== email) throw Error();
        return user;
      }, timeoutMs, 'account');
    } finally { active = false; }
  };
  return Object.freeze(Object.assign(resolve, {projectId}));
}

export function createInvitationHttp({projectId, storeProjectId, verifyIdentity, store, now,
  allowRejoin = false, resolveAccount, accountTimeoutMs = 5000,
  verificationTimeoutMs = 5000, bodyTimeoutMs = 5000, cleanupTimeoutMs = 100, scheduleTimeout}) {
  if (typeof store?.runTransaction !== 'function' || typeof now !== 'function') {
    throw Error('Explicit invitation dependencies required');
  }
  if (typeof allowRejoin !== 'boolean' || !validBudget(accountTimeoutMs) ||
      (allowRejoin && (typeof resolveAccount !== 'function' || resolveAccount.projectId !== projectId))) {
    throw Error('Explicit trusted rejoin dependencies required');
  }
  const resolve = allowRejoin ? email => bounded(() => resolveAccount(email), accountTimeoutMs, 'account') : undefined;
  const compose = operation => ({auth, data}) => operation({auth, data, store, now: () => {
    const time = now();
    if (!(time instanceof Date) || !Number.isFinite(time.getTime())) throw Error('Invalid clock');
    return time;
  }, allowRejoin, ...(resolve === undefined ? {} : {resolveAccount: resolve})});
  return createAuthenticatedJsonHttp({
    projectId, storeProjectId, verifyIdentity, verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    maxRequestBytes: 2048, domainErrorTypes: [invitations.InvitationError],
    routes: new Map([
      ['/staff/create', compose(invitations.createStaffInvitation)],
      ['/staff/revoke', compose(invitations.revokeStaffInvitation)],
      ['/staff/redeem', compose(invitations.redeemStaffInvitation)],
      ['/staff/reconcile', compose(invitations.reconcileStaffInvitation)],
    ]),
  });
}
