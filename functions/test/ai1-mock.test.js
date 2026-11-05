'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {PROJECT, HOSTS, validateRecipes} = require('../ai1/recipe-service');
const {assertMock, mockProvider} = require('../ai1/mock-callable');
const env = {GCLOUD_PROJECT:PROJECT,FUNCTIONS_EMULATOR:'true',...HOSTS,AI1_MOCK_RECIPES:'true',AI_RECIPE_PROVIDER:'fake'};
test('AI1 mock guard never accesses keys and rejects all other profiles/modes', () => {
  const safe = {...env}; Object.defineProperty(safe,'GROQ_API_KEY',{get(){assert.fail('No key access');}});
  assert.doesNotThrow(()=>assertMock(safe));
  for(const extra of [{GCLOUD_PROJECT:'demo-velora-staff'},{GCLOUD_PROJECT:'demo-velora-ai-connectivity'},
    {AI1_MOCK_RECIPES:undefined},{AI_RECIPE_PROVIDER:'groq'},{AI2_PROVIDER_PIPE:'pipe'},
    {AI2_RELAY_CREDENTIAL:'credential'},{FIRESTORE_EMULATOR_HOST:'127.0.0.1:48080'},{FUNCTIONS_EMULATOR:'false'}]) {
    assert.throws(()=>assertMock({...env,...extra}),{code:'failed-precondition'});
  }
});
test('synthetic v2 output is stock bounded, explicitly mock and validates without Groq', async () => {
  const items = [{id:'banana',name:'Banana',quantity:2,unit:'pcs'},{id:'milk',name:'Milk',quantity:2,unit:'L'}];
  const recipes = await mockProvider({items});
  assert.deepEqual(validateRecipes(recipes,items,1,'groq'),recipes);
  assert.equal(recipes[0].ingredients[1].quantity,0.25);
  assert.match(recipes[0].whyRecommended,/not real Groq/);
  assert.deepEqual(await mockProvider({items:[]}),[]);
});
