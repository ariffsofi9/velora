import test from 'node:test';
import assert from 'node:assert/strict';
import {encode, decode, encodeWrite, timestamp, deleteValue, toTimestamp, fieldPath, parseTimestamp} from '../backend/firestore-codec.mjs';

test('round trips supported scalars, maps, arrays and dates without fabricating absent fields', () => {
  const input = {string: '咖啡', count: Number.MAX_SAFE_INTEGER, negative: -Number.MAX_SAFE_INTEGER,
    fraction: 1.25, zero: 0, yes: true, no: false, nullable: null,
    values: ['x', {a: [1, 2]}], empty: [], map: {}, date: new Date('2030-01-02T00:00:00Z')};
  const output = decode(encode(input));
  assert.deepEqual(output, input);
  assert.equal(Object.hasOwn(output, 'missing'), false);
  assert.equal(output.nullable, null);
  assert.deepEqual(encode(123), {integerValue: '123'});
  assert.deepEqual(decode({arrayValue: {}}), []);
  assert.deepEqual(decode({mapValue: {}}), {});
});

for (const [index, value] of [undefined, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1,
  1n, () => {}, Symbol('fake'), new Date('bad'), /regex/, new Map(), [[1]],
  {nested: timestamp()}, {nested: deleteValue()}, [timestamp()], Array(2),
  'a'.repeat(65537), {['a'.repeat(1501)]: 1}, {['bad\n']: 1}, '\ud800', new Date('0000-01-01T00:00:00Z')].entries()) {
  test(`rejects unsupported encoding case ${index}`, () => {
    assert.throws(() => encode(value), {kind: 'codec', code: 'invalid-value'});
  });
}

for (const value of [null, [], {}, {unknownValue: 1}, {booleanValue: 'true'},
  {stringValue: 1}, {nullValue: 'NULL_VALUE'}, {integerValue: '9007199254740992'},
  {integerValue: '1.5'}, {integerValue: '1\n'}, {integerValue: '01'},
  {doubleValue: NaN}, {doubleValue: 9007199254740992}, {stringValue: 'x', booleanValue: false},
  {mapValue: {fields: null}}, {mapValue: {extra: 1}}, {arrayValue: {values: null}},
  {arrayValue: {values: [{arrayValue: {}}]}}, {timestampValue: '2026-02-30T00:00:00Z'},
  {timestampValue: '2026-11-11T00:00:00Z\n'}, {timestampValue: 'bad'}]) {
  test(`rejects malformed wire value ${JSON.stringify(value)}`, () => {
    assert.throws(() => decode(value), {kind: 'codec', code: 'invalid-value'});
  });
}

test('server timestamp and delete markers produce disjoint atomic transforms/masks', () => {
  const patch = encodeWrite({version: 2, archivedAt: deleteValue(), archivedBy: deleteValue(), updatedAt: timestamp()});
  assert.deepEqual(patch.fields, {version: {integerValue: '2'}});
  assert.deepEqual(patch.mask, ['`version`', '`archivedAt`', '`archivedBy`']);
  assert.deepEqual(patch.transforms, [{fieldPath: '`updatedAt`', setToServerValue: 'REQUEST_TIME'}]);
  assert.equal(JSON.stringify(patch).includes('null'), false);
  assert.throws(() => encodeWrite({field: deleteValue()}, 'create'));
  assert.throws(() => encodeWrite({field: deleteValue()}, 'set'));
  assert.throws(() => encodeWrite({field: Symbol('Firestore delete field')}));
  assert.throws(() => encodeWrite({field: {value: timestamp()}}));
  assert.throws(() => encodeWrite({field: [deleteValue()]}));
  assert.throws(() => encodeWrite({}));
});

test('literal field paths escape punctuation without nested transform ambiguity', () => {
  assert.equal(fieldPath('a.b'), '`a.b`');
  assert.equal(fieldPath('a`b\\c'), '`a\\`b\\\\c`');
  assert.deepEqual(encodeWrite({'a.b': timestamp()}).transforms,
    [{fieldPath: '`a.b`', setToServerValue: 'REQUEST_TIME'}]);
  const input = JSON.parse('{"__proto__":{"value":3},"constructor":1}');
  const output = decode(encode(input));
  assert.equal(Object.hasOwn(output, '__proto__'), true);
  assert.equal(output.__proto__.value, 3);
  assert.equal({}.value, undefined);
});

test('rejects accessors, cycles, excessive depth, fields, nodes and document bytes', () => {
  const accessor = Object.defineProperty({}, 'x', {enumerable: true, get() { throw Error('must not run'); }});
  assert.throws(() => encode(accessor), {kind: 'codec'});
  const cyclic = {}; cyclic.self = cyclic;
  assert.throws(() => encode(cyclic), {kind: 'codec'});
  let deep = 1; for (let i = 0; i < 22; i++) deep = {v: deep};
  assert.throws(() => encode(deep), {kind: 'codec'});
  assert.throws(() => encode(Object.fromEntries(Array.from({length: 1001}, (_, i) => [`f${i}`, 1]))));
  assert.throws(() => encode(Array(1001).fill(1)));
  assert.throws(() => encode(Array.from({length: 100}, () => ({values: Array(100).fill(1)}))));
  assert.throws(() => encode(Array(20).fill('x'.repeat(65536))));
});

test('timestamp metadata validates nanos while domain dates are cloned UTC instants', () => {
  const raw = '2026-11-11T00:00:00.123456789Z';
  assert.equal(parseTimestamp(raw).toISOString(), '2026-11-11T00:00:00.123Z');
  assert.equal(raw, '2026-11-11T00:00:00.123456789Z');
  const date = new Date('2030-01-02T00:00:00.000Z'), copy = toTimestamp(date);
  assert.notEqual(copy, date);
  date.setUTCFullYear(2031);
  assert.equal(encode(copy).timestampValue, '2030-01-02T00:00:00.000Z');
});
