'use strict';
// Host protocol only. No simulation, campaign evaluation or authoritative maths.
(function (root) {
  const decimal = x => typeof x === 'string' && /^(0|[1-9][0-9]*)$/.test(x);
  class StaleResponse extends Error {}
  class ResponseGate {
    constructor() { this.runtime = null; this.serial = -1n; this.retired = new Set(); }
    accept(data, requestRuntime, observation) {
      const s = data?.shell, v = data?.view;
      if (!v || s?.schema !== 'red-dune-shell-0.5' || typeof s.runtimeId !== 'string' || !s.runtimeId || !decimal(s.responseSerial) || !s.session || !s.catalog || !s.load || !data.runtime)
        throw new Error('Host protocol is incomplete. The last confirmed view is retained');
      if (![s.session.world, s.session.branch, s.session.epochCounter, v.world, v.branch, v.boundary].every(decimal) || s.session.world !== v.world || s.session.branch !== v.branch)
        throw new Error('Session identity does not match the world projection');
      if (this.retired.has(s.runtimeId)) throw new StaleResponse('Retired runtime response');
      let serial = this.serial;
      if (this.runtime !== null && s.runtimeId !== this.runtime) {
        if (!observation || requestRuntime !== this.runtime) throw new StaleResponse('Response started before runtime changed');
        this.retired.add(this.runtime); serial = -1n;
      }
      const next = BigInt(s.responseSerial);
      if (s.runtimeId === this.runtime && next <= serial) throw new StaleResponse('A newer confirmed response has already arrived');
      this.runtime = s.runtimeId; this.serial = next;
      return data;
    }
  }
  class RequestJournal {
    constructor(id) { this.id = id; this.sequence = 0n; this.generation = 0; this.pending = null; this.inFlight = null; this.records = new WeakMap(); }
    prepare(request, session, path) {
      if (this.inFlight) throw new Error('A previous action is still in flight. Wait for its response');
      if (this.pending && this.pending.request !== request) throw new Error('An earlier action has an unknown result. Resolve it before another action');
      let record = this.records.get(request);
      if (record && record.generation !== this.generation) throw new Error("This action belongs to a retired session and cannot be retried");
      if (!record) {
        this.sequence += 1n;
        const body = {...request, requestId: `${this.id}-${this.sequence}`, requestCounter: String(this.sequence), runtimeId: session.runtimeId, sessionEpoch: session.session.epochCounter};
        record = {request, path, body, generation: this.generation, encoded: JSON.stringify(body)}; this.records.set(request, record);
      }
      this.inFlight = record; return record;
    }
    uncertain(record) { if (record.generation !== this.generation) return; this.pending = record; if (this.inFlight === record) this.inFlight = null; }
    resolved(record) { if (record.generation !== this.generation) return; if (this.pending === record) this.pending = null; if (this.inFlight === record) this.inFlight = null; }
    switched() { this.generation += 1; this.pending = null; this.inFlight = null; }
  }
  const api = {decimal, ResponseGate, RequestJournal, StaleResponse};
  if (typeof module !== 'undefined') module.exports = api;
  root.RedDuneProtocol = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
