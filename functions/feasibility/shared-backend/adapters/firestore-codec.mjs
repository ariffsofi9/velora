import {failure} from './http.mjs';
export const SERVER_TIME = Symbol('server-timestamp');
const record = value => value && Object.getPrototypeOf(value) === Object.prototype;
export function fieldPath(key) {
  if (typeof key !== 'string' || !key || key.length > 1500 || /[\x00-\x1f]/.test(key)) throw failure('invalid-value');
  return '`' + key.replaceAll('\\', '\\\\').replaceAll('`', '\\`') + '`';
}
export function encode(value, depth = 0) {
  if (depth > 20) throw failure('invalid-value');
  if (value === null) return {nullValue: null};
  if (typeof value === 'boolean') return {booleanValue: value};
  if (typeof value === 'string') return {stringValue: value};
  if (typeof value === 'number' && Number.isFinite(value)) {
    if (Number.isInteger(value)) { if (!Number.isSafeInteger(value)) throw failure('invalid-value'); return {integerValue: String(value)}; }
    return {doubleValue: value};
  }
  if (value instanceof Date && Number.isFinite(value.getTime())) return {timestampValue: value.toISOString()};
  if (Array.isArray(value)) {
    if (value.some(Array.isArray)) throw failure('invalid-value');
    return {arrayValue: {values: value.map(v => encode(v, depth + 1))}};
  }
  if (record(value)) return {mapValue: {fields: Object.fromEntries(Object.entries(value).map(([k,v]) => { fieldPath(k); return [k, encode(v, depth + 1)]; }))}};
  throw failure('invalid-value');
}
export function decode(value, depth = 0) {
  if (!record(value) || Object.keys(value).length !== 1 || depth > 20) throw failure('invalid-value');
  const [type, v] = Object.entries(value)[0];
  if (type === 'nullValue' && v === null) return null;
  if (type === 'stringValue' && typeof v === 'string') return v;
  if (type === 'booleanValue' && typeof v === 'boolean') return v;
  if (type === 'integerValue' && typeof v === 'string' && /^-?(0|[1-9]\d*)$/.test(v) && Number.isSafeInteger(Number(v))) return Number(v);
  if (type === 'doubleValue' && typeof v === 'number' && Number.isFinite(v) && (!Number.isInteger(v) || Number.isSafeInteger(v))) return v;
  if (type === 'timestampValue' && typeof v === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z$/.test(v) && Number.isFinite(Date.parse(v)) && new Date(v).toISOString().slice(0,19) === v.slice(0,19)) return new Date(v);
  if (type === 'arrayValue' && record(v) && Object.keys(v).every(k => k === 'values') && (v.values === undefined || Array.isArray(v.values))) {
    const result = (v.values ?? []).map(x => decode(x, depth + 1)); if (result.some(Array.isArray)) throw failure('invalid-value'); return result;
  }
  if (type === 'mapValue' && record(v) && Object.keys(v).every(k => k === 'fields') && (v.fields === undefined || record(v.fields))) {
    return Object.fromEntries(Object.entries(v.fields ?? {}).map(([k,x]) => { fieldPath(k); return [k, decode(x, depth + 1)]; }));
  }
  throw failure('invalid-value');
}
export function encodeWrite(data) {
  if (!record(data)) throw failure('invalid-value');
  const fields = {}; const transforms = [];
  for (const [key,value] of Object.entries(data)) {
    const path = fieldPath(key);
    if (value === SERVER_TIME) transforms.push({fieldPath: path, setToServerValue: 'REQUEST_TIME'});
    else Object.defineProperty(fields, key, {value: encode(value), enumerable: true});
  }
  return {fields, transforms};
}
