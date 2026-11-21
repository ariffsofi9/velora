// Stdio fixture for Flutter widget tests. No ports, network client or deployment.
import {createInterface} from 'node:readline';
import {createInventoryWorker, inventoryOrigin} from './inventory-entry.mjs';
import {syntheticIdentity} from '../integration/synthetic-identity.mjs';
import restModule from '../../../test/helpers/shared-firestore-rest-fake.cjs';
import {CERTIFICATE_URL, OAUTH_URL} from '../../../backend/google-http.mjs';

globalThis.fetch = () => { throw Error('External network is disabled'); };

const projectId = 'velora-spark-test';
const databaseId = '(default)';
const cafeId = 'synthetic-cafe';
const ownerUid = 'synthetic-owner';
const uid = 'synthetic-staff';
const generation = 7;
const now = () => Date.UTC(2026, 10, 20);
const identity = syntheticIdentity(now);
const account = {localId: uid, email: `${uid}@example.test`,
  emailVerified: true, disabled: false, validSince: '0'};
const records = {[`cafes/${cafeId}`]: {ownerUid, status: 'active', schemaVersion: 1}};
for (const [memberUid, role] of [[ownerUid, 'owner'], [uid, 'staff']]) {
  const link = {uid: memberUid, cafeId, status: 'active', schemaVersion: 1,
    membershipGeneration: generation};
  records[`user_cafe_memberships/${memberUid}`] = link;
  records[`cafes/${cafeId}/members/${memberUid}`] = {...link, role};
}
const store = restModule.createRestFake(records);
const accountUrl = `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`;
const fireStoreRpc = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/${databaseId}/documents:`;
const worker = createInventoryWorker({projectId, databaseId, now, sign: identity.sign,
  async transport(url, options) {
    if (url === CERTIFICATE_URL) return Response.json({synthetic: identity.certificate},
      {headers: {'cache-control': 'max-age=3600'}});
    if (url === OAUTH_URL) {
      identity.verifyAssertion(options.body);
      return Response.json({access_token: 'synthetic-access', token_type: 'Bearer', expires_in: 3600});
    }
    if (options.headers.authorization !== 'Bearer synthetic-access') throw Error('Unexpected OAuth identity');
    if (url === accountUrl) {
      const [requestedUid] = JSON.parse(options.body).localId;
      return Response.json({users: requestedUid === uid ? [account] : []});
    }
    if (url.startsWith(fireStoreRpc)) return store.transport(url, options);
    throw Error('Unexpected synthetic destination');
  },
});

const send = data => process.stdout.write(JSON.stringify(data) + '\n');
send({projectId, cafeId, uid, ownerUid, generation, bearer: identity.token(uid)});

for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) {
  try {
    const input = JSON.parse(line);
    const url = new URL(input.url);
    if (url.origin !== inventoryOrigin) throw Error('Unexpected fixture origin');
    if (input.loseCommitResponse === true) store.commitModes.push('applied-lost');
    const response = await worker.fetch(new Request(url, {
      method: input.method, headers: input.headers, body: input.body,
    }));
    const commits = store.calls.filter(call => call.method === 'commit');
    send({status: response.status, headers: Object.fromEntries(response.headers),
      body: await response.text(), writeCommits: commits.filter(call => call.body.writes.length).length,
      lastWriteCount: commits.at(-1)?.body.writes.length ?? 0});
  } catch {
    send({bridgeError: true});
  }
}
