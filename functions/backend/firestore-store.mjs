import {BackendError, requireTestProject, validBudget} from './backend-errors.mjs';
import {firestoreCafeSegment} from './google-http.mjs';
import {decode, encodeWrite, parseTimestamp, record, timestamp, toTimestamp, deleteValue} from './firestore-codec.mjs';

export class FirestoreStoreError extends BackendError {
  constructor(code, phase = 'precommit', unknown = false) {
    super('store', code, unknown);
    this.phase = phase;
  }
}
const invalid = code => { throw new FirestoreStoreError(code); };
const validId = id => typeof id === 'string' && id.isWellFormed() && id.length > 0 && id.length <= 128 &&
  id.trim() === id && !['.', '..'].includes(id) && !/[\\/%\p{Cc}]/u.test(id);
const validToken = token => typeof token === 'string' && token.trim() === token &&
  /^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(token);
const validTransaction = value => typeof value === 'string' && value.length > 0 && value.length <= 8192 &&
  Buffer.from(value, 'base64').toString('base64') === value;
const ownKeys = (value, keys) => record(value) && Object.keys(value).every(key => keys.includes(key));

// Unlike the generic dependency helper, preserve callback exception identity.
async function wait(action, ms, expired) {
  let timer;
  try {
    return await Promise.race([Promise.resolve().then(action), new Promise((_, reject) => {
      timer = setTimeout(() => reject(expired()), ms);
    })]);
  } finally { clearTimeout(timer); }
}

