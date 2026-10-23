'use strict';
const assert = require('node:assert/strict');
const net = require('node:net');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function exchange(port, parts) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({host: '127.0.0.1', port});
    const received = [];
    let finished = false;
    function finish(error) {
      if (finished) return;
      finished = true;
      if (error && !(error.code === 'ECONNRESET' && received.length)) return reject(error);
      const response = Buffer.concat(received).toString('utf8');
      const [head, body] = response.split('\r\n\r\n');
      try {
        const status = /^HTTP\/1\.1 (\d{3}) /.exec(head);
        assert.ok(status, 'missing HTTP response: ' + response);
        resolve({status: Number(status[1]), body: JSON.parse(body)});
      } catch (failure) { reject(failure); }
    }
    socket.setTimeout(10000, () => socket.destroy(new Error('HTTP framing test timed out')));
    socket.on('data', part => received.push(part));
    socket.on('error', finish);
    socket.on('end', () => finish());
    socket.on('close', () => finish());
    socket.on('connect', async () => {
      try {
        for (const part of parts.slice(0, -1)) {
          socket.write(part);
          await delay(60);
        }
        socket.end(parts.at(-1));
      } catch (error) { socket.destroy(error); }
    });
  });
}

module.exports = async function checkFraming(port, clientId) {
  function request(headerBytes, bodyBytes, declaredBytes = bodyBytes) {
    const prefix = JSON.stringify({clientId, padding: ''});
    assert.ok(bodyBytes >= Buffer.byteLength(prefix));
    const body = Buffer.from(JSON.stringify({clientId, padding: 'a'.repeat(bodyBytes - Buffer.byteLength(prefix))}));
    const start = `POST /api/claim HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Type: application/json\r\nContent-Length: ${declaredBytes}\r\nX-Pad: `;
    const pad = headerBytes - Buffer.byteLength(start) - 4;
    assert.ok(pad >= 0);
    const head = Buffer.from(start + 'x'.repeat(pad) + '\r\n\r\n');
    assert.equal(head.length, headerBytes);
    assert.equal(body.length, bodyBytes);
    return {head, body, bytes: Buffer.concat([head, body])};
  }
  async function accepted(label, packet, cuts) {
    const parts = [];
    let offset = 0;
    for (const cut of cuts) { parts.push(packet.bytes.subarray(offset, cut)); offset = cut; }
    parts.push(packet.bytes.subarray(offset));
    const response = await exchange(port, parts);
    assert.equal(response.status, 200, label + ': ' + JSON.stringify(response));
    assert.equal(response.body.result.status, 'ownershipGranted', label);
  }
  async function rejected(label, bytes, expected) {
    const response = await exchange(port, [bytes]);
    assert.equal(response.status, 400, label);
    assert.equal(response.body.error, expected, label);
  }

  const ordinary = request(7714, 2044);
  await accepted('coalesced header and body', ordinary, []);
  await accepted('same bytes after a short first TCP write', ordinary, [1024]);
  await accepted('delimiter split across writes', ordinary, [ordinary.head.length - 3, ordinary.head.length - 1]);
  const exactHeader = request(8192, 2044);
  await accepted('8 KiB header inclusive of delimiter', exactHeader, []);
  await accepted('8 KiB header fragmented with coalesced body', exactHeader, [1024]);
  await rejected('header one byte over budget', request(8193, 2044).bytes, 'Headers exceed 8 KiB');
  await accepted('64 KiB body at its exact bound', request(300, 65536), [299]);
  await rejected('body one byte over budget', request(300, 65537).bytes, 'Body outside bounds');
  const small = request(300, 128);
  await rejected('coalesced excess body byte', Buffer.concat([small.bytes, Buffer.from('x')]), 'Trailing/pipelined request bytes are unsupported');
  await rejected('coalesced pipelined request', Buffer.concat([small.bytes, Buffer.from('GET /api/state HTTP/1.1\r\n\r\n')]), 'Trailing/pipelined request bytes are unsupported');
  await rejected('half-closed incomplete body', request(300, 128, 129).bytes, 'Incomplete body');
  await rejected('half-closed incomplete header', Buffer.from('POST /api/claim HTTP/1.1\r\n'), 'Incomplete request');
  console.log('PASS: actual HTTP sockets preserve identical-byte acceptance across fragmentation; exact header/body budgets, split delimiter, truncation and coalesced excess/pipeline rejection');
};
