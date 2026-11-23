import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, extname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const require = createRequire(new URL('../../feasibility/shared-backend/runtime/package.json', import.meta.url));
const {build} = require('esbuild');

export async function bundleWorkerFixture(contents) {
  const root = fileURLToPath(new URL('../..', import.meta.url));
  const result = await build({stdin: {contents, resolveDir: root},
    bundle: true, write: false, format: 'esm', platform: 'browser', external: ['cloudflare:*', 'node:*'],
    banner: {js: `import * as nodeCrypto from 'node:crypto';
      const require = name => { if (name === 'node:crypto') return nodeCrypto; throw Error('Unexpected import'); };`},
    plugins: [{name: 'read-local-fixture-modules', setup(builder) {
      builder.onResolve({filter: /^\./}, args => ({
        path: extname(args.path) ? resolve(args.resolveDir, args.path)
          : createRequire(join(args.resolveDir, 'fixture.cjs')).resolve(args.path),
        namespace: 'fixture',
      }));
      builder.onLoad({filter: /./, namespace: 'fixture'}, async args => ({
        contents: await readFile(args.path, 'utf8'), resolveDir: dirname(args.path),
      }));
    }}]});
  return result.outputFiles[0].text;
}
