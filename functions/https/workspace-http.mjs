import {randomUUID} from 'node:crypto';
import workspace from '../src/workspace-creation.js';
import {createAuthenticatedJsonHttp} from './authenticated-json-http.mjs';

// Unwired onboarding route. No membership prerequisite: canonical provisioning
// validates prior absence/ownership and allocates the ID once outside retries.
export function createWorkspaceHttp({projectId, storeProjectId, verifyIdentity, store,
  timestamp, idFactory = randomUUID, verificationTimeoutMs = 5000,
  bodyTimeoutMs = 5000, cleanupTimeoutMs = 100, scheduleTimeout} = {}) {
  if (typeof store?.runTransaction !== 'function' || store.projectId !== projectId || store.capabilities?.serverTimestamps !== true ||
      typeof timestamp !== 'function' || typeof idFactory !== 'function') throw Error('Explicit workspace dependencies required');
  return createAuthenticatedJsonHttp({projectId, storeProjectId, verifyIdentity,
    verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    maxRequestBytes: 2048, domainErrorTypes: [workspace.WorkspaceCreationError],
    routes: new Map([['/workspace/create', ({auth, data}) => workspace.createWorkspace({
      auth, data, store, timestamp, idFactory})]])});
}
