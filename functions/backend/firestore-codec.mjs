import {BackendError} from './backend-errors.mjs';

const SERVER_TIME = Symbol('Firestore REQUEST_TIME');
const DELETE_FIELD = Symbol('Firestore delete field');
export const timestamp = () => SERVER_TIME;
export const deleteValue = () => DELETE_FIELD;
export const record = value => value !== null && typeof value === 'object' &&
  [Object.prototype, null].includes(Object.getPrototypeOf(value));
const fail = () => { throw new BackendError('codec', 'invalid-value'); };

export function fieldPath(key) {
  if (typeof key !== 'string' || !key || !key.isWellFormed() || Buffer.byteLength(key) > 1500 || /\p{Cc}/u.test(key)) fail();
  return '`' + key.replaceAll('\\', '\\\\').replaceAll('`', '\\`') + '`';
}

export function parseTimestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z$/.test(value) ||
      value.trim() !== value || value.startsWith('0000')) fail();
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 19) !== value.slice(0, 19)) fail();
  return date;
}
export function toTimestamp(date) {
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) fail();
  parseTimestamp(date.toISOString());
  return new Date(date.getTime());
}

function entries(value) {
  if (!record(value) || Reflect.ownKeys(value).some(key => typeof key !== 'string')) fail();
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (Object.values(descriptors).some(d => !Object.hasOwn(d, 'value') || !d.enumerable)) fail();
  const result = Object.entries(value);
  if (result.length > 1000) fail();
  return result;
}
function context() { return {nodes: 0}; }
function visit(ctx, depth) { if (++ctx.nodes > 10000 || depth > 20) fail(); }
function string(value) { if (!value.isWellFormed() || Buffer.byteLength(value) > 65536) fail(); return value; }
function number(value) {
  if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) fail();
  return value;
}
function encodeValue(value, ctx, depth) {
  visit(ctx, depth);
  if (value === null) return {nullValue: null};
  if (typeof value === 'boolean') return {booleanValue: value};
  if (typeof value === 'string') return {stringValue: string(value)};
  if (typeof value === 'number') {
    number(value);
    return Number.isInteger(value) ? {integerValue: String(value)} : {doubleValue: value};
  }
  if (value instanceof Date) return {timestampValue: toTimestamp(value).toISOString()};
  if (Array.isArray(value)) {
    if (value.length > 1000 || Object.keys(value).length !== value.length ||
        value.some(Array.isArray)) fail();
    return {arrayValue: {values: value.map(v => encodeValue(v, ctx, depth + 1))}};
  }
  return {mapValue: {fields: Object.fromEntries(entries(value).map(([key, v]) => {
    fieldPath(key);
    return [key, encodeValue(v, ctx, depth + 1)];
  }))}};
}
function decodeValue(value, ctx, depth) {
  visit(ctx, depth);
  const pairs = entries(value);
  if (pairs.length !== 1) fail();
  const [type, v] = pairs[0];
  if (type === 'nullValue' && v === null) return null;
  if (type === 'booleanValue' && typeof v === 'boolean') return v;
  if (type === 'stringValue' && typeof v === 'string') return string(v);
  if (type === 'integerValue' && typeof v === 'string' && v.trim() === v &&
      /^-?(0|[1-9]\d*)$/.test(v) && v.length <= 17 && Number.isSafeInteger(Number(v))) return Number(v);
  if (type === 'doubleValue' && typeof v === 'number') return number(v);
  if (type === 'timestampValue') return parseTimestamp(v);
  if (type === 'mapValue') {
    if (entries(v).some(([k]) => k !== 'fields')) fail();
    return Object.fromEntries(entries(v.fields === undefined ? {} : v.fields).map(([k, data]) => {
      fieldPath(k); return [k, decodeValue(data, ctx, depth + 1)];
    }));
  }
  if (type === 'arrayValue') {
    if (entries(v).some(([k]) => k !== 'values')) fail();
    const values = v.values === undefined ? [] : v.values;
    if (!Array.isArray(values) || values.length > 1000 || Object.keys(values).length !== values.length) fail();
    const result = values.map(data => decodeValue(data, ctx, depth + 1));
    if (result.some(Array.isArray)) fail();
    return result;
  }
  fail();
}
function size(value) {
  try { if (Buffer.byteLength(JSON.stringify(value)) > 1048576) fail(); } catch { fail(); }
  return value;
}
export const encode = value => size(encodeValue(value, context(), 0));
export const decode = value => size(decodeValue(value, context(), 0));

// Only literal top-level fields are supported for transforms; quoted masks
// preserve dots/backticks as field names and cannot become nested field paths.
export function encodeWrite(data, kind = 'update') {
  if (!['create', 'update', 'set'].includes(kind)) fail();
  const fields = [], transforms = [], mask = [], ctx = context();
  const pairs = entries(data);
  if (!pairs.length) fail();
  for (const [key, value] of pairs) {
    const path = fieldPath(key);
    if (value === SERVER_TIME) transforms.push({fieldPath: path, setToServerValue: 'REQUEST_TIME'});
    else if (value === DELETE_FIELD) {
      if (kind !== 'update') fail();
      mask.push(path);
    } else {
      fields.push([key, encodeValue(value, ctx, 0)]);
      mask.push(path);
    }
  }
  return size({fields: Object.fromEntries(fields), transforms, mask});
}
