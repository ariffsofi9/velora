
'use strict';
const {spawn} = require('node:child_process');
const {existsSync} = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const {childEnvironment} = require('../ai1/run-emulators');
async function main() {
  const mode = process.argv[2];
  if (!['test', 'start', 'test-team'].includes(mode)) throw Error('Use test, test-team or start.');
  const team = mode === 'test-team';
  const env = childEnvironment();
  const cli = path.join(env.APPDATA, 'npm/node_modules/firebase-tools/lib/bin/firebase.js');
  if (!existsSync(cli)) throw Error('Installed CLI required.');
  const checks = [];
  try {
    for (const port of (team ? [39099,38080,38150,35001,34400,34500,39299,39499] :
      [29099,28080,28150,25001,24001,24400,24500,29299,29499])) {
      const server = net.createServer();
      await new Promise((resolve,reject) => {server.once('error',reject);server.listen({host:'127.0.0.1',port,exclusive:true},resolve);});
      checks.push(server);
    }
  } finally {await Promise.all(checks.map(s=>new Promise(r=>s.close(r))));}
  const args = [cli, mode === 'start' ? 'emulators:start' : 'emulators:exec',
    '--config',team ? 'firebase.team-emulator.json' : 'firebase.staff-emulator.json',
    '--project',team ? 'demo-velora-team' : 'demo-velora-staff',
    '--only','auth,firestore,functions','--non-interactive'];
  if(mode!=='start')args.push('node --test functions/test/staff-emulator.integration.test.js');
  const child=spawn(process.execPath,args,{cwd:path.resolve(__dirname,'../..'),env,stdio:'inherit',windowsHide:true});
  child.on('error',()=>{console.error('Staff demo launch failed.');process.exitCode=1;});
  child.on('exit',code=>{process.exitCode=code??1;});
}
main().catch(()=>{console.error('Staff demo configuration or ports unavailable.');process.exitCode=1;});
