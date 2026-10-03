import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const supervisor = fileURLToPath(new URL('../native-src/Resources/ios-supervisor.mjs', import.meta.url));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function freePort() {
    const server = net.createServer();
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    return port;
}

async function fixture(t) {
    const parent = process.env.SILLYCLIENT_TEST_TMP || os.tmpdir();
    fs.mkdirSync(parent, { recursive: true });
    const directory = fs.mkdtempSync(path.join(parent, 'ios-supervisor-'));
    const control = path.join(directory, 'control');
    const server = path.join(directory, 'server');
    fs.mkdirSync(control);
    fs.mkdirSync(server);
    fs.writeFileSync(path.join(server, 'server.js'), '');
    fs.writeFileSync(path.join(server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    let output = '';
    const child = spawn(process.execPath, [supervisor], {
        env: { ...process.env, SILLYCLIENT_CONTROL_DIR: control, SILLYCLIENT_STARTUP_TIMEOUT: '1200' },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    t.after(async () => {
        child.kill();
        await delay(100);
        fs.rmSync(directory, { recursive: true, force: true });
    });
    for (let i = 0; i < 200 && !fs.existsSync(path.join(control, 'status.json')); i++) await delay(25);
    assert.ok(fs.existsSync(path.join(control, 'status.json')), output);
    let serial = 0;
    const command = async options => {
        const requestId = options.requestId || `request-${++serial}`;
        fs.writeFileSync(path.join(control, 'requests', `${requestId}.tmp`), JSON.stringify({ ...options, requestId }));
        fs.renameSync(path.join(control, 'requests', `${requestId}.tmp`), path.join(control, 'requests', `${requestId}.json`));
        const response = path.join(control, 'responses', `${requestId}.json`);
        for (let i = 0; i < 400 && !fs.existsSync(response); i++) await delay(25);
        assert.ok(fs.existsSync(response), output);
        return JSON.parse(fs.readFileSync(response));
    };
    return { command, server, control };
}

test('embedded supervisor really starts, stops, and restarts an HTTP worker', async t => {
    const f = await fixture(t);
    const port = await freePort();
    const options = {
        action: 'start', instanceId: 'first', operationId: 'operation-1', port,
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    };
    assert.deepEqual(await f.command(options), { success: true, ready: true });
    assert.equal(await (await fetch(`http://127.0.0.1:${port}/`)).text(), 'actual-worker');
    assert.equal((await f.command({ action: 'stop', instanceId: 'other' })).success, false);
    assert.equal((await f.command({ action: 'stop', operationId: 'old-operation' })).success, false);
    assert.equal((await f.command({ action: 'stop', instanceId: 'first', operationId: 'operation-1' })).success, true);
    await assert.rejects(fetch(`http://127.0.0.1:${port}/`));
    assert.equal((await f.command({ ...options, instanceId: 'second', operationId: 'operation-2' })).ready, true);
    assert.equal((await f.command({ ...options, instanceId: 'third', operationId: 'operation-3' })).success, false);
    assert.equal((await f.command({ action: 'stop' })).success, true);
});

test('a stop consumed before its start cancels the same operation without an orphan worker', async t => {
    const f = await fixture(t);
    const port = await freePort();
    const identity = { instanceId: 'late-start', operationId: 'cancel-before-start' };
    assert.equal((await f.command({ action: 'stop', requestId: 'a-stop', ...identity })).success, true);
    const result = await f.command({
        action: 'start', requestId: 'z-start', ...identity, port,
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.equal(result.success, false);
    assert.match(result.error, /cancelled/);
    await assert.rejects(fetch(`http://127.0.0.1:${port}/`));
});

test('startup failure is reported without leaving a false ready session', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), "throw new Error('synthetic startup failure');");
    const result = await f.command({
        action: 'start', instanceId: 'failure', operationId: 'operation-failure', port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.equal(result.success, false);
    assert.match(result.error, /synthetic startup failure/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.control, 'status.json'))).state, 'failed');
});

test('cancelling startup rejects its original response and allows a new start', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), 'setInterval(() => {}, 1000);');
    const first = f.command({
        action: 'start', instanceId: 'first', operationId: 'cancelled-start', port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    await delay(100);
    assert.equal((await f.command({ action: 'stop', instanceId: 'first', operationId: 'cancelled-start' })).success, true);
    assert.match((await first).error, /cancelled/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.control, 'status.json'))).state, 'stopped');
});

test('startup timeout terminates an unready worker and reports failure', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), 'setInterval(() => {}, 1000);');
    const response = await f.command({
        action: 'start', instanceId: 'timeout', operationId: 'timed-out', port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.equal(response.success, false);
    assert.match(response.error, /timed out/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.control, 'status.json'))).state, 'failed');
});

test('a worker ready message cannot substitute for an actual listening server', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import { parentPort } from 'node:worker_threads';
        parentPort.postMessage({type:'ready'});
        setInterval(() => {}, 1000);
    `);
    const response = await f.command({
        action: 'start', instanceId: 'false-ready', operationId: 'false-ready-operation', port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.equal(response.success, false);
    assert.match(response.error, /HTTP 200/);
});
