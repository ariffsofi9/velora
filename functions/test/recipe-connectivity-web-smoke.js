'use strict';
// Local assets only; no SDK/dependency mutation or browser cache dependency.
const {spawn}=require('node:child_process');
const {readFileSync,existsSync}=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const root=path.resolve(__dirname,'../..');
let output=path.join(root,'build/recipe-connectivity-smoke');
const firebase=path.join(root,'functions/node_modules/firebase');
const sdk=path.join(process.env.USERPROFILE,'flutter/flutter');
const chrome=path.join(process.env.ProgramFiles,'Google/Chrome/Application/chrome.exe');
function stop(child){
  return new Promise(resolve=>{
    if(!child || child.exitCode!==null)return resolve();
    const killer=spawn('taskkill.exe',['/PID',String(child.pid),'/T','/F'],{stdio:'ignore',windowsHide:true});
    killer.on('error',resolve);killer.on('exit',resolve);
  });
}
async function build(ai1Mock=false){
  const flutter=path.join(sdk,'bin/flutter.bat');
  for(const file of [flutter,chrome,...['app','auth','firestore','functions'].map(n=>path.join(firebase,`firebase-${n}.js`))]){
    if(!existsSync(file))throw Error('Cached prerequisites unavailable');
  }
  const command=`& '${flutter.replaceAll("'","''")}' build web --no-pub --no-web-resources-cdn --debug `+
    `--target=test/${ai1Mock?'ai1_mock_web_smoke':'recipe_connectivity_web_smoke'}.dart --output=build/${ai1Mock?'ai1-mock-smoke':'recipe-connectivity-smoke'} `+
    `--dart-define=${ai1Mock?'AI1_MOCK_RECIPES':'RECIPE_CONNECTIVITY_DEMO'}=true --dart-define=USE_FIREBASE_EMULATORS=true `+
    '--dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1';
  await new Promise((resolve,reject)=>{
    const child=spawn('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],{
      cwd:root,stdio:'inherit',windowsHide:true,env:{...process.env,FLUTTER_SUPPRESS_ANALYTICS:'true',CI:'true'}});
    const timer=setTimeout(()=>{stop(child).then(()=>reject(Error('Build timeout')));},180000);
    child.on('error',error=>{clearTimeout(timer);reject(error);});
    child.on('exit',code=>{clearTimeout(timer);code===0?resolve():reject(Error('Build blocked'));});
  });
}
async function run({ai1Mock=false}={}){
  output=path.join(root,ai1Mock?'build/ai1-mock-smoke':'build/recipe-connectivity-smoke');
  await build(ai1Mock);
  let browser,timer,finish;
  const result=new Promise(resolve=>{finish=resolve;});
  const modules=new Set(['firebase-app.js','firebase-auth.js','firebase-firestore.js','firebase-functions.js']);
  const server=http.createServer((req,res)=>{
    res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; connect-src 'self' http://127.0.0.1:* ws://127.0.0.1:*; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; worker-src 'self' blob:");
    if(req.url==='/smoke-result' && req.method==='POST'){
      let body='';req.on('data',chunk=>{body+=chunk;if(body.length>256)req.destroy();});
      req.on('end',()=>{try{const data=JSON.parse(body);res.end('ok');
        finish(data.ok===true && JSON.stringify(data.roles)==='["owner","staff"]');
      }catch(_){res.writeHead(400).end();finish(false);}});return;
    }
    try{
      let url=new URL(req.url,'http://127.0.0.1').pathname;
      if(url==='/'){
        res.setHeader('Content-Type','text/html');
        res.end(`<!doctype html><body><script type="module">
          window.firebase_core=await import('/firebase/firebase-app.js');
          window.firebase_auth=await import('/firebase/firebase-auth.js');
          window.firebase_firestore=await import('/firebase/firebase-firestore.js');
          window.firebase_functions=await import('/firebase/firebase-functions.js');
          const script=document.createElement('script');script.src='/flutter_bootstrap.js';document.body.append(script);
          </script></body>`);return;
      }
      if(url.startsWith('/firebase/')){
        const name=url.slice('/firebase/'.length);if(!modules.has(name))throw Error('Denied');
        let source=readFileSync(path.join(firebase,name),'utf8');
        source=source.replaceAll(/https:\/\/www\.gstatic\.com\/firebasejs\/[^/]+\/firebase-app\.js/g,'/firebase/firebase-app.js');
        res.setHeader('Content-Type','text/javascript');res.end(source);return;
      }
      const file=path.resolve(output,'.'+decodeURIComponent(url));
      if(!file.startsWith(output+path.sep))throw Error('Denied');
      const mime={'.js':'text/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'};
      res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');
      res.end(readFileSync(file));
    }catch(_){res.writeHead(404).end();}
  });
  try{
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
    browser=spawn(chrome,['--headless=new','--disable-background-networking','--disable-component-update',
      '--no-first-run','--no-default-browser-check',`--user-data-dir=${path.join(output,'chrome-profile')}`,
      `http://127.0.0.1:${server.address().port}/`],{stdio:'ignore',windowsHide:true});
    browser.on('error',()=>finish(false));browser.on('exit',()=>finish(false));
    timer=setTimeout(()=>finish(false),90000);
    if(!await result)throw Error('Browser smoke blocked or assertion failed');
    console.log(ai1Mock?'PASS: Flutter Web Owner/Staff mock-v2 UI and read-only details (local assets only).':'PASS: authenticated Flutter Web Owner and Staff -> fake suggestRecipes (local assets only).');
  }finally{clearTimeout(timer);await stop(browser);await new Promise(resolve=>server.close(resolve));}
}
module.exports={run};
