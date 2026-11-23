import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {OAUTH_PROTOCOL_VERSION} from '../backend/pre-auth-settlement.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const sha256 = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const reject = reason => { throw new Error(reason); };
const parse = (bytes, label) => {
  try { return JSON.parse(bytes.toString('utf8')); }
  catch { return reject(`Invalid ${label} JSON`); }
};
const sourceName = 'velora-google-token-source-real';
const acknowledgement = 'OAuthAcknowledgement';
const inputs = ['restArtifact', 'sourceArtifact', 'restConfig', 'sourceConfig'];
const privateBinding = (services, binding, service, entrypoint) => {
  if (!Array.isArray(services) || services.length !== 1) return false;
  const target = services[0];
  return target?.binding === binding && target.service === service && target.entrypoint === entrypoint &&
    Object.keys(target).length === 3;
};
const unexposed = config => config?.workers_dev === false && config.preview_urls === false &&
  config.route === undefined && config.routes === undefined && config.env === undefined &&
  config.triggers === undefined && config.durable_objects === undefined;

// The trusted allowlist pins the reviewed evidence and all four release inputs.
// Evidence describes tests on the pinned artifacts. It is never self-approving.
function validateCompatibility({manifest, allowlist, restArtifact, sourceArtifact, restConfig, sourceConfig}) {
  const approved = parse(allowlist, 'allowlist');
  if (!Array.isArray(approved) || !approved.length || !approved.every(sha256)) reject('No valid rollback allowlist');
  const manifestDigest = digest(manifest);
  if (!approved.includes(manifestDigest)) reject('Rollback manifest is not approved');
  const candidate = parse(manifest, 'manifest');
  if (candidate?.schema !== 1 || candidate.protocolVersion !== OAUTH_PROTOCOL_VERSION ||
      candidate.evidence?.trackedFinishGuard !== true ||
      candidate.evidence?.readsExistingRecords !== true ||
      candidate.evidence?.acknowledgesWhileDisabled !== true ||
      candidate.evidence?.privateAcknowledgement !== true ||
      JSON.stringify(candidate.evidence?.acknowledgementMethods) !== '["start","acknowledge"]') {
    reject('Missing or incompatible durable OAuth evidence');
  }
  const supplied = {restArtifact, sourceArtifact, restConfig, sourceConfig};
  for (const name of inputs) {
    if (!Buffer.isBuffer(supplied[name]) || supplied[name].length === 0 ||
        candidate.digests?.[name] !== digest(supplied[name])) reject(`Rollback input mismatch: ${name}`);
  }
  const restRoot = parse(restConfig, 'REST config');
  const rest = restRoot?.env?.real;
  const source = parse(sourceConfig, 'Token Source config');
  const migration = restRoot?.migrations;
  const admission = rest?.durable_objects?.bindings;
  if (rest?.name !== 'rest-api' || rest.vars?.VELORA_FIREBASE_PROJECT !== 'velora-73222' ||
      rest.vars?.VELORA_ENVIRONMENT !== 'real' ||
      ![undefined, 'false'].includes(rest.vars.VELORA_DURABLE_OAUTH) ||
      rest.preview_urls !== false ||
      !privateBinding(rest.services, 'VELORA_GOOGLE_TOKEN_SOURCE', sourceName, 'GoogleTokenSource') ||
      !Array.isArray(admission) || admission.length !== 1 ||
      admission[0]?.name !== 'ADMISSION' || admission[0]?.class_name !== 'AdmissionCoordinator' ||
      Object.keys(admission[0]).length !== 2 ||
      rest.migrations !== undefined ||
      !Array.isArray(migration) || migration.length !== 1 || migration[0]?.tag !== 'v1' ||
      JSON.stringify(migration[0]?.new_sqlite_classes) !== '["AdmissionCoordinator"]' ||
      Object.keys(migration[0]).length !== 2 ||
      source?.name !== sourceName || !unexposed(source) ||
      !privateBinding(source.services, 'OAUTH_ACK', 'rest-api', acknowledgement)) {
    reject('Incompatible private binding or admission configuration');
  }
  return manifestDigest;
}

export function validateOAuthRollback(inputs) {
  const manifestDigest = validateCompatibility(inputs);
  if (parse(inputs.manifest, 'manifest').scope === 'ingress-containment-only') {
    reject('Containment artifact requires explicit containment review');
  }
  return manifestDigest;
}

export function validateOAuthContainment(inputs) {
  const manifestDigest = validateCompatibility(inputs);
  const candidate = parse(inputs.manifest, 'containment manifest');
  const rest = parse(inputs.restConfig, 'containment REST config');
  if (candidate.scope !== 'ingress-containment-only' ||
      candidate.parentManifestSha256 !== '92e6f38a237256367f715627d349aefd40c9180ba8806197934ad6b96a6e99e1' ||
      candidate.evidence.rejectsPublicIngress !== true ||
      candidate.evidence.blocksTrackedStartAndRegistration !== true ||
      rest.main !== 'ingress-containment-entry.mjs') {
    reject('Missing or incompatible ingress containment evidence');
  }
  return manifestDigest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const names = ['manifest', 'allowlist', ...inputs];
    const paths = process.argv.slice(2);
    const containment = paths[0] === '--containment';
    if (containment) paths.shift();
    if (paths.length !== names.length) {
      reject('Usage: node oauth-rollback-gate.mjs [--containment] MANIFEST ALLOWLIST REST_BUNDLE SOURCE_BUNDLE REST_JSON SOURCE_JSON');
    }
    const contents = await Promise.all(paths.map(path => readFile(path)));
    const validate = containment ? validateOAuthContainment : validateOAuthRollback;
    const validated = validate(Object.fromEntries(names.map((name, i) => [name, contents[i]])));
    process.stdout.write(`Reviewed ${containment ? 'containment' : 'rollback'} manifest matched ${validated}\n`);
  } catch (error) {
    process.stderr.write(`Rollback rejected: ${error.message}\n`);
    process.exitCode = 1;
  }
}
