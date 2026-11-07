// Synthetic test controller only. Never deploy or connect this to an application.
import {createWorker} from '../worker.mjs';
import {createIdentity} from '../identity.mjs';
import fakes from '../../../test/helpers/shared-backend-fakes.cjs';
export default {async fetch(request) {
  const input = await request.json();
  if (input.scenario === 'egress') {
    try { const response = await fetch('https://unexpected.invalid/');
      return Response.json({blocked: response.status >= 500, outboundStatus: response.status}); }
    catch { return Response.json({blocked: true}); }
  }
  if (input.scenario === 'output-limit') {
    const bounded = createWorker({verifyIdentity: async () => ({}), backend: async () => ({value: 'x'.repeat(65537)})});
    return bounded.fetch(new Request('https://offline.invalid/', {method: 'POST',
      headers: {'content-type': 'application/json', authorization: 'Bearer synthetic'}, body: '{}'}));
  }
  // Construct cryptographic fixtures during request execution, never module load.
  const f = fakes.fixture();
  const logs = [];
  const original = console.error;
  console.error = (...args) => logs.push(args.map(String));
  try {
    if (input.account) Object.assign(f.accounts.owner, input.account);
    if (input.mode) f.mode(input.mode);
    const worker = createWorker({verifyIdentity: createIdentity(f.identity), backend: f.backend});
    const results = [];
    const call = async step => {
      const data = {...(step.data ?? {})};
      if (step.ticket) data.ticketId = results[0]?.body.ticketId;
      if (step.invite) data.code = results[0]?.body.code;
      if (step.revoke) data.invitationId = results[0]?.body.invitationId;
      if (step.failCommit) f.store.failCommit = true;
      const response = await worker.fetch(new Request('https://offline.invalid' + step.path, {
        method: 'POST', headers: {'content-type': 'application/json', authorization: `Bearer ${f.token(step.uid ?? 'owner', step.claims ?? {})}`},
        body: step.raw ?? JSON.stringify(data)}));
      return {status: response.status, body: await response.json()};
    };
    for (const step of input.steps ?? []) {
      if (step.parallel) results.push(...await Promise.all(step.parallel.map(call)));
      else results.push(await call(step));
    }
    const state = f.store.snapshot();
    // Return only synthetic test diagnostics. Never return raw headers or credentials.
    return Response.json({results, calls: f.calls.length, state,
      secretLeak: JSON.stringify({results, logs, calls: f.calls}).includes(f.secret)});
  } finally { console.error = original; }
}};
