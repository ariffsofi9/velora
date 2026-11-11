'use strict';
const assert = require('node:assert/strict');
const root = 'projects/velora-spark-test/databases/(default)/documents';
const instant = '2026-11-11T00:00:00.123456789Z';
const json = (data, status = 200) => Response.json(data, {status});
const nativeError = (status, code) => json({error: {code: status, status: code, message: 'SYNTHETIC PRIVATE DETAIL'}}, status);

// Independent wire implementation: never imports the adapter or its codec.
function encode(value) {
  if (value === null) return {nullValue: null};
  if (value instanceof Date) return {timestampValue: value.toISOString()};
  if (Array.isArray(value)) return {arrayValue: {values: value.map(encode)}};
  if (typeof value === 'object') return {mapValue: {fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)]))}};
  if (typeof value === 'number') return Number.isInteger(value) ? {integerValue: String(value)} : {doubleValue: value};
  return {[typeof value === 'boolean' ? 'booleanValue' : 'stringValue']: value};
}
function decode(value) {
  assert.equal(Object.keys(value).length, 1);
  if ('integerValue' in value) return Number(value.integerValue);
  if ('timestampValue' in value) return new Date(value.timestampValue);
  if ('mapValue' in value) return Object.fromEntries(Object.entries(value.mapValue.fields ?? {}).map(([k, v]) => [k, decode(v)]));
  if ('arrayValue' in value) return (value.arrayValue.values ?? []).map(decode);
  return Object.values(value)[0];
}
function literal(path) {
  assert.match(path, /^`(?:[^`\\]|\\[`\\])+`$/);
  return path.slice(1, -1).replace(/\\([`\\])/g, '$1');
}
function createRestFake(seed = {}) {
  let records = structuredClone(seed), revision = 0, serial = 0;
  const transactions = new Map(), calls = [], hooks = {}, commitModes = [];
  const snapshot = () => structuredClone(records);
  const replace = (path, value) => { if (value === undefined) delete records[path]; else records[path] = structuredClone(value); revision++; };
  const resource = path => `${root}/${path}`;
  const doc = (path, data) => ({name: resource(path), fields: encode(data).mapValue.fields,
    createTime: instant, updateTime: instant});
  const relative = name => { assert.ok(name.startsWith(root + '/')); return name.slice(root.length + 1); };
  async function transport(url, options) {
    const parsed = new URL(url);
    assert.equal(parsed.origin, 'https://firestore.googleapis.com');
    assert.equal(options.method, 'POST');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.authorization, 'Bearer synthetic-access');
    assert.equal(options.headers['content-type'], 'application/json');
    const method = parsed.pathname.slice(parsed.pathname.lastIndexOf(':') + 1);
    const body = JSON.parse(options.body);
    const call = {method, url, body}; calls.push(call);
    if (hooks[method]) {
      const response = await hooks[method](call);
      if (response !== undefined) return response;
    }
    if (method === 'beginTransaction') {
      assert.equal(parsed.pathname, `/v1/${root}:beginTransaction`);
      assert.deepEqual(body, {options: {readWrite: {}}});
      const transaction = Buffer.from(`synthetic-tx-${++serial}`).toString('base64');
      transactions.set(transaction, {records: snapshot(), revision});
      return json({transaction});
    }
    assert.equal(typeof body.transaction, 'string');
    const tx = transactions.get(body.transaction);
    assert.ok(tx, 'all RPCs must use the exact live transaction');
    if (method === 'rollback') {
      assert.equal(parsed.pathname, `/v1/${root}:rollback`);
      transactions.delete(body.transaction); return json({});
    }
    if (method === 'batchGet') {
      assert.equal(parsed.pathname, `/v1/${root}:batchGet`);
      assert.deepEqual(Object.keys(body).sort(), ['documents', 'transaction']);
      assert.equal(body.documents.length, 1);
      const path = relative(body.documents[0]);
      return json([{...(Object.hasOwn(tx.records, path) ? {found: doc(path, tx.records[path])} : {missing: resource(path)}),
        readTime: instant}]);
    }
    if (method === 'runQuery') {
      assert.deepEqual(Object.keys(body).sort(), ['structuredQuery', 'transaction']);
      const match = parsed.pathname.match(/\/documents\/cafes\/([^/]+):runQuery$/);
      assert.ok(match);
      const cafeId = decodeURIComponent(match[1]), q = body.structuredQuery;
      assert.deepEqual(q.orderBy, [{field: {fieldPath: '__name__'}, direction: 'ASCENDING'}]);
      assert.equal(q.from.length, 1);
      assert.deepEqual(Object.keys(q.from[0]), ['collectionId']);
      const collection = q.from[0].collectionId;
      assert.ok(['members', 'inventory', 'menu_items'].includes(collection));
      assert.ok(Number.isInteger(q.limit) && q.limit > 0 && q.limit <= 101);
      const prefix = `cafes/${cafeId}/${collection}/`;
      let rows = Object.entries(tx.records).filter(([path]) => path.startsWith(prefix) && !path.slice(prefix.length).includes('/'));
      if (q.where) {
        assert.equal(collection, 'menu_items');
        assert.deepEqual(q.where, {fieldFilter: {field: {fieldPath: 'isArchived'}, op: 'EQUAL', value: {booleanValue: false}}});
        rows = rows.filter(([, data]) => data.isArchived === false);
      }
      rows.sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
      if (q.startAt) {
        assert.equal(q.startAt.before, false);
        assert.equal(q.startAt.values.length, 1);
        const cursor = q.startAt.values[0].referenceValue;
        assert.ok(cursor.startsWith(resource(prefix)));
        rows = rows.filter(([path]) => Buffer.compare(Buffer.from(resource(path)), Buffer.from(cursor)) > 0);
      }
      rows = rows.slice(0, q.limit);
      return json(rows.length ? rows.map(([path, data]) => ({document: doc(path, data), readTime: instant})) : [{readTime: instant}]);
    }
    assert.equal(method, 'commit');
    assert.equal(parsed.pathname, `/v1/${root}:commit`);
    assert.deepEqual(Object.keys(body).sort(), ['transaction', 'writes']);
    const mode = commitModes.shift();
    if (mode === 'abort' || tx.revision !== revision) return nativeError(409, 'ABORTED');
    if (mode === 'lost') throw Error('SYNTHETIC LOST RESPONSE');
    if (mode === 'reject') return nativeError(403, 'PERMISSION_DENIED');
    const draft = structuredClone(records), results = [];
    for (const write of body.writes) {
      if (write.delete) {
        assert.deepEqual(write.currentDocument, {exists: true});
        const path = relative(write.delete);
        if (!Object.hasOwn(draft, path)) return nativeError(400, 'FAILED_PRECONDITION');
        delete draft[path]; results.push({}); continue;
      }
      assert.ok(write.update);
      const path = relative(write.update.name), exists = Object.hasOwn(draft, path);
      if (write.currentDocument?.exists === false && exists) return nativeError(409, 'ALREADY_EXISTS');
      if (write.currentDocument?.exists === true && !exists) return nativeError(400, 'FAILED_PRECONDITION');
      const fields = write.update.fields;
      const target = write.updateMask ? {...draft[path]} : {};
      if (write.updateMask) {
        assert.deepEqual(write.currentDocument, {exists: true});
        for (const mask of write.updateMask.fieldPaths) {
          const key = literal(mask);
          if (Object.hasOwn(fields, key)) Object.defineProperty(target, key, {value: decode(fields[key]), enumerable: true, configurable: true, writable: true});
          else delete target[key];
        }
        for (const key of Object.keys(fields)) assert.ok(write.updateMask.fieldPaths.includes('`' + key.replaceAll('\\', '\\\\').replaceAll('`', '\\`') + '`'));
      } else {
        for (const [key, value] of Object.entries(fields)) Object.defineProperty(target, key, {value: decode(value), enumerable: true, configurable: true, writable: true});
      }
      const transforms = [];
      for (const transform of write.updateTransforms ?? []) {
        assert.equal(transform.setToServerValue, 'REQUEST_TIME');
        assert.equal(Object.keys(transform).length, 2);
        const key = literal(transform.fieldPath);
        assert.equal(Object.hasOwn(fields, key), false);
        assert.equal(write.updateMask?.fieldPaths.includes(transform.fieldPath) ?? false, false);
        Object.defineProperty(target, key, {value: new Date(instant), enumerable: true, configurable: true, writable: true});
        transforms.push({timestampValue: instant});
      }
      draft[path] = target;
      results.push({updateTime: instant, ...(transforms.length ? {transformResults: transforms} : {})});
    }
    records = draft;
    if (body.writes.length) revision++;
    transactions.delete(body.transaction);
    if (mode === 'applied-lost') throw Error('SYNTHETIC LOST RESPONSE');
    if (mode === 'malformed') return json({commitTime: 'not-a-time', writeResults: results});
    if (mode === 'bad-transform') return json({commitTime: instant,
      writeResults: results.map(row => ({...row, transformResults: []}))});
    return json({commitTime: instant, ...(results.length ? {writeResults: results} : {})});
  }
  return {transport, calls, hooks, commitModes, snapshot, replace, doc, resource, json, nativeError, instant};
}
module.exports = {createRestFake};
