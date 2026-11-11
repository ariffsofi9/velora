import menu from '../src/menu-service.js';
import model from '../src/menu-model.js';
import {createAuthenticatedJsonHttp, DOMAIN_HTTP_STATUSES} from './authenticated-json-http.mjs';

// Injected boundary only; canonical menuOperation owns authorization and writes.
export function createMenuHttp({projectId, storeProjectId, verifyIdentity, store,
  timestamp, verificationTimeoutMs = 5000, bodyTimeoutMs = 5000,
  cleanupTimeoutMs = 100, scheduleTimeout} = {}) {
  if (typeof store?.runTransaction !== 'function' || store.projectId !== projectId ||
      store.capabilities?.serverTimestamps !== true || typeof timestamp !== 'function') {
    throw Error('Explicit menu dependencies required');
  }
  return createAuthenticatedJsonHttp({projectId, storeProjectId, verifyIdentity,
    verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    domainErrorTypes: [model.MenuError], domainStatuses: {...DOMAIN_HTTP_STATUSES, aborted: 409},
    routes: new Map(['create', 'get', 'list', 'update', 'lifecycle'].map(operation =>
      [`/menu/${operation}`, ({auth, data}) => menu.menuOperation({operation, auth, data, store, timestamp})]))});
}
