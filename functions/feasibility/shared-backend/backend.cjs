'use strict';
const {createSecureGroqHandler} = require('../../src/secure-groq-handler');
const invitations = require('../../src/workspace-invitations');
const {listTeamMembers} = require('../../src/team-members');
const {removeStaffMember} = require('../../src/membership-removal');
const {activeMembershipGeneration} = require('../../src/membership-generation');
const reject = code => { const e = new Error(code); e.code = code; throw e; };
function createBackend({store, getAccount, transport, getSecret, now = Date.now, timeoutMs = 30}) {
  const ai = createSecureGroqHandler({store, getAccount, transport, getSecret, now, timeoutMs});
  async function scope(auth) {
    return store.runTransaction(async tx => {
      const map = await tx.get(`user_cafe_memberships/${auth.uid}`);
      const cafeId = map?.cafeId;
      if (typeof cafeId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(cafeId)) reject('permission-denied');
      const cafe = await tx.get(`cafes/${cafeId}`);
      const member = await tx.get(`cafes/${cafeId}/members/${auth.uid}`);
      const owner = cafe?.ownerUid;
      if (typeof owner !== 'string' || cafe.status !== 'active' || cafe.schemaVersion !== 1) reject('permission-denied');
      const ownerMap = await tx.get(`user_cafe_memberships/${owner}`);
      const ownerMember = await tx.get(`cafes/${cafeId}/members/${owner}`);
      const generation = activeMembershipGeneration(map, member, auth.uid, cafeId, owner);
      if (generation === null || activeMembershipGeneration(ownerMap, ownerMember, owner, cafeId, owner) === null ||
          !['owner', 'staff'].includes(member?.role) || (member.role === 'owner') !== (owner === auth.uid) ||
          ownerMember?.role !== 'owner') reject('permission-denied');
      return {cafeId, generation};
    });
  }
  return async (path, auth, data) => {
    if (Object.hasOwn(data, 'operation')) reject('invalid-argument');
    // Redemption is the sole operation allowed before canonical membership exists.
    if (path !== '/staff/redeem') await scope(auth);
    const common = {auth, data, store, now: () => new Date(now()), toTimestamp: d => d};
    switch (path) {
      case '/ai/issue': return ai({auth, data: {...data, operation: 'issue'}});
      case '/ai/generate': return ai({auth, data: {...data, operation: 'generate'}});
      case '/staff/create': return invitations.createStaffInvitation(common);
      case '/staff/revoke': return invitations.revokeStaffInvitation(common);
      case '/staff/redeem': return invitations.redeemStaffInvitation(common);
      case '/staff/remove': return removeStaffMember({...common, timestamp: () => new Date(now())});
      case '/staff/list': return listTeamMembers({...common,
        accounts: ids => Promise.all(ids.map(getAccount))});
      default: reject('not-found');
    }
  };
}
module.exports = {createBackend};
