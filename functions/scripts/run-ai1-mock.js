'use strict';
const {spawn} = require('node:child_process');
const {existsSync, readdirSync} = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const {childEnvironment} = require('../ai1/run-emulators');
async function main() {
  const mode = process.argv[2];
  if (!['start', 'test', 'test-browser'].includes(mode)) throw Error();
  for (const folder of ['..', '../ai1', '../ai1-mock']) if (readdirSync(path.resolve(__dirname, folder)).some(n => n.startsWith('.env'))) throw Error();
  const env = {...childEnvironment(), AI_RECIPE_PROVIDER: 'fake', AI1_MOCK_RECIPES: 'true'};
  const cli = path.join(env.APPDATA, 'npm/node_modules/firebase-tools/lib/bin/firebase.js');
  if (!existsSync(cli)) throw Error();
  const servers = [];
  try {
    for (const port of [19099,19080,19150,15001,14001,14400,14500,19299,19499]) {
      const server = net.createServer();
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen({host:'127.0.0.1',port,exclusive:true}, resolve); });
      servers.push(server);
    }
  } finally { await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve)))); }
  const args = [cli, mode === 'start' ? 'emulators:start' : 'emulators:exec', '--config', 'firebase.ai1-mock-emulator.json', '--project', 'demo-velora-ai1',
    '--only', 'auth,firestore,functions', '--non-interactive'];
  if (mode !== 'start') args.push('node functions/test/ai1-mock.integration.js'+(mode === 'test-browser' ? ' --browser' : ''));
  const child = spawn(process.execPath, [__filename, '--cli', ...args], {
    cwd: path.resolve(__dirname, '../..'), env, stdio: ['inherit','inherit','inherit','ipc'], windowsHide:true});
  let forced, stopping = false, timedOut = false;
  const stop = () => {
    if(stopping) return; stopping = true;
    if(child.connected) child.send('mock-shutdown', () => {});
    forced = setTimeout(() => { if(child.exitCode === null && child.pid) spawn('taskkill.exe', ['/PID',String(child.pid),'/T','/F'], {stdio:'ignore',windowsHide:true}); },10000);
  };
  const timer = mode === 'start' ? undefined : setTimeout(() => { timedOut = true; stop(); }, mode === 'test-browser' ? 360000 : 180000);
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  child.once('error', () => { clearTimeout(timer); process.exitCode = 1; });
  child.once('exit', code => { clearTimeout(timer); clearTimeout(forced); process.removeListener('SIGINT',stop); process.removeListener('SIGTERM',stop); process.exitCode = timedOut ? 1 : code ?? 1; });
}
if(require.main === module && process.argv[2] === '--cli') {
  const cli = process.argv[3]; let stopping = false;
  const stop = async () => {
    if(stopping) return; stopping = true;
    try { await require(path.resolve(path.dirname(cli),'../emulator/controller.js')).cleanShutdown(); process.exit(0); }
    catch(_) { process.exit(1); }
  };
  process.on('message', message => { if(message === 'mock-shutdown') stop(); });
  process.on('disconnect', stop);
  process.argv = [process.execPath,cli,...process.argv.slice(4)]; require(cli);
} else if(require.main === module) main().catch(() => { console.error('BLOCKED: AI1 mock configuration/ports unavailable.'); process.exitCode = 1; });
