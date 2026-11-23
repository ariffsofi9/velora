import {BackendError, requireBackendProject} from './backend-errors.mjs';
import {createGoogleHttp} from './google-http.mjs';
import {createGoogleOAuth} from './google-oauth.mjs';
import {createFirebaseAccounts, createFirebaseIdentity} from './firebase-identity.mjs';
import {createFirestoreStore} from './firestore-store.mjs';
import {createInventoryHttp} from '../https/inventory-http.mjs';
import {createInvitationHttp, createInvitationAccountResolver} from '../https/invitation-http.mjs';
import {createWorkspaceHttp} from '../https/workspace-http.mjs';
import {createStaffHttp} from '../https/staff-http.mjs';
import {createMenuHttp} from '../https/menu-http.mjs';
import {createAiHttp} from '../https/ai-http.mjs';
import {createSavedRecipesHttp} from '../https/saved-recipes-http.mjs';
import {createHttpPolicy} from './http-policy.mjs';

const inventoryRoutes = ['/inventory/create', '/inventory/update', '/inventory/adjust-stock', '/inventory/lifecycle', '/inventory/reconcile'];
const invitationRoutes = ['/staff/create', '/staff/revoke', '/staff/redeem', '/staff/reconcile'];
const workspaceRoutes = ['/workspace/create'];
const staffRoutes = ['/staff/list', '/staff/remove'];
const menuRoutes = ['/menu/create', '/menu/get', '/menu/list', '/menu/update', '/menu/lifecycle'];
const aiRoutes = ['/ai/issue', '/ai/generate'];
const recipeRoutes = ['/recipes/save', '/recipes/list', '/recipes/get', '/recipes/lifecycle', '/recipes/reconcile'];

