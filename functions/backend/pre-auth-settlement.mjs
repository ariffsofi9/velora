// A local holder can track the underlying task at its dispatch boundary, before
// wrapping the returned promise in a caller deadline or requesting cancellation.
// A dependency with an opaque lifetime must be marked unobservable at dispatch.
// This status is process-local and is not authority to release a permit.
export function createPreAuthSettlement() {
  let sealed = false, unobservable = false;
  const pending = new Set();
  const status = () => !sealed ? 'open' : unobservable ? 'unproven' : pending.size ? 'pending' : 'settled';

  return Object.freeze({
    dispatch(start, {observable = false} = {}) {
      if (sealed) throw new Error('Pre-auth dispatch is sealed.');
      const task = Promise.resolve().then(() => {
        if (sealed) throw new Error('Pre-auth dispatch is sealed.');
        if (observable !== true) unobservable = true;
        return start();
      });
      pending.add(task);
      const settled = () => pending.delete(task);
      void task.then(settled, settled);
      return task;
    },
    seal() { sealed = true; },
    status,
    async completion() {
      if (!sealed) return 'open';
      while (pending.size) await Promise.allSettled(pending);
      return status();
    },
  });
}
export const OAUTH_PROTOCOL_VERSION = 1;

