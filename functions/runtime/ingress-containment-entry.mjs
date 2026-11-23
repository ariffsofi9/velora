import {AdmissionCoordinator as Coordinator, OAuthAcknowledgement as Acknowledgement,
  unavailable, unavailableResponse} from './admission-coordinator.mjs';

// Preserve the deployed export names and storage model. The maintenance build
// may settle existing work but must never dispatch another tracked operation.
export class AdmissionCoordinator extends Coordinator {
  registerOAuth() { throw unavailable(); }
  startOAuth() { throw unavailable(); }
}

export class OAuthAcknowledgement extends Acknowledgement {
  start() { throw unavailable(); }
}

// Keep this entrypoint independent of the application and its startup graph.
export default {fetch: unavailableResponse};
