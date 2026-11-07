import test from 'node:test';
import assert from 'node:assert/strict';
import {encode, decode, encodeWrite, SERVER_TIME} from './firestore-codec.mjs';
import {createFirestoreStore} from './firestore-store.mjs';
globalThis.fetch = () => { throw Error('Unexpected network'); };
test('codec roundtrips safe values and rejects unsupported numeric/value shapes', () => {
  const value = {text: 'Rice', count: 3, fraction: 1.5, date: new Date(0), bool: true, nil: null, list: ['a', 2]};
  assert.deepEqual(decode(encode(value)), value);
  for (const bad of [NaN, Infinity, 9007199254740992, undefined, [[1]], new Map()]) assert.throws(() => encode(bad));
  for (const bad of [{integerValue: '9007199254740992'}, {doubleValue: 'NaN'}, {booleanValue: 'true'}, {referenceValue: 'x'}, {stringValue:'x',nullValue:null}]) assert.throws(() => decode(bad));
  assert.equal(encodeWrite({createdAt: SERVER_TIME}).transforms[0].setToServerValue, 'REQUEST_TIME');
});
function fixture(mode = 'ok') {
  const requests = []; let commits = 0;
  const store = createFirestoreStore({accessToken: async () => 'synthetic', sleep: async () => {}, random: () => 0,
    http: async (url, request) => {
      const body = JSON.parse(request.body); requests.push({url, body});
      if (url.endsWith(':beginTransaction')) return {status: 200, data: {transaction: 'synthetic'}};
      if (url.endsWith(':rollback')) return {status: 200, data: {}};
      if (url.endsWith(':batchGet')) return {status: 200, data: [{missing: body.documents[0]}]};
      if (url.endsWith(':commit')) {
        commits++;
        if (mode === 'unknown') throw Error('private');
        if (mode === 'conflict' && commits === 1) return {status: 409, data: {error: {status: 'ABORTED'}}};
        if (mode === 'denied') return {status: 403, data: {}};
        return {status: 200, data: {commitTime: new Date(0).toISOString(), writeResults: body.writes.map(() => ({}))}};
      }
      throw Error('Unexpected request');
    }});
  return {store, requests, commits: () => commits};
}
test('atomic linked create writes have preconditions and audit transforms', async () => {
  const f = fixture();
  await f.store.runTransaction(async tx => { assert.equal(await tx.get('links/missing'), null);
    tx.create('links/a', {uid: 'a', createdAt: SERVER_TIME}); tx.create('links/b', {uid: 'a'}); });
  const commit = f.requests.find(r => r.url.endsWith(':commit')).body;
  assert.equal(commit.writes.length, 2); assert.deepEqual(commit.writes[0].currentDocument, {exists: false});
  assert.equal(commit.writes[0].updateTransforms[0].setToServerValue, 'REQUEST_TIME');
});
test('definite conflict retries full callback; unknown commit never retries or rolls back', async () => {
  const f = fixture('conflict'); let callbacks = 0;
  await f.store.runTransaction(async tx => { callbacks++; tx.update('links/a', {value: 1}); });
  assert.equal(callbacks, 2); assert.equal(f.commits(), 2);
  const u = fixture('unknown');
  await assert.rejects(u.store.runTransaction(async tx => tx.create('links/a', {x: 1})), e => e.uncertain && e.code === 'outcome-unknown');
  assert.equal(u.commits(), 1); assert.ok(!u.requests.some(r => r.url.endsWith(':rollback')));
  assert.deepEqual(await fixture().store.recover({receiptPath: 'receipts/a', matches: () => true}), {state: 'unknown'});
});
test('callback failure rolls back without commit; read-after-write and IAM denied', async () => {
  const f = fixture(); await assert.rejects(f.store.runTransaction(async tx => { tx.create('links/a', {x: 1}); await tx.get('links/b'); }));
  assert.equal(f.commits(), 0); assert.ok(f.requests.some(r => r.url.endsWith(':rollback')));
  await assert.rejects(fixture('denied').store.runTransaction(async tx => tx.create('links/a', {})), /permission-denied/);
});
test('receipt recovery validates linked records in the same transaction', async () => {
  const store = createFirestoreStore({accessToken: async () => 'synthetic', http: async (url, request) => {
    const body = JSON.parse(request.body);
    if (url.endsWith(':beginTransaction')) return {status:200,data:{transaction:'synthetic'}};
    if (url.endsWith(':batchGet')) return {status:200,data:[{found:{name:body.documents[0],fields:encode({uid:'owner'}).mapValue.fields}}]};
    if (url.endsWith(':commit')) return {status:200,data:{writeResults:[],commitTime:new Date(0).toISOString()}};
    return {status:200,data:{}};
  }});
  const result = await store.recover({receiptPath:'receipts/a', matches:async (receipt,tx) => receipt.uid === (await tx.get('links/a')).uid});
  assert.equal(result.state,'acknowledged');
  await assert.rejects(store.recover({receiptPath:'receipts/a',matches:()=>false}), /receipt-conflict/);
});
