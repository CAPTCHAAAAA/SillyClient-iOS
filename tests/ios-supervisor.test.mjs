import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import net from 'node:net';

const supervisor = fileURLToPath(new URL('../native-src/Resources/ios-supervisor.mjs', import.meta.url));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const logPrefix = '[SILLYCLIENT_LOG_V1]';

async function waitForLogs(fixture, predicate) {
    for (let i = 0; i < 200; i++) {
        if (predicate(fixture.logs())) return;
        await delay(10);
    }
    assert.fail(`Expected worker log frames were not received: ${fixture.output().slice(-4096)}`);
}

async function freePort() {
    const server = net.createServer();
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    return port;
}

async function fixture(t, { asynchronousOutput = false } = {}) {
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
    let stdout = '';
    const arguments_ = asynchronousOutput ? ['--input-type=module', '--eval', `
        import fs from 'node:fs';
        import { Writable } from 'node:stream';
        Object.defineProperty(process, 'stdout', { value: new Writable({
            write(chunk, encoding, callback) {
                setImmediate(() => {
                    try { fs.writeSync(1, chunk); callback(); }
                    catch (error) { callback(error); }
                });
            },
        }) });
        process.execArgv = [];
        await import(${JSON.stringify(pathToFileURL(supervisor).href)});
    `] : [supervisor];
    const child = spawn(process.execPath, arguments_, {
        env: { ...process.env, SILLYCLIENT_CONTROL_DIR: control, SILLYCLIENT_STARTUP_TIMEOUT: '1200' },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', data => { stdout += data; output += data; });
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
    const logs = () => stdout.split('\n').slice(0, -1).filter(line => line.startsWith(logPrefix)).map(line => {
        const frame = JSON.parse(line.slice(logPrefix.length));
        return { ...frame, line: Buffer.from(frame.lineBase64, 'base64').toString('utf8') };
    });
    return { command, server, control, logs, output: () => output };
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

test('terminated worker partial output never joins the restarted session or loses its origin', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        if (process.env.SILLYCLIENT_OPERATION_ID === 'operation-a') process.stdout.write('old-worker-tail');
        else process.stdout.write('new-worker-line\\n');
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    const port = await freePort();
    const options = { action: 'start', port, serverDirectory: f.server, dataDirectory: path.join(f.server, 'data') };
    assert.equal((await f.command({ ...options, instanceId: 'worker-a', operationId: 'operation-a' })).ready, true);
    assert.equal((await f.command({ action: 'stop', instanceId: 'worker-a', operationId: 'operation-a' })).success, true);
    assert.equal((await f.command({ ...options, instanceId: 'worker-b', operationId: 'operation-b' })).ready, true);
    await waitForLogs(f, logs => logs.some(frame => frame.instanceId === 'worker-a')
        && logs.some(frame => frame.instanceId === 'worker-b'));
    assert.deepEqual(f.logs().map(({ instanceId, operationId, stream, line }) => ({
        instanceId, operationId, stream, line,
    })).sort((left, right) => left.instanceId.localeCompare(right.instanceId)), [
        { instanceId: 'worker-a', operationId: 'operation-a', stream: 'stdout', line: 'old-worker-tail' },
        { instanceId: 'worker-b', operationId: 'operation-b', stream: 'stdout', line: 'new-worker-line' },
    ]);
    assert.equal((await f.command({ action: 'stop', instanceId: 'worker-b', operationId: 'operation-b' })).success, true);
});

test('worker log framing preserves UTF8 chunk boundaries and separates stdout from stderr tails', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        const bytes = Buffer.from('split \\u4e2d\\u6587 \\u{1f642}');
        process.stdout.write(bytes.subarray(0, 7));
        await new Promise(resolve => setTimeout(resolve, 25));
        process.stdout.write(bytes.subarray(7));
        process.stdout.write('\\r\\n');
        process.stderr.write('independent-stderr-tail');
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    const identity = { instanceId: 'utf8-worker', operationId: 'utf8-operation' };
    assert.equal((await f.command({
        action: 'start', ...identity, port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    })).ready, true);
    assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
    await waitForLogs(f, logs => logs.length === 2);
    const frames = f.logs();
    assert.ok(frames.every(frame => frame.instanceId === identity.instanceId && frame.operationId === identity.operationId));
    assert.equal(frames.find(frame => frame.stream === 'stdout').line, 'split \u4e2d\u6587 \u{1f642}');
    assert.equal(frames.find(frame => frame.stream === 'stderr').line, 'independent-stderr-tail');
});

test('oversized worker lines are discarded once and cannot hide the next valid line', async t => {
    const f = await fixture(t);
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        process.stdout.write('a'.repeat(16384) + '\\n');
        process.stdout.write('x'.repeat(16384));
        await new Promise(resolve => setTimeout(resolve, 25));
        process.stdout.write('x'.repeat(32768) + '\\nrecovered-line\\n');
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    const identity = { instanceId: 'bounded-worker', operationId: 'bounded-operation' };
    assert.equal((await f.command({
        action: 'start', ...identity, port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    })).ready, true);
    await waitForLogs(f, logs => logs.some(frame => frame.line === 'recovered-line'));
    const frames = f.logs();
    assert.deepEqual(frames.map(frame => frame.line), [
        'a'.repeat(16384), '[Oversized worker log line discarded]', 'recovered-line',
    ]);
    assert.ok(frames.every(frame => Buffer.byteLength(frame.line) <= 16384));
    assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
});

test('frame-looking worker text cannot forge another session identity', async t => {
    const f = await fixture(t);
    const forged = logPrefix + JSON.stringify({
        instanceId: 'other-worker', operationId: 'other-operation', stream: 'stderr',
        lineBase64: Buffer.from('forged-message').toString('base64'),
    });
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        process.stdout.write(${JSON.stringify(forged + '\n')});
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    const identity = { instanceId: 'real-worker', operationId: 'real-operation' };
    assert.equal((await f.command({
        action: 'start', ...identity, port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    })).ready, true);
    await waitForLogs(f, logs => logs.length > 0);
    assert.equal(f.logs().length, 1);
    assert.equal(f.logs()[0].instanceId, identity.instanceId);
    assert.equal(f.logs()[0].operationId, identity.operationId);
    assert.equal(f.logs()[0].line, forged);
    assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
});

test('log producer identities reject trailing line controls rather than matching a safe prefix', async t => {
    const f = await fixture(t);
    for (const ending of ['\n', '\r', '\u2028', '\u2029']) {
        for (const field of ['instanceId', 'operationId']) {
            const result = await f.command({
                action: 'start', instanceId: 'valid-worker', operationId: 'valid-operation',
                [field]: `invalid${ending}`, port: await freePort(),
                serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
            });
            assert.equal(result.success, false);
            assert.match(result.error, /Invalid operation identity/);
        }
    }
    assert.deepEqual(f.logs(), []);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.control, 'status.json'))).state, 'idle');
});

