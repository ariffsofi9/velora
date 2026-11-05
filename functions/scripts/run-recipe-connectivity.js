'use strict';
const {spawn}=require('node:child_process');
const {existsSync,readdirSync}=require('node:fs');
const path=require('node:path');
const net=require('node:net');
const {childEnvironment}=require('../ai1/run-emulators');
async function main(){
  const mode=process.argv[2];
  if(!['test','start','test-browser','test-web-smoke'].includes(mode))throw Error('Use test, start, test-browser or test-web-smoke.');
  const source=path.resolve(__dirname,'../recipe-connectivity');
  for(const folder of [source,path.resolve(__dirname,'..')]){
    if(readdirSync(folder).some(name=>name.startsWith('.env')))throw Error('Environment files are not allowed in this test profile.');
  }
  const env=childEnvironment();env.AI_RECIPE_PROVIDER='fake';
  const cli=path.join(env.APPDATA,'npm/node_modules/firebase-tools/lib/bin/firebase.js');
  if(!existsSync(cli))throw Error('Installed CLI required.');
  const servers=[];
  try{
    for(const port of [49099,48080,48150,45001,44001,44400,44500,49299,49499]){
      const server=net.createServer();
      await new Promise((resolve,reject)=>{server.once('error',reject);server.listen({host:'127.0.0.1',port,exclusive:true},resolve);});
      servers.push(server);
    }
  }finally{await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));}
  const args=[cli,mode==='start'?'emulators:start':'emulators:exec',
    '--config','firebase.recipe-connectivity-emulator.json','--project','demo-velora-ai-connectivity',
    '--only','auth,firestore,functions','--non-interactive'];
  if(mode!=='start')args.push(mode==='test'?
    'node --test functions/test/recipe-connectivity.integration.test.js':
    `node functions/test/recipe-connectivity-browser.js${mode==='test-web-smoke'?' --web-smoke':''}`);
  const child=spawn(process.execPath,[__filename,'--cli',...args],{cwd:path.resolve(__dirname,'../..'),env,
    stdio:['inherit','inherit','inherit','ipc'],windowsHide:true});
  const stop=()=>{if(child.connected)child.send('fake-connectivity-shutdown',()=>{});};
  process.on('SIGINT',stop);process.on('SIGTERM',stop);
  child.on('error',()=>{console.error('Fake connectivity launch failed.');process.exitCode=1;});
  child.on('exit',(code,signal)=>{
    process.removeListener('SIGINT',stop);process.removeListener('SIGTERM',stop);
    console.log(`Fake connectivity emulator exit: ${code??'none'}${signal?' (interrupted)':''}`);
    process.exitCode=code??1;
  });
}
if(require.main===module&&process.argv[2]==='--cli'){
  const cli=process.argv[3];let stopping=false;
  const stop=async()=>{if(stopping)return;stopping=true;
    try{await require(path.resolve(path.dirname(cli),'../emulator/controller.js')).cleanShutdown();process.exit(0);}
    catch(_){process.exit(1);}
  };
  process.on('message',message=>{if(message==='fake-connectivity-shutdown')stop();});
  process.on('disconnect',stop);
  process.argv=[process.execPath,cli,...process.argv.slice(4)];require(cli);
}else if(require.main===module)main().catch(()=>{console.error('Fake connectivity configuration or ports unavailable.');process.exitCode=1;});
