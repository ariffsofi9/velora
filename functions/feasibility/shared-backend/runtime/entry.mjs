// Synthetic test controller only. Never deploy or connect this to an application.
import {createWorker} from '../worker.mjs';
import {createIdentity} from '../identity.mjs';
import fakes from '../../../test/helpers/shared-backend-fakes.cjs';
export default {async fetch(request) {
  const input = await request.json();
  if (input.scenario === 'output-limit') {
    const bounded = createWorker({verifyIdentity: async () => ({}), backend: async () => ({value: 'x'.repeat(65537)})});
    return bounded.fetch(new Request('https://offline.invalid/', {method: 'POST',
      headers: {'content-type': 'application/json', authorization: 'Bearer synthetic'}, body: '{}'}));
  }
  // Construct cryptographic fixtures during request execution, never module load.
  const f = fakes.fixture();
  // Synthetic fixture controls only; never derive request expectations from these.
  const setOwnerGeneration = async generation => {
    if (!Number.isSafeInteger(generation) || generation < 0) throw Error('Invalid fixture generation');
    await f.store.runTransaction(async tx => {
      tx.update('user_cafe_memberships/owner', {membershipGeneration: generation});
      tx.update('cafes/cafe/members/owner', {membershipGeneration: generation});
    });
  };
  if (Object.hasOwn(input, 'ownerGeneration')) await setOwnerGeneration(input.ownerGeneration);
  const operations = [];
  const transact = f.store.runTransaction.bind(f.store);
  f.store.runTransaction = action => transact(tx => action(new Proxy(tx, {
    get(target, method) {
      const member = target[method];
      if (typeof member !== 'function') return member;
      return (...args) => { operations.push({method, path: args[0]}); return member.apply(target, args); };
    },
  })));
  const logs = [];
  const original = console.error;
  console.error = (...args) => logs.push(args.map(String));
  try {
    if (input.account) Object.assign(f.accounts.owner, input.account);
    if (input.mode) f.mode(input.mode);
    const worker = createWorker({verifyIdentity: createIdentity(f.identity), backend: f.backend});
    const results = [];
    const requests = [];
    const call = async step => {
      if (Object.hasOwn(step, 'ownerGeneration')) await setOwnerGeneration(step.ownerGeneration);
      if (step.invitationPatch) await f.store.runTransaction(async tx => {
        const path = 'workspace_invitations/' + results[0].body.invitationId;
        const row = await tx.get(path);
        Object.assign(row, step.invitationPatch);
        for (const field of step.omitInvitationFields ?? []) delete row[field];
        tx.delete(path); tx.create(path, row);
      });
      const data = {...(step.data ?? {})};
      if (step.ticket) data.ticketId = results[0]?.body.ticketId;
      if (step.invite) data.code = results[step.invitationResultIndex ?? 0]?.body.code;
      if (step.revoke) data.invitationId = results[0]?.body.invitationId;
      if (step.failCommit) f.store.failCommit = true;
      const start = operations.length;
      requests.push({path: step.path, data: structuredClone(data)});
      const response = await worker.fetch(new Request('https://offline.invalid' + step.path, {
        method: 'POST', headers: {'content-type': 'application/json', authorization: `Bearer ${f.token(step.uid ?? 'owner', step.claims ?? {})}`},
        body: step.raw ?? JSON.stringify(data)}));
      return {status: response.status, body: await response.json(), operations: operations.slice(start)};
    };
    for (const step of input.steps ?? []) {
      if (step.parallel) results.push(...await Promise.all(step.parallel.map(call)));
      else results.push(await call(step));
    }
    const state = f.store.snapshot();
    // Return only synthetic test diagnostics. Never return raw headers or credentials.
    return Response.json({results, requests, calls: f.calls.length, state,
      secretLeak: JSON.stringify({results, logs, calls: f.calls}).includes(f.secret)});
  } finally { console.error = original; }
}};