test('worker log floods have a bounded host backlog and recover after the discarded burst', async t => {
    const f = await fixture(t, { asynchronousOutput: true });
    fs.writeFileSync(path.join(f.server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        process.stdout.write('storm-line\\n'.repeat(100000));
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write('after-storm\\n');
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    const identity = { instanceId: 'storm-worker', operationId: 'storm-operation' };
    const started = await f.command({
        action: 'start', ...identity, port: await freePort(),
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.deepEqual(started, { success: true, ready: true });
    await waitForLogs(f, logs => logs.some(frame => frame.line === 'after-storm'));
    const frames = f.logs();
    assert.ok(frames.some(frame => frame.line === '[Runtime log backlog reached; further lines discarded]'));
    assert.ok(frames.length < 100000, 'The complete storm was buffered instead of being bounded');
    assert.ok(frames.every(frame => frame.instanceId === identity.instanceId && frame.operationId === identity.operationId));
    assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
});

test('native frame contract keeps queued output identities explicit and validates byte limits', () => {
    const source = fs.readFileSync(new URL('../native-src/NodeRunner.swift', import.meta.url), 'utf8');
    assert.ok(source.includes(`static let prefix = "${logPrefix}"`));
    assert.match(source, /static let maximumFrameBytes = 24 \* 1024/);
    assert.match(source, /static let maximumLineBytes = 16 \* 1024/);
    assert.match(source, /raw\.count <= maximumFrameBytes/);
    assert.match(source, /Data\(base64Encoded: encoded\)/);
    assert.match(source, /bytes\.count <= maximumLineBytes/);
    assert.match(source, /String\(data: bytes, encoding: \.utf8\)/);
    assert.match(source, /appendLog\(frame\.line, instance: frame\.instanceId, operation: frame\.operationId\)/);
    const append = source.slice(source.indexOf('public func appendLog'), source.indexOf('public func getLogs'));
    assert.match(append, /instance id: String = "runtime", operation op: String = ""/);
    assert.doesNotMatch(append, /self\.(?:instanceId|operationId)/);
    assert.match(append, /pendingLogCount < 256, pendingLogBytes \+ size <= 512 \* 1024/);
    assert.match(append, /defer \{[\s\S]*pendingLogCount -= 1[\s\S]*pendingLogBytes -= size/);
});
