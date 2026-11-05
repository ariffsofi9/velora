'use strict';
const assert = require('node:assert/strict');
// Offline optimistic document/query model; never imports Firebase or uses network.
class AiTransactionStore {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  put(path, doc) { this.docs.set(path, structuredClone(doc)); this.versions.set(path, (this.versions.get(path) ?? 0) + 1); }
  async runTransaction(operation) {
    const signature = (docs, versions, prefix) => JSON.stringify([...docs.keys()].filter(p =>
      p.startsWith(prefix) && !p.slice(prefix.length).includes('/')).sort().map(p => [p, versions.get(p)]));
    for (let attempt = 0; attempt < 100; attempt++) {
      const snapshot = structuredClone(this.docs); const versions = new Map(this.versions);
      const reads = new Set(); const queries = new Map(); const writes = new Map(); let writing = false;
      const write = (path, doc, create) => {
        writing = true; assert.equal(writes.has(path), false);
        assert.equal(snapshot.has(path), !create); reads.add(path);
        writes.set(path, create ? structuredClone(doc) : {...snapshot.get(path), ...structuredClone(doc)});
      };
      const result = await operation({
        get: async path => { assert.equal(writing, false); reads.add(path); await Promise.resolve(); return structuredClone(snapshot.get(path) ?? null); },
        inventory: async (cafeId, limit) => {
          assert.equal(writing, false); const prefix = `cafes/${cafeId}/inventory/`;
          queries.set(prefix, signature(snapshot, versions, prefix)); await Promise.resolve();
          return [...snapshot.entries()].filter(([p]) => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
            .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).slice(0, limit)
            .map(([p, data]) => ({id: p.slice(prefix.length), data: structuredClone(data)}));
        },
        create: (p, d) => write(p, d, true), update: (p, d) => write(p, d, false),
        delete: p => { writing = true; assert.equal(writes.has(p), false); reads.add(p); writes.set(p, null); },
      });
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; await hook(); }
      if ([...reads].some(p => this.versions.get(p) !== versions.get(p)) ||
          [...queries].some(([prefix, value]) => signature(this.docs, this.versions, prefix) !== value)) {
        this.conflicts++; continue;
      }
      if (this.failCommit) throw Error('simulated storage failure');
      for (const [p, d] of writes) {
        if (d === null) { this.docs.delete(p); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
        else this.put(p, d);
      }
      return result;
    }
    throw Error('model contention limit');
  }
}
module.exports = {AiTransactionStore};
