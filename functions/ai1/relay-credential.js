'use strict';
// Windows CurrentUser DPAPI envelope. Only ciphertext enters Firebase CLI env/logs.
const {execFileSync} = require('node:child_process');
const {RecipeError} = require('./recipe-service');
function blocked() { throw new RecipeError('failed-precondition', 'Relay credential protection unavailable.'); }
function transform(value, protect) {
  if (process.platform !== 'win32') blocked();
  const operation = protect ? 'Protect' : 'Unprotect';
  const command = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; " +
    '$inputValue=[Console]::In.ReadToEnd(); ' +
    '$bytes=[Convert]::FromBase64String($inputValue); ' +
    "$entropy=[Text.Encoding]::UTF8.GetBytes('VELORA-AI2-RELAY-v1'); " +
    `$result=[Security.Cryptography.ProtectedData]::${operation}($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser); ` +
    '[Console]::Out.Write([Convert]::ToBase64String($result));';
  try {
    const env = {};
    for (const name of ['SystemRoot', 'SYSTEMROOT', 'WINDIR', 'USERPROFILE', 'APPDATA',
      'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH', 'Path']) {
      if (process.env[name] !== undefined) env[name] = process.env[name];
    }
    return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], {
      input: value, encoding: 'utf8', timeout: 8000, maxBuffer: 16384,
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], env,
    }).trim();
  } catch (_) { blocked(); }
}
function protectRelaySecret(secret) {
  if (typeof secret !== 'string' || !/^[a-f0-9]{64}$/.test(secret)) blocked();
  return 'dpapi-v1:' + transform(Buffer.from(secret, 'hex').toString('base64'), true);
}
function unprotectRelaySecret(envelope) {
  if (typeof envelope !== 'string' || envelope.length > 8192 ||
      !/^dpapi-v1:[A-Za-z0-9+/]+={0,2}$/.test(envelope)) blocked();
  const decoded = Buffer.from(transform(envelope.slice(9), false), 'base64');
  if (decoded.length !== 32) blocked();
  return decoded.toString('hex');
}
module.exports = {protectRelaySecret, unprotectRelaySecret};
