'use strict';

// Use the installed CLI with a deliberately minimal environment. In particular,
// never pass API keys, cloud credential variables, DEBUG or NODE_OPTIONS to it.
// Live opt-in keeps the Groq key in this process, outside Firebase CLI logging.
const {spawn} = require('node:child_process');
const {existsSync, readdirSync} = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const {randomBytes} = require('node:crypto');
const {PROJECT, HOSTS} = require('./recipe-service');
const {createGroqProvider, serveProvider} = require('./groq-provider');
const {PREFIX, SAFE_CODES, safeTitles} = require('./live-smoke');

function childEnvironment(source = process.env) {
  const env = {};
  for (const key of ['PATH', 'Path', 'PATHEXT', 'APPDATA', 'LOCALAPPDATA', 'USERPROFILE',
    'TEMP', 'TMP', 'SystemRoot', 'SYSTEMROOT', 'WINDIR', 'ComSpec', 'JAVA_HOME',
    'HOMEDRIVE', 'HOMEPATH', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramData']) {
    if (source[key] !== undefined) env[key] = source[key];
  }
  env.CI = '1';
  return env;
}

async function main() {
  const mode = process.argv[2];
  if (!['start', 'test', 'start-groq', 'test-groq'].includes(mode)) throw Error('Use start, test, start-groq or test-groq.');
  if (readdirSync(__dirname).some((name) => name.startsWith('.env'))) {
    throw Error('AI-1 must not load environment files.');
  }
  const env = childEnvironment();
  const cli = path.join(env.APPDATA ?? '', 'npm/node_modules/firebase-tools/lib/bin/firebase.js');
  if (!existsSync(cli)) throw Error('Installed Windows Firebase CLI not found; no installation attempted.');
  const servers = [];
  try {
    // Fail before starting any emulator if an AI-1 port is occupied. Never reuse
    // a working emulator and never stop another process to claim a port.
    for (const port of [19099, 19080, 19150, 15001, 14001, 14400, 14500, 19299, 19499]) {
      const server = net.createServer();
      await new Promise((resolve, reject) => {
        server.once('error', () => reject(Error(`AI-1 port ${port} is unavailable.`)));
        server.listen({host: '127.0.0.1', port, exclusive: true}, resolve);
      });
      servers.push(server);
    }
  } finally {
    await Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))));
  }
  let broker;
  let liveCalls = 0;
  if (mode === 'start-groq' || mode === 'test-groq') {
    const provider = createGroqProvider({env: {GCLOUD_PROJECT: PROJECT,
      FUNCTIONS_EMULATOR: 'true', ...HOSTS, AI_RECIPE_PROVIDER: 'groq',
      GROQ_API_KEY: process.env.GROQ_API_KEY}});
    const pipe = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
    broker = serveProvider(pipe, async (input) => { liveCalls++; return provider(input); });
    await new Promise((resolve, reject) => {
      broker.once('error', () => reject(Error('Local provider relay could not start.')));
      broker.listen(pipe, resolve);
    });
    env.AI_RECIPE_PROVIDER = 'groq';
    env.AI2_PROVIDER_PIPE = pipe;
  } else {
    env.AI_RECIPE_PROVIDER = 'fake';
  }
  const args = [cli, mode === 'test' ? 'emulators:exec' : 'emulators:start',
    '--config', 'firebase.ai1-emulator.json', '--project', PROJECT,
    '--only', 'auth,firestore,functions', '--non-interactive'];
  if (mode === 'test') args.push('node --test functions/test/ai1-emulator.integration.test.js');
  const liveTest = mode === 'test-groq';
  if (liveTest) env.AI2_LIVE_SMOKE = 'true';
  const child = spawn(process.execPath, [__filename, '--cli', ...args], {
    cwd: path.resolve(__dirname, '../..'), env,
    stdio: liveTest ? ['ignore', 'pipe', 'pipe', 'ipc'] : ['inherit', 'inherit', 'inherit', 'ipc'],
    windowsHide: true,
  });
  let runner;
  let stopping = false;
  let interrupted = false;
  let result;
  let runnerCode;
  let forced;
  let watchdog;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    runner?.kill(); // Only the runner spawned by this launcher, never another process.
    if (child.connected) child.send('ai2-shutdown', () => {});
    forced = setTimeout(() => {
      // Last resort only for our still-running CLI process tree on Windows.
      if (child.exitCode === null && child.pid) {
        spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'],
          {stdio: 'ignore', windowsHide: true});
      }
    }, 10000);
  };
  const interrupt = () => { interrupted = true; stop(); };
  process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
  child.once('error', () => {
    broker?.close(); process.exitCode = 1;
    console.error('FAIL: Isolated emulator process could not start.');
  });
  child.once('close', (code) => {
    clearTimeout(forced); clearTimeout(watchdog);
    process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
    runner?.kill(); broker?.close();
    if (liveTest) {
      const passed = !interrupted && code === 0 && runnerCode === 0 && result?.ok === true && liveCalls === 1;
      if (passed) {
        console.log('PASS: Live AI-2 callable and structured recipe validation.');
        for (const title of result.titles) console.log(`Recipe: ${title}`);
      } else {
        console.error(`FAIL: ${interrupted ? 'INTERRUPTED' : result?.code ?? 'SMOKE_FAILED'}.`);
      }
      process.exitCode = passed ? 0 : 1;
    } else process.exitCode = interrupted ? 130 : code ?? 1;
  });
  if (liveTest) {
    // Raw Firebase CLI/provider output is never printed by the live test mode.
    child.stdout.resume(); child.stderr.resume();
    watchdog = setTimeout(stop, 120000);
    const ready = async () => {
      for (let attempt = 0; attempt < 120 && !stopping && child.exitCode === null; attempt++) {
        try {
          const response = await fetch(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/suggestRecipes`, {
            method: 'POST', redirect: 'error', signal: AbortSignal.timeout(1000),
            headers: {'Content-Type': 'application/json'}, body: JSON.stringify({data: {}}),
          });
          const body = await response.json();
          if (body.error?.status === 'UNAUTHENTICATED') return true;
        } catch (_) { /* Fixed local endpoint only; no provider call without Auth. */ }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      return false;
    };
    if (!await ready()) { stop(); return; }
    if (stopping) return;
    const runnerEnv = {...env, GCLOUD_PROJECT: PROJECT, ...HOSTS};
    runner = spawn(process.execPath, [path.join(__dirname, 'live-smoke.js')], {
      cwd: path.resolve(__dirname, '../..'), env: runnerEnv,
      stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
    });
    runner.stdout.setEncoding('utf8');
    let line = '';
    runner.stdout.on('data', (chunk) => {
      line += chunk.toString('utf8');
      if (line.length > 8192) { result = {ok: false, code: 'SMOKE_OUTPUT_INVALID'}; stop(); return; }
      let newline;
      while ((newline = line.indexOf('\n')) !== -1) {
        const item = parseSmokeLine(line.slice(0, newline).trim());
        if (item) result = result ? {ok: false, code: 'SMOKE_OUTPUT_INVALID'} : item;
        line = line.slice(newline + 1);
      }
    });
    runner.stderr.resume();
    runner.once('error', () => { result = {ok: false, code: 'SMOKE_RUNNER_FAILED'}; stop(); });
    runner.once('close', (code) => { runnerCode = code; stop(); });
  }
}

function parseSmokeLine(line) {
  if (!line.startsWith(PREFIX)) return null;
  try {
    const result = JSON.parse(line.slice(PREFIX.length));
    if (result.ok === true) return {ok: true, titles: safeTitles(result.titles)};
    const allowed = [...SAFE_CODES, 'CALLABLE_FAILED', 'SMOKE_VALIDATION_FAILED'];
    return {ok: false, code: allowed.includes(result.code) ? result.code : 'SMOKE_FAILED'};
  } catch (_) { return {ok: false, code: 'SMOKE_OUTPUT_INVALID'}; }
}

// Internal child entry: graceful shutdown through the installed CLI controller.
// No secret is present in this child's environment or arguments.
if (require.main === module && process.argv[2] === '--cli') {
  const cli = process.argv[3];
  let shutdown = false;
  process.on('message', async (message) => {
    if (message !== 'ai2-shutdown' || shutdown) return;
    shutdown = true;
    try {
      await require(path.resolve(path.dirname(cli), '../emulator/controller.js')).cleanShutdown();
      process.exit(0);
    } catch (_) { process.exit(1); }
  });
  process.argv = [process.execPath, cli, ...process.argv.slice(4)];
  require(cli);
} else if (require.main === module) main().catch(() => {
  console.error('FAIL: AI-1 launch configuration, credentials or local ports could not be verified.');
  process.exitCode = 1;
});

module.exports = {childEnvironment, parseSmokeLine};
