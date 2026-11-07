import test from 'node:test';
import assert from 'node:assert/strict';
import {names,scenario} from './scenarios.mjs';
let outbound=0;globalThis.fetch=()=>{outbound++;throw Error('Unexpected network');};
test.after(()=>assert.equal(outbound,0));
for(const name of names)test(name,async()=>{const evidence=await scenario(name);assert.equal(evidence.ok,true);});
