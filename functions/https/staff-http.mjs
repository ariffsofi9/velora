import team from '../src/team-members.js';
import removal from '../src/membership-removal.js';
import {BackendError, bounded, validBudget} from '../backend/backend-errors.mjs';
import {createAuthenticatedJsonHttp, DOMAIN_HTTP_STATUSES} from './authenticated-json-http.mjs';

const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  value.trim() === value && !['.', '..'].includes(value) && !/[\\/\p{Cc}]/u.test(value);

// Fresh account enrichment is private, bounded and outside retryable callbacks.
// Scalar S5.32 lookups are batched with a maximum of four concurrent requests.
function accountBatch(getAccount, timeoutMs) {
  return async uids => {
    if (!Array.isArray(uids) || !uids.length || uids.length > 101 ||
        uids.some(uid => !id(uid)) || new Set(uids).size !== uids.length) throw new BackendError('account', 'unavailable');
    const requested = [...uids], profiles = new Map();
    let active = true, cursor = 0;
    try {
      return await bounded(async () => {
        const worker = async () => {
          try {
            while (active && cursor < requested.length) {
              const uid = requested[cursor++], user = await getAccount(uid);
              if (!active || !user || user.uid !== uid || user.disabled !== false || user.emailVerified !== true ||
                  typeof user.email !== 'string' || user.email.length > 254 ||
                  !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(user.email) || /\p{Cc}/u.test(user.email) || user.email.trim() !== user.email) throw Error();
              profiles.set(uid, {uid, disabled: false, emailVerified: true, email: user.email,
                ...(typeof user.displayName === 'string' && user.displayName.length <= 80 && !/\p{Cc}/u.test(user.displayName)
                  ? {displayName: user.displayName} : {})});
            }
          } catch { active = false; throw Error(); }
        };
        await Promise.all(Array.from({length: Math.min(4, requested.length)}, worker));
        if (!active || profiles.size !== requested.length) throw Error();
        return requested.map(uid => profiles.get(uid));
      }, timeoutMs, 'account');
    } finally { active = false; }
  };
}

export function createStaffHttp({projectId, storeProjectId, verifyIdentity, store, timestamp, getAccount,
  accountTimeoutMs = 5000, verificationTimeoutMs = 5000, bodyTimeoutMs = 5000,
  cleanupTimeoutMs = 100, scheduleTimeout} = {}) {
  if (typeof store?.runTransaction !== 'function' || store.projectId !== projectId || store.capabilities?.serverTimestamps !== true ||
      typeof timestamp !== 'function' || typeof getAccount !== 'function' || getAccount.projectId !== projectId ||
      !validBudget(accountTimeoutMs)) throw Error('Explicit project-bound Staff dependencies required');
  const accounts = accountBatch(getAccount, accountTimeoutMs);
  return createAuthenticatedJsonHttp({projectId, storeProjectId, verifyIdentity,
    verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    maxRequestBytes: 2048, domainStatuses: {...DOMAIN_HTTP_STATUSES, aborted: 409},
    domainErrorTypes: [team.TeamMembersError, removal.MembershipRemovalError],
    routes: new Map([
      ['/staff/list', ({auth, data}) => team.listTeamMembers({auth, data, store, accounts})],
      // Preserve expectedActorGeneration and expectedGeneration as independent
      // canonical preconditions; do not translate them to inventory envelopes.
      ['/staff/remove', ({auth, data}) => removal.removeStaffMember({auth, data, store, timestamp})],
    ])});
}