// TEST uses injected offline dependencies. REAL requires a trusted Worker
// capability. No listener, credential discovery or Functions SDK.
export function createApplication({projectId, publicOrigin, allowedOrigins, enableLocalFrontend, transport, credential,
  accessToken: injectedAccessToken, realWorker, createRealAccessToken,
  now = Date.now, maxConcurrent = 8, admission, httpTimeoutMs = 5000, identityTimeoutMs = 5000,
  verificationTimeoutMs = 5000, bodyTimeoutMs = 5000, cleanupTimeoutMs = 100,
  transactionTimeoutMs = 20000, rpcTimeoutMs = 5000, maxResponseBytes = 262144,
  workspaceIdFactory, allowInvitationRejoin = false, enableSavedRecipes = false, ai} = {}) {
  requireBackendProject(projectId, realWorker);
  if (typeof enableSavedRecipes !== 'boolean') throw new BackendError('configuration', 'invalid-configuration');
  const hasCredential = credential !== undefined;
  const hasProvider = injectedAccessToken !== undefined;
  const invalidCredentials = realWorker
    ? hasCredential || hasProvider || typeof createRealAccessToken !== 'function' || admission !== realWorker.admission ||
      allowInvitationRejoin || enableSavedRecipes || ai !== undefined
    : createRealAccessToken !== undefined || hasCredential === hasProvider ||
      (hasCredential && credential?.projectId !== projectId) ||
      (hasProvider && (typeof injectedAccessToken !== 'function' || injectedAccessToken.projectId !== projectId));
  if (typeof now !== 'function' || invalidCredentials) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const http = createGoogleHttp({projectId, realWorker, transport, timeoutMs: httpTimeoutMs,
    cleanupTimeoutMs, maxBytes: maxResponseBytes});
  function bindGoogle(attempts, acquireOAuth) {
    const accessToken = realWorker
      ? createRealAccessToken({projectId, realWorker, acquire: realWorker.acquire, acquireOAuth,
        now, timeoutMs: identityTimeoutMs})
      : (hasProvider ? injectedAccessToken : createGoogleOAuth({projectId, http, email: credential.email,
        sign: credential.sign, now, timeoutMs: identityTimeoutMs}));
    const getAccount = createFirebaseAccounts({projectId, realWorker, http, accessToken, timeoutMs: identityTimeoutMs});
    const verifyIdentity = createFirebaseIdentity({projectId, realWorker, http, getAccount, now, timeoutMs: identityTimeoutMs});
    const store = createFirestoreStore({projectId, realWorker, http, accessToken, now, timeoutMs: transactionTimeoutMs,
      rpcTimeoutMs, cleanupTimeoutMs, ...(attempts === undefined ? {} : {attempts})});
    return {accessToken, getAccount, verifyIdentity, store};
  }
  const google = bindGoogle();
  const {accessToken, getAccount, verifyIdentity, store} = google;
  if (typeof allowInvitationRejoin !== 'boolean') throw new BackendError('configuration', 'invalid-configuration');
  // Explicit offline-test opt-in only; no environment/client selector. No email
  // lookup provider is constructed or invoked by the default composition.
  const resolveAccount = allowInvitationRejoin ? createInvitationAccountResolver({projectId, http, accessToken,
    getAccount, timeoutMs: identityTimeoutMs}) : undefined;
  const rejoin = {allowRejoin: allowInvitationRejoin, resolveAccount, accountTimeoutMs: identityTimeoutMs};
  const common = {projectId, storeProjectId: store.projectId, verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs};
  // Validate the existing boundary's budgets at construction without any I/O.
  createInventoryHttp({...common, verifyIdentity, store, timestamp: store.timestamp,
    toTimestamp: store.toTimestamp, deleteValue: store.deleteValue});
  createInvitationHttp({...common, ...rejoin, verifyIdentity, store, now: () => new Date(now())});
  createWorkspaceHttp({...common, verifyIdentity, store, timestamp: store.timestamp,
    ...(workspaceIdFactory === undefined ? {} : {idFactory: workspaceIdFactory})});
  createStaffHttp({...common, verifyIdentity, store, timestamp: store.timestamp, getAccount,
    accountTimeoutMs: identityTimeoutMs});
  createMenuHttp({...common, verifyIdentity, store, timestamp: store.timestamp});
  if (enableSavedRecipes) createSavedRecipesHttp({...common, verifyIdentity, store, timestamp: store.timestamp});
  // Trusted explicit injection only. Existing callers keep AI unavailable;
  // provider traffic never passes through the Google-only transport.
  if (ai !== undefined && (!ai || typeof ai !== 'object' || Array.isArray(ai) ||
      Object.keys(ai).some(key => !['transport', 'getSecret', 'timeoutMs'].includes(key)))) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const aiOptions = ai === undefined ? undefined : {transport: ai.transport, getSecret: ai.getSecret,
    ...(ai.timeoutMs === undefined ? {} : {timeoutMs: ai.timeoutMs}), now, getAccount,
    accountTimeoutMs: identityTimeoutMs};
  if (aiOptions) createAiHttp({...common, ...aiOptions, verifyIdentity, store});

  const handler = async request => {
    const path = new URL(request.url).pathname;
    // Keep pending REAL credential and certificate I/O in the request that
    // started it. The outer concurrent admission policy remains shared.
    // Two snapshots may each retry once and still leave room for rollback
    // and fresh account checks within the Workers Free subrequest budget.
    const {getAccount, verifyIdentity, store} = realWorker
      ? bindGoogle(path === '/staff/list' ? 2 : undefined, request.admission?.acquireOAuth) : google;
    // Each request retains its own verified token/identity. No shared mutable
    // actor context can bleed across concurrent Owner/Staff requests.
    let capturedToken, capturedIdentity;
    const capture = async token => {
      const identity = await verifyIdentity(token, request.admission?.preAuth);
      capturedToken = token; capturedIdentity = identity;
      return identity;
    };
    // Preserve the trusted verifier binding for the token-based Saved Recipes domain.
    Object.assign(capture, {projectId});
    const scopedStore = Object.freeze({...store, runTransaction: async callback => {
      if (request.signal?.aborted) throw new BackendError('request', 'unavailable');
      if (!capturedToken || !capturedIdentity) throw new BackendError('identity', 'unauthenticated');
      // Body reading can outlast identity freshness. Reuse the real verifier
      // before transaction dispatch, outside retryable canonical callbacks.
      const current = await verifyIdentity(capturedToken);
      if (request.signal?.aborted) throw new BackendError('request', 'unavailable');
      if (current.uid !== capturedIdentity.uid) throw new BackendError('identity', 'unauthenticated');
      return store.runTransaction(callback);
    }});
    const operation = inventoryRoutes.includes(path)
      ? createInventoryHttp({...common, verifyIdentity: capture, store: scopedStore,
        timestamp: store.timestamp, toTimestamp: store.toTimestamp, deleteValue: store.deleteValue})
      : workspaceRoutes.includes(path)
        ? createWorkspaceHttp({...common, verifyIdentity: capture, store: scopedStore, timestamp: store.timestamp,
          ...(workspaceIdFactory === undefined ? {} : {idFactory: workspaceIdFactory})})
        : staffRoutes.includes(path)
          ? createStaffHttp({...common, verifyIdentity: capture, store: scopedStore, timestamp: store.timestamp,
            getAccount, accountTimeoutMs: identityTimeoutMs})
          : menuRoutes.includes(path)
            ? createMenuHttp({...common, verifyIdentity: capture, store: scopedStore, timestamp: store.timestamp})
            : enableSavedRecipes && recipeRoutes.includes(path)
              ? createSavedRecipesHttp({...common, verifyIdentity: capture, store: scopedStore, timestamp: store.timestamp})
            : aiOptions && aiRoutes.includes(path)
              ? createAiHttp({...common, ...aiOptions, verifyIdentity: capture, store: scopedStore})
              : createInvitationHttp({...common, ...rejoin, verifyIdentity: capture, store: scopedStore, now: () => new Date(now())});
    // No universal membership gate: onboarding/redemption retain their actual
    // canonical admission policies. Callable disabled flags remain untouched.
    return operation(request);
  };
  const fetch = createHttpPolicy({projectId, realWorker, publicOrigin, allowedOrigins, enableLocalFrontend, maxConcurrent, admission,
    routes: [...inventoryRoutes, ...invitationRoutes, ...workspaceRoutes, ...staffRoutes, ...menuRoutes,
      ...(aiOptions ? aiRoutes : []), ...(enableSavedRecipes ? recipeRoutes : [])], handler});
  return Object.freeze({projectId, fetch});
}