// Factories only: no SDK initialization, network default, recovery route or auth
// policy. Canonical callbacks own authority; native transactions enforce atomicity.
export function createFirestoreStore({projectId, databaseId = '(default)', http, accessToken,
  attempts = 3, timeoutMs = 20000, rpcTimeoutMs = 5000, cleanupTimeoutMs = 100,
  now = Date.now, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), random = Math.random} = {}) {
  requireTestProject(projectId);
  if (databaseId !== '(default)' || typeof http !== 'function' || http.projectId !== projectId ||
      typeof accessToken !== 'function' || accessToken.projectId !== projectId ||
      !Number.isInteger(attempts) || attempts < 1 || attempts > 3 ||
      !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 20000 ||
      !validBudget(rpcTimeoutMs) || !validBudget(cleanupTimeoutMs) ||
      typeof now !== 'function' || typeof sleep !== 'function' || typeof random !== 'function') {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const root = `projects/${projectId}/databases/${databaseId}/documents`;
  const endpoint = `https://firestore.googleapis.com/v1/${root}`;
  function name(path) {
    if (typeof path !== 'string' || path.length > 2048) invalid('invalid-path');
    const segments = path.split('/');
    if (segments.length < 2 || segments.length % 2 || !segments.every(validId)) invalid('invalid-path');
    return `${root}/${path}`;
  }
  function document(doc, expected) {
    if (!ownKeys(doc, ['name', 'fields', 'createTime', 'updateTime']) || doc.name !== expected ||
        !record(doc.fields === undefined ? {} : doc.fields) || !Object.hasOwn(doc, 'createTime') || !Object.hasOwn(doc, 'updateTime')) invalid('invalid-response');
    // Keep raw metadata strings intact; never use a rounded Date as a native
    // update-time precondition. Current writes use existence preconditions.
    parseTimestamp(doc.createTime); parseTimestamp(doc.updateTime);
    return decode({mapValue: {fields: doc.fields === undefined ? {} : doc.fields}});
  }
  async function rollback(transaction) {
    let active = true;
    try {
      await wait(async () => {
        const token = await accessToken();
        if (!active || !validToken(token)) return;
        await http(`${endpoint}:rollback`, {method: 'POST',
          headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'},
          body: JSON.stringify({transaction})});
      }, cleanupTimeoutMs, () => new FirestoreStoreError('cleanup-failed'));
    } catch { /* Cleanup cannot resolve uncertainty or replace the original error. */ }
    finally { active = false; }
  }
  async function runTransaction(callback) {
    if (typeof callback !== 'function') invalid('invalid-operation');
    const ctx = {active: true, committing: false, originalSet: false};
    function clock() {
      try {
        const time = now();
        if (!Number.isSafeInteger(time) || time < 0) throw Error();
        return time;
      } catch { throw new FirestoreStoreError('invalid-clock', ctx.committing ? 'unknown' : 'precommit', ctx.committing); }
    }
    const start = clock(), wall = performance.now();
    const aborts = new WeakSet();
    function expired() {
      ctx.active = false;
      return ctx.originalSet ? ctx.original : new FirestoreStoreError('deadline-exceeded',
        ctx.committing ? 'unknown' : 'precommit', ctx.committing);
    }
    function remaining() {
      const time = clock();
      if (time < start) throw new FirestoreStoreError('invalid-clock',
        ctx.committing ? 'unknown' : 'precommit', ctx.committing);
      return timeoutMs - Math.max(time - start, performance.now() - wall);
    }
    function check() { if (!ctx.active || remaining() <= 0) throw expired(); }
    async function rpc(method, data, queryUrl) {
      let active = true;
      const episode = ctx.episode;
      check();
      try {
        return await wait(async () => {
          const body = JSON.stringify(data);
          if (Buffer.byteLength(body) > 1048576) invalid('request-limit');
          const token = await accessToken();
          check();
          if (!active || episode !== ctx.episode ||
              (['batchGet', 'runQuery'].includes(method) && ctx.readsClosed)) invalid('transaction-closed');
          if (!validToken(token)) invalid('credential-unavailable');
          if (method === 'commit') ctx.committing = true;
          let r;
          try { r = await http(queryUrl ?? `${endpoint}:${method}`, {method: 'POST',
            headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'}, body,
            ...(method === 'commit' ? {mutation: true} : {}),
            ...(['batchGet', 'runQuery'].includes(method) ? {firestoreRpc: method} : {})}); }
          catch { throw new FirestoreStoreError('unavailable', ctx.committing ? 'unknown' : 'precommit', ctx.committing); }
          check();
          if (!active) throw Error();
          if (r.status === 200) return r.data;
          const error = r.data?.error;
          // Only an exact native HTTP status envelope from this RPC can prove a
          // definite abort. An exception merely named "aborted" never can.
          if (r.status === 409 && record(error) && error.code === 409 && error.status === 'ABORTED') {
            ctx.committing = false;
            const failure = new FirestoreStoreError('contention');
            aborts.add(failure); throw failure;
          }
          const definite = {400: ['INVALID_ARGUMENT', 'FAILED_PRECONDITION', 'OUT_OF_RANGE'], 401: ['UNAUTHENTICATED'],
            403: ['PERMISSION_DENIED'], 404: ['NOT_FOUND'], 409: ['ALREADY_EXISTS'],
            412: ['FAILED_PRECONDITION'], 429: ['RESOURCE_EXHAUSTED']};
          if (record(error) && error.code === r.status && definite[r.status]?.includes(error.status)) {
            ctx.committing = false;
            throw new FirestoreStoreError('native-rejected', method === 'commit' ? 'acknowledged' : 'precommit');
          }
          throw Error();
        }, Math.max(1, Math.min(rpcTimeoutMs, remaining())), () => new FirestoreStoreError('deadline-exceeded',
          ctx.committing ? 'unknown' : 'precommit', ctx.committing));
      } catch (error) {
        if (error instanceof FirestoreStoreError) throw error;
        throw new FirestoreStoreError('unavailable', ctx.committing ? 'unknown' : 'precommit', ctx.committing);
      } finally { active = false; }
    }
    async function perform() {
      for (let attempt = 0; attempt < attempts; attempt++) {
        check();
        ctx.committing = false;
        ctx.episode = (ctx.episode ?? 0) + 1;
        ctx.readsClosed = false;
        ctx.transaction = undefined;
        ctx.rollbackStarted = false;
        let transaction, open = true, pendingReads = 0, poison;
        const writes = [], written = new Set();
        const ensureOpen = () => { check(); if (!open) invalid('transaction-closed'); };
        const failRead = error => {
          const failure = error instanceof FirestoreStoreError ? error : new FirestoreStoreError('invalid-response');
          poison ??= failure; throw failure;
        };
        const read = action => {
          const task = (async () => {
            try {
              ensureOpen();
              if (writes.length) invalid('read-after-write');
              pendingReads++;
              try { const result = await action(); ensureOpen(); return result; }
              finally { pendingReads--; }
            } catch (error) { failRead(error); }
          })();
          // An unawaited read cannot commit or cause an unobserved rejection.
          task.catch(() => {});
          return task;
        };
        function metadata(row) {
          if (row.transaction !== undefined && row.transaction !== transaction) invalid('invalid-response');
          if (row.readTime !== undefined) parseTimestamp(row.readTime);
          if (row.skippedResults !== undefined && row.skippedResults !== 0) invalid('invalid-response');
        }
        function stage(path, kind, data) {
          try {
            ensureOpen();
            if (pendingReads) invalid('pending-reads');
            const full = name(path);
            if (written.has(full) || writes.length >= 100) invalid('invalid-write');
            let write;
            if (kind === 'delete') write = {delete: full, currentDocument: {exists: true}};
            else {
              const encoded = encodeWrite(data, kind);
              write = {update: {name: full, fields: encoded.fields},
                ...(kind === 'create' ? {currentDocument: {exists: false}} : {}),
                ...(kind === 'update' ? {currentDocument: {exists: true}, updateMask: {fieldPaths: encoded.mask}} : {}),
                ...(encoded.transforms.length ? {updateTransforms: encoded.transforms} : {})};
            }
            if (Buffer.byteLength(JSON.stringify([...writes, write])) > 1040000) invalid('request-limit');
            writes.push(write); written.add(full);
          } catch (error) {
            const failure = error instanceof FirestoreStoreError ? error : new FirestoreStoreError('invalid-write');
            poison ??= failure; throw failure;
          }
        }
        async function query(cafeId, collectionId, limit, input) {
          return read(async () => {
            const segment = firestoreCafeSegment(cafeId);
            if (!Number.isInteger(limit) || limit < 1 || limit > 101) invalid('invalid-query');
            const prefix = `${name(`cafes/${cafeId}`)}/${collectionId}/`;
            const structuredQuery = {from: [{collectionId}], orderBy: [{field: {fieldPath: '__name__'}, direction: 'ASCENDING'}], limit};
            if (input) {
              if (!input.includeArchived) structuredQuery.where = {fieldFilter: {
                field: {fieldPath: 'isArchived'}, op: 'EQUAL', value: {booleanValue: false}}};
              if (input.cursor !== null) structuredQuery.startAt = {
                values: [{referenceValue: prefix + input.cursor}], before: false};
            }
            const rows = await rpc('runQuery', {transaction, structuredQuery}, `${endpoint}/cafes/${segment}:runQuery`);
            if (!Array.isArray(rows) || rows.length > limit + 2) invalid('invalid-response');
            const result = [], seen = new Set();
            for (const row of rows) {
              if (!ownKeys(row, ['document', 'transaction', 'readTime', 'skippedResults', 'done'])) invalid('invalid-response');
              metadata(row);
              if (row.done !== undefined && typeof row.done !== 'boolean') invalid('invalid-response');
              if (!row.document) {
                if (row.readTime === undefined && row.transaction === undefined) invalid('invalid-response');
                continue;
              }
              const full = row.document.name;
              if (typeof full !== 'string' || !full.startsWith(prefix)) invalid('invalid-response');
              const id = full.slice(prefix.length);
              if (!validId(id) || seen.has(id) || (result.length && Buffer.compare(Buffer.from(result.at(-1).id), Buffer.from(id)) >= 0)) invalid('invalid-response');
              const data = document(row.document, full);
              if (input && ((!input.includeArchived && data.isArchived !== false) ||
                  (input.cursor !== null && Buffer.compare(Buffer.from(id), Buffer.from(input.cursor)) <= 0))) invalid('invalid-response');
              result.push({id, data}); seen.add(id);
            }
            if (result.length > limit) invalid('invalid-response');
            return result;
          });
        }
        const tx = Object.freeze({
          get: path => read(async () => {
            const full = name(path), rows = await rpc('batchGet', {documents: [full], transaction});
            if (!Array.isArray(rows) || rows.length < 1 || rows.length > 2) invalid('invalid-response');
            let found = false, result;
            for (const row of rows) {
              if (!ownKeys(row, ['found', 'missing', 'transaction', 'readTime'])) invalid('invalid-response');
              metadata(row);
              const hit = Object.hasOwn(row, 'found') || Object.hasOwn(row, 'missing');
              if (!hit) { if (row.transaction === undefined && row.readTime === undefined) invalid('invalid-response'); continue; }
              if (found || (Object.hasOwn(row, 'found') && Object.hasOwn(row, 'missing'))) invalid('invalid-response');
              found = true;
              if (Object.hasOwn(row, 'missing')) { if (row.missing !== full) invalid('invalid-response'); result = null; }
              else result = document(row.found, full);
            }
            if (!found) invalid('invalid-response');
            return result;
          }),
          create: (path, data) => stage(path, 'create', data),
          update: (path, data) => stage(path, 'update', data),
          set: (path, data) => stage(path, 'set', data),
          // Existence is required: no silent deletion of an already absent doc.
          delete: path => stage(path, 'delete'),
          members: (cafeId, limit) => query(cafeId, 'members', limit),
          inventory: (cafeId, limit) => query(cafeId, 'inventory', limit),
          menuItems: (cafeId, input) => {
            if (!ownKeys(input, ['includeArchived', 'limit', 'cursor']) ||
                typeof input.includeArchived !== 'boolean' || !Number.isInteger(input.limit) ||
                input.limit < 1 || input.limit > 50 || (input.cursor !== null && !validId(input.cursor))) {
              const failure = new FirestoreStoreError('invalid-query'); poison ??= failure; throw failure;
            }
            return query(cafeId, 'menu_items', input.limit + 1, input);
          },
        });
        try {
          const begin = await rpc('beginTransaction', {options: {readWrite: {}}});
          if (!ownKeys(begin, ['transaction']) || !validTransaction(begin.transaction)) invalid('invalid-response');
          transaction = begin.transaction;
          ctx.transaction = transaction;
          const result = await callback(tx);
          check();
          if (poison) throw poison;
          if (pendingReads) invalid('pending-reads');
          open = false;
          ctx.readsClosed = true;
          const committed = await rpc('commit', {transaction, writes});
          try {
            const results = committed?.writeResults === undefined && !writes.length ? [] : committed?.writeResults;
            if (!ownKeys(committed, ['writeResults', 'commitTime']) || !Array.isArray(results) ||
                results.length !== writes.length) invalid('invalid-response');
            parseTimestamp(committed.commitTime);
            for (let i = 0; i < writes.length; i++) {
              const result = results[i], count = writes[i].updateTransforms?.length ?? 0;
              if (!ownKeys(result, ['updateTime', 'transformResults'])) invalid('invalid-response');
              if (!writes[i].delete || result.updateTime !== undefined) parseTimestamp(result.updateTime);
              if (count) {
                if (!Array.isArray(result.transformResults) || result.transformResults.length !== count) invalid('invalid-response');
                for (const value of result.transformResults) {
                  if (!ownKeys(value, ['timestampValue']) || value.timestampValue === undefined) invalid('invalid-response');
                  parseTimestamp(value.timestampValue);
                }
              } else if (result.transformResults !== undefined && (!Array.isArray(result.transformResults) || result.transformResults.length)) invalid('invalid-response');
            }
          } catch { throw new FirestoreStoreError('invalid-acknowledgement', 'unknown', true); }
          check();
          ctx.committing = false;
          return result;
        } catch (error) {
          open = false;
          ctx.readsClosed = true;
          // Callback errors keep their original type, fields and object identity.
          if (!ctx.committing && !(error instanceof FirestoreStoreError)) {
            ctx.original = error; ctx.originalSet = true;
          }
          if (transaction && ctx.active && !ctx.committing && !error?.outcomeUnknown && !error?.uncertain) {
            ctx.rollbackStarted = true;
            await rollback(transaction);
          }
          if (aborts.has(error) && ctx.active && attempt + 1 < attempts) {
            check();
            try {
              const jitter = random();
              if (!Number.isFinite(jitter) || jitter < 0 || jitter >= 1) invalid('invalid-backoff');
              await wait(() => sleep(20 + Math.floor(jitter * 80)), Math.max(1, remaining()), expired);
            } catch (failure) {
              if (failure instanceof FirestoreStoreError) throw failure;
              throw new FirestoreStoreError('backoff-failed');
            }
            check(); continue;
          }
          if (aborts.has(error)) throw new FirestoreStoreError('contention-exhausted');
          throw error;
        } finally { open = false; }
      }
    }
    try { return await wait(perform, timeoutMs, expired); }
    catch (error) {
      // A stalled callback may resume long after the aggregate deadline. Start
      // its bounded cleanup here, before returning, never from that late task.
      if (!ctx.active && ctx.transaction && !ctx.committing && !ctx.rollbackStarted &&
          !error?.outcomeUnknown && !error?.uncertain) {
        ctx.rollbackStarted = true;
        await rollback(ctx.transaction);
      }
      throw error;
    }
    finally { ctx.active = false; }
  }
  return Object.freeze({projectId, databaseId, runTransaction, timestamp, toTimestamp, deleteValue,
    capabilities: Object.freeze({serverTimestamps: true, deleteFields: true})});
}
