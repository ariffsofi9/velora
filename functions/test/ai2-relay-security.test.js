'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const {randomBytes, createHmac} = require('node:crypto');
const {serveProvider, pipeProvider} = require('../ai1/groq-provider');
const {protectRelaySecret, unprotectRelaySecret} = require('../ai1/relay-credential');
const key = () => randomBytes(32).toString('hex');
const mac = (secret, ...parts) => createHmac('sha256', Buffer.from(secret, 'hex')).update(JSON.stringify(parts)).digest('hex');
const input = {items: [{id: 'private-item', name: 'Milk', quantity: 2, unit: 'L'}], maxRecipes: 1};
const recipe = {title: 'Fixture', ingredients: [{itemId: 'private-item', quantity: 1, unit: 'L'}],
  steps: ['Supplied fixture step.'], whyRecommended: 'Offline fixture.'};
test('Windows DPAPI credential roundtrip and corrupt/legacy credentials fail closed', () => {
  const secret = key(), envelope = protectRelaySecret(secret);
  assert.equal(envelope.includes(secret), false);
  assert.equal(unprotectRelaySecret(envelope), secret);
  for (const invalid of [undefined, secret, 'dpapi-v1:AAAA', 'dpapi-v1:' + 'A'.repeat(9000)]) {
    assert.throws(() => unprotectRelaySecret(invalid), {code: 'failed-precondition'});
  }
});
async function listen(t, server, pipe = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex')) {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(pipe, resolve); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  return pipe;
}
async function exchange(pipe, hello, next) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(pipe); let buffer = ''; const messages = [];
    const timer = setTimeout(() => { socket.destroy(); reject(Error('Offline relay test timed out')); }, 2000);
    socket.setEncoding('utf8'); socket.on('error', reject);
    socket.on('connect', () => socket.write(JSON.stringify(hello) + '\n'));
    socket.on('data', chunk => {
      buffer += chunk;
      while (buffer.includes('\n')) {
        const index = buffer.indexOf('\n'); const message = JSON.parse(buffer.slice(0, index));
        buffer = buffer.slice(index + 1); messages.push(message);
        if (messages.length === 1 && next) socket.write(JSON.stringify(next(message)) + '\n');
      }
    });
    socket.on('close', () => { clearTimeout(timer); resolve(messages); });
  });
}
test('relay requires explicit strong credential on client and server', () => {
  const pipe = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  for (const secret of [undefined, '', 'weak', 'G'.repeat(64)]) {
    assert.throws(() => serveProvider(pipe, () => [], secret), {code: 'failed-precondition'});
    assert.throws(() => pipeProvider(pipe, secret), {code: 'failed-precondition'});
  }
});
test('authorized mutual handshake returns authenticated validated response', async t => {
  const secret = key(); let calls = 0;
  const name = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  const pipe = await listen(t, serveProvider(name, async () => { calls++; return [recipe]; }, secret), name);
  assert.deepEqual(await pipeProvider(pipe, secret)(input), [recipe]);
  assert.equal(calls, 1);
});
test('wrong credential cannot obtain inventory or invoke provider', async t => {
  let calls = 0; const secret = key();
  const name = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  const pipe = await listen(t, serveProvider(name, async () => { calls++; return [recipe]; }, secret), name);
  await assert.rejects(pipeProvider(pipe, key())(input));
  assert.equal(calls, 0);
});
test('legacy raw/unsigned payload and invalid client proof never invoke provider', async t => {
  let calls = 0; const secret = key();
  const name = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  const pipe = await listen(t, serveProvider(name, async () => { calls++; return [recipe]; }, secret), name);
  assert.deepEqual(await exchange(pipe, input), []);
  const messages = await exchange(pipe, {clientNonce: key()}, () => ({payload: JSON.stringify(input), proof: key()}));
  assert.equal(messages.length, 1); assert.equal(calls, 0);
});
test('captured authenticated request cannot replay across connections', async t => {
  let calls = 0; const secret = key(), clientNonce = key(), payload = JSON.stringify(input);
  const name = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  const pipe = await listen(t, serveProvider(name, async () => { calls++; return [recipe]; }, secret), name);
  let captured;
  const first = await exchange(pipe, {clientNonce}, ({serverNonce}) => {
    captured = {payload, proof: mac(secret, 'request', clientNonce, serverNonce, payload)}; return captured;
  });
  assert.equal(first.length, 2); assert.equal(calls, 1);
  const second = await exchange(pipe, {clientNonce}, () => captured);
  assert.equal(second.length, 1); assert.equal(calls, 1);
});
test('unauthenticated impersonator sees only fresh client nonce, not inventory', async t => {
  let received = '';
  const pipe = await listen(t, net.createServer(socket => {
    socket.setEncoding('utf8');
    socket.on('data', chunk => { received += chunk; socket.write(JSON.stringify({serverNonce: key(), proof: key()}) + '\n'); });
  }));
  await assert.rejects(pipeProvider(pipe, key())(input));
  assert.equal(received.includes('private-item'), false); assert.equal(received.includes('Milk'), false);
  assert.deepEqual(Object.keys(JSON.parse(received)), ['clientNonce']);
});
test('tampered response from relay is rejected', async t => {
  const secret = key();
  const pipe = await listen(t, net.createServer(socket => {
    let stage = 0, buffer = ''; socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk; if (!buffer.includes('\n')) return;
      const message = JSON.parse(buffer.slice(0, buffer.indexOf('\n'))); buffer = '';
      if (stage++ === 0) {
        const serverNonce = key();
        socket.write(JSON.stringify({serverNonce, proof: mac(secret, 'server', message.clientNonce, serverNonce)}) + '\n');
      } else socket.end(JSON.stringify({payload: JSON.stringify({recipes: [recipe]}), proof: key()}) + '\n');
    });
  }));
  await assert.rejects(pipeProvider(pipe, secret)(input));
});
