import domain from '../src/saved-recipe-service.js';
import model from '../src/saved-recipe-model.js';
import {bounded, requireTestProject} from '../backend/backend-errors.mjs';
import {createAuthenticatedJsonHttp, DOMAIN_HTTP_STATUSES} from './authenticated-json-http.mjs';

const operations = ['save', 'list', 'get', 'lifecycle', 'reconcile'];
const reply = (status, body) => Response.json(body, {status,
  headers: {'cache-control': 'no-store', 'x-content-type-options': 'nosniff'}});

// Unwired TEST-only factory. Trusted dependencies have no network/credential defaults.
export function createSavedRecipesHttp({projectId, storeProjectId, verifyIdentity, store, timestamp,
  verificationTimeoutMs = 5000, bodyTimeoutMs = 5000, cleanupTimeoutMs = 100,
  requestTimeoutMs = 30000, scheduleTimeout} = {}) {
  requireTestProject(projectId);
  if (storeProjectId !== projectId || store?.projectId !== projectId ||
      verifyIdentity?.projectId !== projectId || typeof verifyIdentity !== 'function' ||
      typeof store?.runTransaction !== 'function' || store.capabilities?.serverTimestamps !== true ||
      typeof timestamp !== 'function' || !Number.isInteger(requestTimeoutMs) ||
      requestTimeoutMs < 1 || requestTimeoutMs > 60000) throw Error('Explicit saved recipe dependencies required');
  const common = {projectId, storeProjectId, verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}), maxRequestBytes: 32768,
    domainErrorTypes: [model.SavedRecipeError],
    domainStatuses: {...DOMAIN_HTTP_STATUSES, aborted: 409, unavailable: 503}};
  // Validate shared admission configuration without invoking any dependency.
  createAuthenticatedJsonHttp({...common, verifyIdentity,
    routes: new Map([['/recipes/get', () => undefined]])});
  return async request => {
    let active = true, dispatched = false, token, initialUid, cancelDeadline, onAbort;
    const mutation = ['/recipes/save', '/recipes/lifecycle'].includes(new URL(request.url).pathname);
    const guard = () => { if (!active || request.signal.aborted) throw Error('Request closed'); };
    const capture = async bearer => {
      guard();
      const auth = await verifyIdentity(bearer);
      guard(); token = bearer; initialUid = auth?.uid;
      return auth;
    };
    const fresh = Object.assign(async bearer => {
      guard();
      if (bearer !== token) throw Error();
      const auth = await bounded(() => verifyIdentity(bearer), verificationTimeoutMs, 'identity', 'unauthenticated');
      guard();
      if (auth?.uid !== initialUid) throw Error();
      return auth;
    }, {projectId});
    const guardedStore = {...store, runTransaction: async callback => {
      guard(); dispatched = true;
      return store.runTransaction(async tx => {
        guard();
        const guardedTx = {...tx,
          create: (...args) => { guard(); return tx.create(...args); },
          update: (...args) => { guard(); return tx.update(...args); }};
        const result = await callback(guardedTx);
        guard();
        return result;
      });
    }};
    const service = domain.createSavedRecipeService({projectId, store: guardedStore, verifyIdentity: fresh, timestamp});
    const handler = createAuthenticatedJsonHttp({...common, verifyIdentity: capture,
      routes: new Map(operations.map(operation => [`/recipes/${operation}`, async ({data}) => {
        guard();
        try {
          const result = await service({operation, token, data});
          guard();
          if (Buffer.byteLength(JSON.stringify(result), 'utf8') > 65536) throw Error();
          return result;
        } catch (error) {
          // E2's explicit uncertainty must bypass definite domain status mapping.
          if (error instanceof model.SavedRecipeError && error.outcomeUnknown === true) throw Error();
          throw error;
        }
      }]))});
    const closed = () => dispatched && mutation
      ? reply(503, {error: 'unavailable', outcomeUnknown: true})
      : reply(408, {error: 'deadline-exceeded'});
    try {
      if (request.signal.aborted) { active = false; return closed(); }
      return await Promise.race([
        new Promise(resolve => {
          onAbort = () => { active = false; resolve(closed()); };
          request.signal.addEventListener('abort', onAbort, {once: true});
          const schedule = scheduleTimeout ?? ((callback, ms) => {
            const timer = setTimeout(callback, ms);
            return () => clearTimeout(timer);
          });
          cancelDeadline = schedule(onAbort, requestTimeoutMs);
        }),
        handler(request),
      ]);
    } finally {
      active = false;
      cancelDeadline?.();
      if (onAbort) request.signal.removeEventListener('abort', onAbort);
    }
  };
}
