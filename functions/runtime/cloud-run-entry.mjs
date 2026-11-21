import {once} from 'node:events';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createApplication} from '../backend/application.mjs';
import {requireTestProject} from '../backend/backend-errors.mjs';
import {exactHttpsOrigin} from '../backend/http-policy.mjs';
import {createNodeRuntime} from './node-entry.mjs';

const projectId = 'velora-spark-test';
const startupTimeoutMs = 3000;
const denySyntheticOperation = async () => { throw new Error('Synthetic dependency denied.'); };
const synthetic = Object.freeze({
  transport: denySyntheticOperation,
  credential: Object.freeze({
    projectId,
    email: 'synthetic@velora-spark-test.iam.gserviceaccount.com',
    sign: denySyntheticOperation,
  }),
});

function configuration(env) {
  requireTestProject(env.VELORA_FIREBASE_PROJECT);
  const rawPort = env.PORT;
  if (typeof rawPort !== 'string' || !/^[1-9]\d{0,4}$/.test(rawPort) || Number(rawPort) > 65535) {
    throw new Error('Invalid listener port.');
  }
  const canonicalOrigin = env.VELORA_CANONICAL_ORIGIN;
  if (!exactHttpsOrigin(canonicalOrigin)) throw new Error('Invalid canonical origin.');
  return {port: Number(rawPort), canonicalOrigin};
}

// Programmatic options support loopback tests. The direct entry never reads
// credentials or dependency selectors from the environment.
export async function startCloudRun({
  env = process.env, dependencies = synthetic, signals = process,
  log = event => console.log(JSON.stringify(event)), host = '127.0.0.1',
  runtimeOptions,
} = {}) {
  let runtime;
  let category = 'invalid-configuration';
  try {
    const {port, canonicalOrigin} = configuration(env);
    const application = createApplication({
      projectId, publicOrigin: canonicalOrigin, allowedOrigins: [canonicalOrigin],
      transport: dependencies.transport, credential: dependencies.credential,
    });
    runtime = createNodeRuntime({...runtimeOptions, application, canonicalOrigin});
    category = 'listener-failure';
    const startup = new AbortController();
    const deadline = setTimeout(() => {
      category = 'startup-deadline';
      startup.abort();
    }, startupTimeoutMs);
    let stopping;
    function stop() {
      stopping ??= (async () => {
        log({event: 'shutdown-started'});
        await runtime.close();
        log({event: 'shutdown-complete'});
      })().finally(() => signals.removeListener('SIGTERM', onSignal));
      return stopping;
    }
    function onSignal() {
      if (!runtime.server.listening && !startup.signal.aborted) startup.abort();
      void stop().catch(() => {
        log({event: 'shutdown-failed', category: 'listener-close'});
        if (signals === process) process.exitCode = 1;
      });
    }
    signals.on('SIGTERM', onSignal);
    try {
      runtime.server.listen({port, host, signal: startup.signal});
      await once(runtime.server, 'listening', {signal: startup.signal});
      if (stopping) throw new Error('Listener stopped during startup.');
    } catch (error) {
      signals.removeListener('SIGTERM', onSignal);
      throw error;
    } finally {
      clearTimeout(deadline);
    }
    log({event: 'startup-complete'});
    return Object.freeze({close: stop});
  } catch {
    await runtime?.close().catch(() => {});
    log({event: 'startup-failed', category});
    throw new Error('Cloud Run launcher startup failed.');
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    await startCloudRun({host: '0.0.0.0'});
  } catch {
    process.exitCode = 1;
  }
}
