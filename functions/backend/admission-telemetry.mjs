const stages = new Set([
  'worker-local-limit',
  'shared-project-limit',
  'shared-pre-auth-limit',
  'shared-record-limit',
  'per-uid-limit',
  'release-acknowledged',
  'release-unconfirmed',
]);
const fields = [
  'active', 'limit', 'project', 'preAuth', 'reserved', 'running', 'closed',
  'runningUnattributed', 'runningPastReplay', 'runningPastReplayOneMinute',
];

// At most one event per stage per minute in this runtime. Reading optional
// counters is deferred until an event will actually be emitted.
export function createAdmissionTelemetry({
  now = Date.now, log = event => console.log(event),
} = {}) {
  const last = new Map();
  return (stage, readCounts) => {
    try {
      if (!stages.has(stage)) return;
      const time = now();
      if (last.has(stage) && time - last.get(stage) < 60000) return;
      last.set(stage, time);
      const event = {event: 'admission', stage};
      try {
        const counts = readCounts?.();
        for (const field of fields) {
          const value = counts?.[field];
          if (Number.isSafeInteger(value) && value >= 0) event[field] = value;
        }
      } catch { /* The stage is still useful without occupancy. */ }
      log(event);
    } catch { /* Telemetry never changes an admission or release outcome. */ }
  };
}

export const recordAdmission = createAdmissionTelemetry();
