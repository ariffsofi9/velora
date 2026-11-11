// Offline composition only. Never substitutes local timestamps or null deletes.
import creation from '../src/inventory-create.js';
import update from '../src/inventory-update.js';
import stock from '../src/inventory-stock.js';
import lifecycle from '../src/inventory-lifecycle.js';
import recovery from '../src/inventory-recovery.js';
import {createAuthenticatedJsonHttp, DOMAIN_HTTP_STATUSES} from './authenticated-json-http.mjs';

// The trusted store must resolve timestamp and delete-field transforms atomically
// with every mutation/audit write. The TEST REST prototype is not that adapter.
export function createInventoryHttp({projectId, storeProjectId, verifyIdentity, store,
  timestamp, toTimestamp, deleteValue, verificationTimeoutMs = 5000,
  bodyTimeoutMs = 5000, cleanupTimeoutMs = 100, scheduleTimeout}) {
  if (typeof store?.runTransaction !== 'function' ||
      store.capabilities?.serverTimestamps !== true || store.capabilities?.deleteFields !== true ||
      [timestamp, toTimestamp, deleteValue].some(value => typeof value !== 'function')) {
    throw Error('Compatible inventory store and explicit transform dependencies required');
  }
  const compose = operation => ({auth, data}) => operation({auth, data, store, timestamp, toTimestamp, deleteValue});
  const common = {
    projectId, storeProjectId, verifyIdentity, verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    domainStatuses: {...DOMAIN_HTTP_STATUSES, aborted: 409, 'out-of-range': 409},
    domainReason: error => error instanceof stock.InventoryStockError &&
      error.code === 'failed-precondition' && error.reason === 'insufficient-stock'
      ? 'insufficient-stock' : undefined,
    domainErrorTypes: [creation.InventoryCreationError, update.InventoryUpdateError,
      stock.InventoryStockError, lifecycle.InventoryLifecycleError, recovery.InventoryRecoveryError],
  };
  // Preserve mutation limits; the observation envelope needs bounded overhead
  // around an original request that could already occupy all 4096 bytes.
  const mutations = createAuthenticatedJsonHttp({...common, maxRequestBytes: 4096,
    routes: new Map([
      ['/inventory/create', compose(creation.createInventoryItem)],
      ['/inventory/update', compose(update.updateInventoryItem)],
      ['/inventory/adjust-stock', compose(stock.adjustInventoryStock)],
      ['/inventory/lifecycle', compose(lifecycle.setInventoryLifecycle)],
    ]),
  });
  const observer = createAuthenticatedJsonHttp({...common, maxRequestBytes: 4160,
    routes: new Map([['/inventory/reconcile', compose(recovery.reconcileInventory)]])});
  return request => {
    try { if (new URL(request.url).pathname === '/inventory/reconcile') return observer(request); }
    catch { /* Let the existing boundary normalize malformed requests. */ }
    return mutations(request);
  };
}
