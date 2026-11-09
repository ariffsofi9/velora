'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {preflight, SCENARIOS} = require('../scripts/run-staff-emulators');
const valid = () => ({project: 'demo-velora-staff', executable: path.resolve('staff-job-supervisor.exe'),
  token: 'a'.repeat(32), scenario: 'forced'});
test('module import has no startup; exact synthetic plan has empty child environment', () => {
  const plan = preflight(valid());
  assert.deepEqual(plan.args, ['--supervise', 'a'.repeat(32), 'forced']);
  assert.deepEqual(plan.env, {}); assert.ok(Object.isFrozen(plan));
});
for (const [name, change] of Object.entries({
  'wrong project': {project: 'synthetic-wrong'}, 'missing project': {project: undefined},
  'relative executable': {executable: 'staff-job-supervisor.exe'},
  'arbitrary executable': {executable: path.resolve('unapproved.exe')},
  'shell token': {token: 'a;PRIVATE'}, 'missing token': {token: undefined},
  'arbitrary mode': {scenario: 'kill'}, 'target PID': {scenario: '1234'},
})) test(`preflight rejects ${name}`, () => {
  assert.throws(() => preflight({...valid(), ...change}), {message: 'SYNTHETIC_CONFIGURATION_REJECTED'});
});
for (const key of ['GCLOUD_PROJECT', 'GOOGLE_CLOUD_PROJECT', 'FIRESTORE_EMULATOR_HOST',
  'FIREBASE_AUTH_EMULATOR_HOST', 'GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_TOKEN',
  'FIREBASE_CONFIG', 'NODE_OPTIONS']) test(`rejects conflicting ${key} without exposing value`, () => {
  assert.throws(() => preflight({...valid(), environment: {[key]: 'PRIVATE'}}),
    {message: 'SYNTHETIC_ENVIRONMENT_REJECTED'});
});
for (const scenario of SCENARIOS) test(`allowlisted synthetic scenario ${scenario}`, () => {
  assert.equal(preflight({...valid(), scenario}).args[2], scenario);
});
test('dedicated emulator identity may be validated but is not forwarded', () => {
  assert.deepEqual(preflight({...valid(), environment: {GCLOUD_PROJECT: 'demo-velora-staff',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:28080', FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:29099'}}).env, {});
});
