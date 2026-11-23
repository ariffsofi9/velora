import {createHash} from 'node:crypto';
import {lstat, readFile, readdir} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {validateOAuthRollback} from './oauth-rollback-gate.mjs';

const manifestSha256 = '92e6f38a237256367f715627d349aefd40c9180ba8806197934ad6b96a6e99e1';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const reject = reason => { throw new Error(reason); };

async function requireLayout(directory, files, directories = []) {
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) reject('Staging directory must be a real directory');
  const entries = await readdir(directory, {withFileTypes: true});
  if (entries.length !== files.length + directories.length || entries.some(entry =>
    !(entry.isFile() && files.includes(entry.name)) &&
    !(entry.isDirectory() && !entry.isSymbolicLink() && directories.includes(entry.name)))) {
    reject('Unexpected or missing staging entries');
  }
}

export async function verifyDormantLayout(directory, approval) {
  const modules = {rest: 'rest-api.mjs', source: 'velora-google-token-source-real.mjs'};
  const configs = {rest: 'rest-api.proposed.json', source: 'token-source.proposed.json'};
  await requireLayout(directory, ['release-candidate.manifest.json', 'build-inventory.json', ...Object.values(configs)],
    Object.keys(modules));
  for (const [name, module] of Object.entries(modules)) await requireLayout(join(directory, name), [module]);
  const fromRoot = (...parts) => readFile(join(directory, ...parts));
  const manifest = await fromRoot('release-candidate.manifest.json');
  if (hash(manifest) !== manifestSha256) reject('Manifest differs from the pinned release candidate');
  const candidate = JSON.parse(manifest);
  const inventory = await fromRoot('build-inventory.json');
  if (hash(inventory) !== candidate.build.inventorySha256) reject('Inventory differs from the pinned build');
  const workers = JSON.parse(inventory).workers;
  for (const [worker, file, exports] of [
    ['rest-api', modules.rest, ['default', 'AdmissionCoordinator', 'OAuthAcknowledgement']],
    ['velora-google-token-source-real', modules.source, ['default', 'GoogleTokenSource']],
  ]) {
    if (workers[worker]?.file !== file || !exports.every(name => workers[worker].exports.includes(name))) {
      reject('Unexpected Worker entry module or export');
    }
  }
  const inputs = {manifest, restArtifact: await fromRoot('rest', modules.rest),
    sourceArtifact: await fromRoot('source', modules.source), restConfig: await fromRoot(configs.rest),
    sourceConfig: await fromRoot(configs.source)};
  // A structural check uses a throwaway pin in memory. It grants no eligibility.
  validateOAuthRollback({...inputs, allowlist: Buffer.from(JSON.stringify([manifestSha256]))});
  if (!approval) return {manifestSha256, status: 'verified-only'};
  const policy = JSON.parse(approval.policy);
  if (policy?.schema !== 1 || policy.mode !== 'forward-fix-only' ||
      policy.manifestSha256 !== manifestSha256 || policy.decision !== 'approve-dormant-artifact' ||
      typeof policy.reviewReference !== 'string' || !policy.reviewReference.trim()) {
    reject('Explicit reviewed forward-fix-only policy required');
  }
  validateOAuthRollback({...inputs, allowlist: approval.allowlist});
  return {manifestSha256, status: 'artifact-approval-evidence-validated'};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [directory, allowlist, policy, ...extra] = process.argv.slice(2);
    if (!directory || Boolean(allowlist) !== Boolean(policy) || extra.length) {
      reject('Usage: node verify-dormant-layout.mjs STAGING_DIR [REVIEWED_ALLOWLIST REVIEWED_POLICY]');
    }
    const result = await verifyDormantLayout(directory, allowlist && {
      allowlist: await readFile(allowlist), policy: await readFile(policy),
    });
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (error) {
    process.stderr.write(`Staging rejected: ${error.message}\n`);
    process.exitCode = 1;
  }
}
