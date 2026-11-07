import {decode, encodeWrite, fieldPath} from './firestore-codec.mjs';
import {failure} from './http.mjs';
const root = 'projects/velora-spark-test/databases/(default)/documents';
const endpoint = 'https://firestore.googleapis.com/v1/' + root;
export function createFirestoreStore({http, accessToken, attempts = 3, now = Date.now,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), random = Math.random}) {
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > 5) throw failure('configuration');
  const name = path => {
    if (typeof path !== 'string' || path.length > 1024 || path.split('/').length % 2 ||
        path.split('/').some(p => !p || p === '.' || p === '..' || /[\\%?#\x00-\x1f]/.test(p))) throw failure('invalid-path');
    return root + '/' + path;
  };
  async function rpc(method, data, committing = false) {
    let r;
    try { r = await http(endpoint + ':' + method, {method: 'POST',
      headers: {authorization: `Bearer ${await accessToken()}`, 'content-type': 'application/json'}, body: JSON.stringify(data)}); }
    catch { throw failure(committing ? 'outcome-unknown' : 'unavailable', committing); }
    if (r.status !== 200) {
      if (r.data?.error?.status === 'ABORTED' && r.status === 409) throw failure('aborted');
      if (r.status === 403) throw failure('permission-denied');
      throw failure(committing ? 'outcome-unknown' : 'unavailable', committing);
    }
    return r.data;
  }
  async function runTransaction(callback) {
    const start = now();
    for (let attempt = 0; attempt < attempts; attempt++) {
      let transaction; let committing = false;
      try {
        const begin = await rpc('beginTransaction', {options: {readWrite: {}}});
        if (typeof begin.transaction !== 'string' || !begin.transaction || begin.transaction.length > 8192) throw failure();
        transaction = begin.transaction;
        const writes = []; const written = new Set();
        const checkRead = () => { if (writes.length) throw failure('read-after-write'); };
        const document = d => {
          if (!d || typeof d.name !== 'string' || !d.name.startsWith(root + '/') || !d.fields) throw failure('invalid-response');
          return decode({mapValue: {fields: d.fields}});
        };
        const stage = (path, write) => {
          const full = name(path); if (written.has(full) || writes.length >= 100) throw failure('invalid-write');
          written.add(full); writes.push(write(full));
        };
        const tx = {
          async get(path) {
            checkRead(); const full = name(path);
            const rows = await rpc('batchGet', {documents: [full], transaction});
            if (!Array.isArray(rows)) throw failure('invalid-response');
            const hits = rows.filter(r => r.found || r.missing);
            if (hits.length !== 1) throw failure('invalid-response');
            if (hits[0].missing === full) return null;
            if (hits[0].found?.name !== full) throw failure('invalid-response');
            return document(hits[0].found);
          },
          create(path, data) { const value = encodeWrite(data); stage(path, full => ({update: {name: full, fields: value.fields},
            currentDocument: {exists: false}, ...(value.transforms.length ? {updateTransforms: value.transforms} : {})})); },
          update(path, data) { const value = encodeWrite(data); stage(path, full => ({update: {name: full, fields: value.fields},
            updateMask: {fieldPaths: Object.keys(value.fields).map(fieldPath)}, currentDocument: {exists: true},
            ...(value.transforms.length ? {updateTransforms: value.transforms} : {})})); },
          delete(path) { stage(path, full => ({delete: full, currentDocument: {exists: true}})); },
        };
        async function query(cafeId, collection, limit) {
          checkRead(); name(`cafes/${cafeId}`);
          if (!Number.isInteger(limit) || limit < 1 || limit > 101) throw failure('invalid-query');
          // runQuery is scoped to a validated parent, not a collection-group query.
          const parent = endpoint + '/cafes/' + encodeURIComponent(cafeId) + ':runQuery';
          const r = await http(parent, {method: 'POST', headers: {authorization: `Bearer ${await accessToken()}`,
            'content-type': 'application/json'}, body: JSON.stringify({transaction, structuredQuery: {from: [{collectionId: collection}], limit}})});
          if (r.status !== 200 || !Array.isArray(r.data)) throw failure();
          const docs = r.data.filter(row => row.document).map(row => {
            const d = row.document; const prefix = root + `/cafes/${cafeId}/${collection}/`;
            if (!d.name?.startsWith(prefix) || d.name.slice(prefix.length).includes('/')) throw failure('invalid-response');
            return {id: d.name.slice(prefix.length), data: document(d)};
          });
          if (docs.length > limit) throw failure('invalid-response'); return docs;
        }
        tx.inventory = (cafe, limit) => query(cafe, 'inventory', limit);
        tx.members = (cafe, limit) => query(cafe, 'members', limit);
        const result = await callback(tx);
        if (now() - start >= 20000) throw failure('deadline-exceeded');
        committing = true;
        const committed = await rpc('commit', {transaction, writes}, true);
        if (!Array.isArray(committed.writeResults) || committed.writeResults.length !== writes.length || typeof committed.commitTime !== 'string') {
          throw failure('outcome-unknown', true);
        }
        return result;
      } catch (error) {
        if (transaction && !error.uncertain) { try { await rpc('rollback', {transaction}); } catch {} }
        if (error.code === 'aborted' && attempt + 1 < attempts && now() - start < 20000) {
          await sleep(20 + Math.floor(random() * 80)); continue;
        }
        throw failure(error.code ?? 'unavailable', error.uncertain ?? committing);
      }
    }
  }
  // Absence is never evidence that an earlier timed-out commit cannot still finish.
  async function recover({receiptPath, matches}) {
    if (typeof matches !== 'function') throw failure('configuration');
    return runTransaction(async tx => {
      const receipt = await tx.get(receiptPath);
      if (!receipt) return {state: 'unknown'};
      if (!await matches(receipt, tx)) throw failure('receipt-conflict');
      return {state: 'acknowledged', receipt};
    });
  }
  return {runTransaction, recover};
}
