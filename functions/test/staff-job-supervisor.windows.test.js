'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {randomBytes} = require('node:crypto');
const path = require('node:path');
const fs = require('node:fs');
const {launchSynthetic} = require('../scripts/run-staff-emulators');
const executable = process.env.VELORA_SYNTHETIC_SUPERVISOR;
const skip = process.platform !== 'win32' || !executable;
if (!skip) {
  const resolved = fs.realpathSync(executable);
  const repository = path.resolve(__dirname, '../..');
  assert.ok(!resolved.toLowerCase().startsWith(repository.toLowerCase() + path.sep));
  assert.equal(path.basename(resolved).toLowerCase(), 'staff-job-supervisor.exe');
}
async function run(scenario, control) {
  const token = randomBytes(16).toString('hex');
  const child = launchSynthetic({project: 'demo-velora-staff', executable, token, scenario});
  const events = []; let buffer = '', stderr = '', started = Date.now();
  // Native has independent deadlines. Never use guessed PIDs to recover a timeout.
  const heartbeat = setInterval(() => { if (child.stdin.writable) child.stdin.write('V1 PING\n'); }, 100);
  if (control === 'heartbeat') clearInterval(heartbeat);
  child.stdin.on('error', () => {});
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
  child.stderr.on('data', data => { stderr += data; });
  child.stdout.on('data', data => {
    buffer += data;
    if (buffer.length > 4096) return; // Assert bounded transcript on completion.
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      const event = JSON.parse(line); events.push(event);
      if (event.event === 'READY') {
        if (control === 'disconnect') { clearInterval(heartbeat); child.stdin.end(); }
        else if (control === 'stop') child.stdin.write('V1 STOP\nV1 STOP\n');
        else if (control === 'graceful') child.stdin.write('V1 SHUTDOWN\n');
      }
    }
  });
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject); child.once('close', resolve);
  }).finally(() => clearInterval(heartbeat));
  assert.equal(code, 0, `Native failure; stage ${events.find(e => e.event === 'CHILD_FAILED')?.count ?? 0}, active ${events.find(e => e.event === 'STARTUP_COUNT')?.count ?? 0}, self ${events.find(e => e.event === 'SELF_COUNT')?.count ?? 0}`);
  assert.equal(stderr.length, 0); assert.equal(buffer.length, 0);
  assert.ok(events.every(e => e.v === 1 && e.token === token));
  assert.ok(events.some(e => e.event === 'SENTINEL_PRESERVED'));
  const measured = events.find(e => e.event === 'CLEANUP_MS');
  if (scenario !== 'assignment-failure') {
    assert.ok(measured && measured.count <= 10000, 'Measured cleanup deadline exceeded');
    // Only bounded numeric timing is reported, never process IDs or raw responses.
    console.log(`Synthetic cleanup ${scenario}: ${measured.count} ms`);
  }
  assert.ok(Date.now() - started < 12000, 'Cleanup deadline exceeded');
  return events;
}
for (const [scenario, control, expected] of [
  ['forced', 'stop', 'FORCED'], ['graceful', 'graceful', 'GRACEFUL'],
  ['root-exit', null, 'ROOT_EXIT'],
  ['forced', 'disconnect', 'DISCONNECTED'], ['heartbeat-timeout', 'heartbeat', 'HEARTBEAT_TIMEOUT'],
  ['execution-timeout', null, 'EXECUTION_TIMEOUT'],
]) test(`Windows containment: ${scenario}/${control || 'automatic'}`, {skip, timeout: 15000}, async () => {
  const events = await run(scenario, control);
  assert.ok(events.some(e => e.event === 'ASSIGNED'));
  assert.ok(events.some(e => e.event === 'READY' && e.count === 3));
  assert.ok(events.some(e => e.event === expected));
  assert.ok(events.some(e => e.event === 'CLEANED' && e.count === 0));
});
test('last job handle closure signals all retained workload handles', {skip, timeout: 15000}, async () => {
  const events = await run('close-job');
  assert.ok(events.some(e => e.event === 'HANDLES_SIGNALED' && e.count >= 3));
  assert.ok(!events.some(e => e.event === 'CLEANED')); // Job accounting is no longer available.
});
test('invalid job assignment fails before workload execution', {skip, timeout: 15000}, async () => {
  const events = await run('assignment-failure');
  assert.ok(events.some(e => e.event === 'ASSIGNMENT_REJECTED'));
  assert.ok(!events.some(e => e.event === 'ASSIGNED' || e.event === 'READY'));
});
test('failure after suspended assignment cleans without executing workload', {skip, timeout: 15000}, async () => {
  const events = await run('partial');
  assert.ok(events.some(e => e.event === 'ASSIGNED'));
  assert.ok(events.some(e => e.event === 'PARTIAL'));
  assert.ok(events.some(e => e.event === 'CLEANED' && e.count === 0));
  assert.ok(!events.some(e => e.event === 'READY'));
});
for (const [scenario, expected] of [['owner-crash', 'OWNER_CRASH_CLEANED'],
  ['owner-hang', 'WATCHDOG_CLEANED'], ['startup-timeout', 'STARTUP_TIMEOUT']]) {
  test(`Windows independent observation: ${scenario}`, {skip, timeout: 15000}, async () => {
    const events = await run(scenario);
    assert.ok(events.some(e => e.event === expected));
    assert.ok(events.some(e => e.event === 'CLEANED' && e.count === 0));
  });
}
test('contained workers cannot request breakaway', {skip, timeout: 15000}, async () => {
  const events = await run('breakaway', 'stop');
  assert.ok(events.some(e => e.event === 'BREAKAWAY_REJECTED' && e.count === 3));
});
for (const reason of ['nested-job incompatibility', 'actual PID reuse stress']) {
  test(reason, {skip: 'Not implemented or verified; emulator execution remains blocked'}, () => {});
}
