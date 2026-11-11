import {BackendError, requireTestProject} from './backend-errors.mjs';
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
import {createHttpPolicy} from './http-policy.mjs';

const inventoryRoutes = ['/inventory/create', '/inventory/update', '/inventory/adjust-stock', '/inventory/lifecycle', '/inventory/reconcile'];
const invitationRoutes = ['/staff/create', '/staff/revoke', '/staff/redeem', '/staff/reconcile'];
const workspaceRoutes = ['/workspace/create'];
const staffRoutes = ['/staff/list', '/staff/remove'];
const menuRoutes = ['/menu/create', '/menu/get', '/menu/list', '/menu/update', '/menu/lifecycle'];
const aiRoutes = ['/ai/issue', '/ai/generate'];

// Unwired TEST-only composition. No listener, defaults for network/credentials,
// SDK initialization, environment discovery or import of src/index.js.
export function createApplication({projectId, publicOrigin, allowedOrigins, transport, credential,
  now = Date.now, maxConcurrent = 8, httpTimeoutMs = 5000, identityTimeoutMs = 5000,
  verificationTimeoutMs = 5000, bodyTimeoutMs = 5000, cleanupTimeoutMs = 100,
  transactionTimeoutMs = 20000, rpcTimeoutMs = 5000, maxResponseBytes = 262144,
  workspaceIdFactory, allowInvitationRejoin = false, ai} = {}) {
  requireTestProject(projectId);
  if (!credential || credential.projectId !== projectId || typeof now !== 'function') {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const http = createGoogleHttp({projectId, transport, timeoutMs: httpTimeoutMs, cleanupTimeoutMs, maxBytes: maxResponseBytes});
  const accessToken = createGoogleOAuth({projectId, http, email: credential.email, sign: credential.sign,
    now, timeoutMs: identityTimeoutMs});
  const getAccount = createFirebaseAccounts({projectId, http, accessToken, timeoutMs: identityTimeoutMs});
  const verifyIdentity = createFirebaseIdentity({projectId, http, getAccount, now, timeoutMs: identityTimeoutMs});
  const store = createFirestoreStore({projectId, http, accessToken, now, timeoutMs: transactionTimeoutMs,
    rpcTimeoutMs, cleanupTimeoutMs});
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
    // Each request retains its own verified token/identity. No shared mutable
    // actor context can bleed across concurrent Owner/Staff requests.
    let capturedToken, capturedIdentity;
    const capture = async token => {
      const identity = await verifyIdentity(token);
      capturedToken = token; capturedIdentity = identity;
      return identity;
    };
    const scopedStore = Object.freeze({...store, runTransaction: async callback => {
      if (!capturedToken || !capturedIdentity) throw new BackendError('identity', 'unauthenticated');
      // Body reading can outlast identity freshness. Reuse the real verifier
      // before transaction dispatch, outside retryable canonical callbacks.
      const current = await verifyIdentity(capturedToken);
      if (current.uid !== capturedIdentity.uid) throw new BackendError('identity', 'unauthenticated');
      return store.runTransaction(callback);
    }});
    const path = new URL(request.url).pathname;
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
            : aiOptions && aiRoutes.includes(path)
              ? createAiHttp({...common, ...aiOptions, verifyIdentity: capture, store: scopedStore})
              : createInvitationHttp({...common, ...rejoin, verifyIdentity: capture, store: scopedStore, now: () => new Date(now())});
    // No universal membership gate: onboarding/redemption retain their actual
    // canonical admission policies. Callable disabled flags remain untouched.
    return operation(request);
  };
  const fetch = createHttpPolicy({projectId, publicOrigin, allowedOrigins, maxConcurrent,
    routes: [...inventoryRoutes, ...invitationRoutes, ...workspaceRoutes, ...staffRoutes, ...menuRoutes,
      ...(aiOptions ? aiRoutes : [])], handler});
  return Object.freeze({projectId, fetch});
}
