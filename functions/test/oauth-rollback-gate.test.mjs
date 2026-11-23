import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {validateOAuthRollback} from '../release/oauth-rollback-gate.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const bytes = value => Buffer.from(JSON.stringify(value));
const config = name => JSON.parse(readFileSync(new URL('../runtime/' + name, import.meta.url), 'utf8'));

function candidate({revision = 'current', changeEvidence = () => {}, changeConfig = () => {}} = {}) {
  const rest = config('wrangler.jsonc');
  const source = config('google-token-source.wrangler.jsonc');
  source.services = [{binding: 'OAUTH_ACK', service: 'rest-api', entrypoint: 'OAuthAcknowledgement'}];
  changeConfig(rest, source);
  const artifacts = {
    restArtifact: Buffer.from('synthetic REST bundle ' + revision),
    sourceArtifact: Buffer.from('synthetic Token Source bundle ' + revision),
    restConfig: bytes(rest),
    sourceConfig: bytes(source),
  };
  const evidence = {schema: 1, protocolVersion: 1, evidence: {
    trackedFinishGuard: true,
    readsExistingRecords: true,
    acknowledgesWhileDisabled: true,
    privateAcknowledgement: true,
    acknowledgementMethods: ['start', 'acknowledge'],
  }, digests: Object.fromEntries(Object.entries(artifacts).map(([key, input]) => [key, hash(input)]))};
  changeEvidence(evidence);
  const manifest = bytes(evidence);
  return {...artifacts, manifest, allowlist: bytes([hash(manifest)])};
}

test('current and explicitly approved rollback manifests pin both artifacts and exact configs', () => {
  const current = candidate();
  const rollback = candidate({revision: 'approved-rollback'});
  const allowlist = bytes([hash(current.manifest), hash(rollback.manifest)]);
  for (const release of [current, rollback]) {
    assert.equal(validateOAuthRollback({...release, allowlist}), hash(release.manifest));
  }
  assert.throws(() => validateOAuthRollback({...rollback, allowlist: current.allowlist}), /not approved/);
});

for (const [label, changeEvidence] of [
  ['incompatible protocol', item => { item.protocolVersion = 2; }],
  ['missing finish guard', item => { delete item.evidence.trackedFinishGuard; }],
  ['missing compatibility metadata', item => { delete item.evidence; }],
  ['unreadable existing records', item => { item.evidence.readsExistingRecords = false; }],
  ['no late acknowledgement while disabled', item => { item.evidence.acknowledgesWhileDisabled = false; }],
  ['missing acknowledgement method', item => { item.evidence.acknowledgementMethods = ['start']; }],
  ['overprivileged acknowledgement', item => { item.evidence.acknowledgementMethods.push('finish'); }],
]) {
  test(`rollback rejects approved evidence for ${label}`, () => {
    assert.throws(() => validateOAuthRollback(candidate({changeEvidence})), /incompatible durable OAuth evidence/);
  });
}

for (const [label, changeConfig] of [
  ['missing acknowledgement entrypoint', (_, source) => { delete source.services[0].entrypoint; }],
  ['missing reverse binding', (_, source) => { delete source.services; }],
  ['incorrect reverse target', (_, source) => { source.services[0].service = 'other-worker'; }],
  ['public acknowledgement route', (_, source) => { source.routes = ['example.invalid/oauth/*']; }],
  ['direct coordinator authority', (_, source) => { source.durable_objects = {bindings: []}; }],
  ['tracked registration enabled', rest => { rest.env.real.vars.VELORA_DURABLE_OAUTH = 'true'; }],
  ['different coordinator', rest => { rest.env.real.durable_objects.bindings[0].class_name = 'Other'; }],
]) {
  test(`rollback rejects approved configuration with ${label}`, () => {
    assert.throws(() => validateOAuthRollback(candidate({changeConfig})), /incompatible private binding/i);
  });
}

test('rollback rejects empty or malformed allowlists and tampered evidence or artifact bytes', () => {
  const release = candidate();
  for (const allowlist of [bytes([]), bytes(['synthetic-unapproved']), Buffer.from('{')]) {
    assert.throws(() => validateOAuthRollback({...release, allowlist}), /allowlist/);
  }
  assert.throws(() => validateOAuthRollback({...release, manifest: Buffer.concat([release.manifest, Buffer.from(' ')])}),
    /not approved/);
  for (const input of ['restArtifact', 'sourceArtifact', 'restConfig', 'sourceConfig']) {
    assert.throws(() => validateOAuthRollback({...release, [input]: Buffer.from('different bytes')}),
      new RegExp('input mismatch: ' + input));
  }
});
