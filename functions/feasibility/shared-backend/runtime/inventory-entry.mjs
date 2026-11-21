// Synthetic qualification factory. There is no deployment entry or live transport.
import {createApplication} from '../../../backend/application.mjs';
import {BackendError, requireTestProject} from '../../../backend/backend-errors.mjs';

export const inventoryOrigin = 'https://inventory.offline.invalid';
export const inventoryWebOrigin = 'https://frontend.offline.invalid';

const inventoryPaths = new Set([
  '/inventory/create',
  '/inventory/update',
  '/inventory/adjust-stock',
  '/inventory/lifecycle',
  '/inventory/reconcile',
]);

export function createInventoryWorker({
  projectId, databaseId, transport, sign, now,
} = {}) {
  requireTestProject(projectId);
  if (databaseId !== '(default)' || typeof transport !== 'function' ||
      transport === globalThis.fetch || typeof sign !== 'function' || typeof now !== 'function') {
    throw new BackendError('configuration', 'invalid-configuration');
  }

  const app = createApplication({
    projectId, now, transport,
    publicOrigin: inventoryOrigin,
    allowedOrigins: [inventoryWebOrigin],
    credential: {projectId, email: `synthetic@${projectId}.iam.gserviceaccount.com`, sign},
    enableSavedRecipes: false,
    allowInvitationRejoin: false,
    verificationTimeoutMs: 2000,
    identityTimeoutMs: 2000,
    bodyTimeoutMs: 1000,
    // Allow the HTTP adapter to signal cancellation before the enclosing RPC expires.
    httpTimeoutMs: 1000,
    transactionTimeoutMs: 6000,
    rpcTimeoutMs: 1500,
    cleanupTimeoutMs: 100,
  });

  return Object.freeze({
    async fetch(request) {
      if (request instanceof Request && inventoryPaths.has(new URL(request.url).pathname)) {
        return app.fetch(request);
      }
      return Response.json({error: 'not-found'}, {
        status: 404,
        headers: {'cache-control': 'no-store', 'x-content-type-options': 'nosniff'},
      });
    },
  });
}
