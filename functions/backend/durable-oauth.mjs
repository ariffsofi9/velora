import {createHash, randomUUID} from 'node:crypto';

const uuid = value => typeof value === 'string' &&
  /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const hash = value => createHash('sha256').update(value).digest('hex');
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const deny = () => { throw new Error('OAuth operation unavailable.'); };
const key = id => `oauth-operation:v1:${id}`;
const ownerKey = attempt => `oauth-operation-owner:v1:${attempt}`;
const pairDigest = (attempt, token) => hash(`${attempt}:${token}`);

export function createOAuthLedger(storage, drainStatus) {
  const {kv, sql} = storage;
  const transactionSync = action => storage.transactionSync(action);
  function read(id) {
    if (!uuid(id)) deny();
    let row;
    try { row = kv.get(key(id)); } catch { deny(); }
    if (row?.version !== 1 || row.id !== id || !uuid(row.attempt) || !digest(row.owner) ||
        Object.keys(row).length !== 6 ||
        !['registered', 'started', 'settled', 'sealed-before-start'].includes(row.state) ||
        (['started', 'settled'].includes(row.state) ? !digest(row.grant) : row.grant !== null) ||
        kv.get(ownerKey(row.attempt)) !== id) deny();
    return row;
  }
  function requireOwner(row, attempt, token) {
    if (!uuid(attempt) || !uuid(token) ||
        row.attempt !== attempt || row.owner !== pairDigest(attempt, token)) deny();
  }
  function requireRunning(row) {
    const permit = sql.exec("SELECT token FROM permits WHERE attempt = ? AND state = 'running' AND uid_key IS NULL",
      row.attempt).one();
    if (!permit || pairDigest(row.attempt, permit.token) !== row.owner) deny();
  }
  function write(row, state, grant = row.grant) {
    kv.put(key(row.id), {...row, state, grant});
  }
  const permit = Object.freeze({
    register(attempt, token) {
      if (!uuid(attempt) || !uuid(token)) deny();
      return transactionSync(() => {
        const owner = pairDigest(attempt, token);
        const existing = kv.get(ownerKey(attempt));
        if (existing !== undefined) {
          requireOwner(read(existing), attempt, token);
          return existing;
        }
        const id = randomUUID();
        if (kv.get(key(id)) !== undefined) deny();
        const row = {version: 1, id, attempt, owner, state: 'registered', grant: null};
        requireRunning(row);
        if (drainStatus().draining) deny();
        write(row, 'registered');
        kv.put(ownerKey(attempt), id);
        return id;
      });
    },
    status(id, attempt, token) {
      const row = read(id);
      requireOwner(row, attempt, token);
      return row.state;
    },
    seal(id, attempt, token) {
      return transactionSync(() => {
        const row = read(id);
        requireOwner(row, attempt, token);
        if (row.state === 'sealed-before-start') return row.state;
        if (row.state !== 'registered') deny();
        write(row, 'sealed-before-start');
        return 'sealed-before-start';
      });
    },
  });
  const source = Object.freeze({
    start(id) {
      return transactionSync(() => {
        const row = read(id);
        requireRunning(row);
        if (row.state !== 'registered' || drainStatus().draining) deny();
        const grant = randomUUID();
        write(row, 'started', hash(grant));
        return grant;
      });
    },
    acknowledge(id, grant) {
      return transactionSync(() => {
        const row = read(id);
        if (!uuid(grant) || hash(grant) !== row.grant || !['started', 'settled'].includes(row.state)) deny();
        if (row.state === 'started') write(row, 'settled');
        return 'settled';
      });
    },
  });
  // The coordinator calls this inside the same transaction as permit close.
  function mayFinish(attempt, token, expectedTracked) {
    const id = kv.get(ownerKey(attempt));
    if (id === undefined) return !expectedTracked;
    const row = read(id);
    requireOwner(row, attempt, token);
    if (row.state === 'started') return false;
    if (row.state === 'registered') write(row, 'sealed-before-start');
    return true;
  }
  return Object.freeze({permit, source, mayFinish});
}

