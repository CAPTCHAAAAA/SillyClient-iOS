import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import net from 'node:net';
import vm from 'node:vm';

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

function prepareActualLoader(server, contents) {
    fs.mkdirSync(path.join(server, 'src'), { recursive: true });
    fs.writeFileSync(path.join(server, 'package.json'), JSON.stringify({ type: 'module' }));
    fs.copyFileSync(new URL('../native-src/ios-loader.mjs', import.meta.url), path.join(server, 'ios-loader.mjs'));
    fs.writeFileSync(path.join(server, 'src', 'server-events.js'), `
        import { EventEmitter } from 'node:events';
        export const serverEvents = new EventEmitter();
        export const EVENT_NAMES = { SERVER_STARTED: 'ready' };
    `);
    fs.writeFileSync(path.join(server, 'relative-state.txt'), contents);
    fs.writeFileSync(path.join(server, 'server.js'), `
        import assert from 'node:assert/strict';
        import fs from 'node:fs';
        import path from 'node:path';
        import http from 'node:http';
        import { fileURLToPath } from 'node:url';
        import { serverEvents, EVENT_NAMES } from './src/server-events.js';
        const directory = fs.realpathSync(path.dirname(fileURLToPath(import.meta.url)));
        process.chdir(directory);
        process.chdir('.');
        process.chdir(path.join(directory, '..', path.basename(directory)));
        assert.equal(fs.realpathSync(process.cwd()), directory);
        assert.throws(() => process.chdir(path.dirname(directory)), { code: 'ERR_IOS_WORKER_CWD_CHANGE' });
        assert.throws(() => process.chdir(undefined), { code: 'ERR_INVALID_ARG_TYPE' });
        const read = () => fs.readFileSync('relative-state.txt', 'utf8');
        assert.equal(read(), ${JSON.stringify(contents)});
        const server = http.createServer((request, response) => response.end(read()));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => {
            serverEvents.emit(EVENT_NAMES.SERVER_STARTED, { url: 'http://127.0.0.1:' + process.env.PORT + '/' });
        });
    `);
}

async function fixture(t, { asynchronousOutput = false, actualLoader = false, authorization = false } = {}) {
    const parent = process.env.SILLYCLIENT_TEST_TMP || os.tmpdir();
    fs.mkdirSync(parent, { recursive: true });
    const directory = fs.mkdtempSync(path.join(parent, 'ios-supervisor-'));
    const control = path.join(directory, 'control');
    const server = path.join(directory, 'server');
    fs.mkdirSync(control);
    fs.mkdirSync(server);
    fs.writeFileSync(path.join(server, 'server.js'), '');
    fs.mkdirSync(path.join(server, 'data'));
    fs.writeFileSync(path.join(server, 'config.yaml'), 'listen: false\n');
    fs.writeFileSync(path.join(server, 'ios-loader.mjs'), `
        import http from 'node:http';
        import { parentPort } from 'node:worker_threads';
        const server = http.createServer((request, response) => response.end('actual-worker'));
        server.listen(Number(process.env.PORT), '127.0.0.1', () => parentPort.postMessage({type:'ready'}));
    `);
    if (actualLoader) prepareActualLoader(server, 'first-instance-data');
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
        env: { ...process.env, SILLYCLIENT_CONTROL_DIR: control, SILLYCLIENT_STARTUP_TIMEOUT: '1200',
            ...(authorization ? { SILLYCLIENT_INSTANCES_ROOT: path.join(directory, 'default-storage') } : {}) },
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
    const authorize = options => {
        const root = path.dirname(options.serverDirectory);
        const rootStat = fs.lstatSync(root, { bigint: true });
        const serverStat = fs.lstatSync(options.serverDirectory, { bigint: true });
        const mapping = { revision: 1, instanceId: options.instanceId, operationId: options.operationId,
            root: fs.realpathSync(root), rootDevice: String(BigInt.asUintN(32, rootStat.dev)), rootInode: String(rootStat.ino),
            serverDirectory: fs.realpathSync(options.serverDirectory),
            serverDevice: String(BigInt.asUintN(32, serverStat.dev)), serverInode: String(serverStat.ino),
            dataDirectory: options.dataDirectory, configPath: options.configPath };
        fs.writeFileSync(path.join(control, 'locations.json'), JSON.stringify(mapping));
        return mapping;
    };
    return { command, authorize, server, control, logs, output: () => output };
}

test('native runtime authorization permits selected storage instead of substituting the default root', async t => {
    const f = await fixture(t, { authorization: true });
    const port = await freePort();
    const options = { action: 'start', instanceId: 'custom-root', operationId: 'custom-operation', port,
        serverDirectory: fs.realpathSync(f.server), dataDirectory: path.join(fs.realpathSync(f.server), 'data'),
        configPath: path.join(fs.realpathSync(f.server), 'config.yaml') };
    const denied = await f.command(options);
    assert.equal(denied.success, false);
    assert.match(denied.error, /authorization is unavailable/);
    f.authorize(options);
    assert.deepEqual(await f.command(options), { success: true, ready: true }, f.output());
    assert.equal(await (await fetch(`http://127.0.0.1:${port}/`)).text(), 'actual-worker');
    assert.equal((await f.command({ action: 'stop', instanceId: options.instanceId, operationId: options.operationId })).success, true);
    const next = { ...options, operationId: 'custom-operation-restarted' };
    const stale = await f.command(next);
    assert.equal(stale.success, false);
    assert.match(stale.error, /another operation/);
    f.authorize(next);
    assert.equal((await f.command(next)).ready, true);
    assert.equal((await f.command({ action: 'stop', instanceId: next.instanceId, operationId: next.operationId })).success, true);
});

test('runtime authorization rejects forged paths, replaced directory identities, and unsafe metadata', async t => {
    const f = await fixture(t, { authorization: true });
    const options = { action: 'start', instanceId: 'guarded-root', operationId: 'guarded-operation', port: await freePort(),
        serverDirectory: fs.realpathSync(f.server), dataDirectory: path.join(fs.realpathSync(f.server), 'data'),
        configPath: path.join(fs.realpathSync(f.server), 'config.yaml') };
    const mapping = f.authorize(options);
    for (const altered of [
        { ...options, dataDirectory: path.dirname(options.serverDirectory) },
        { ...options, configPath: path.join(path.dirname(options.serverDirectory), 'other.yaml') },
        { ...options, serverDirectory: path.dirname(options.serverDirectory), root: path.dirname(options.serverDirectory) },
    ]) {
        const result = await f.command(altered);
        assert.equal(result.success, false);
        assert.match(result.error, /differs from its native authorization/);
    }
    for (const field of ['rootInode', 'serverInode']) {
        fs.writeFileSync(path.join(f.control, 'locations.json'), JSON.stringify({ ...mapping, [field]: '0' }));
        const result = await f.command(options);
        assert.equal(result.success, false);
        assert.match(result.error, /directory was replaced/);
    }
    for (const badRoot of ['relative/root', path.join(path.dirname(options.serverDirectory), 'nonexistent-root')]) {
        fs.writeFileSync(path.join(f.control, 'locations.json'), JSON.stringify({ ...mapping, root: badRoot }));
        const result = await f.command(options);
        assert.equal(result.success, false);
        assert.match(result.error, /Unsafe authorized runtime root/);
    }
    fs.writeFileSync(path.join(f.control, 'locations.json'), 'x'.repeat(65537));
    const oversized = await f.command(options);
    assert.equal(oversized.success, false);
    assert.match(oversized.error, /authorization is invalid/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.control, 'status.json'))).state, 'idle');
    await assert.rejects(fetch(`http://127.0.0.1:${options.port}/`));
});

test('runtime authorization accepts Darwin /private canonical path equivalence and rejects symlink traversal', async t => {
    const f = await fixture(t, { authorization: true });
    const port = await freePort();
    const options = { action: 'start', instanceId: 'darwin-root', operationId: 'darwin-operation', port,
        serverDirectory: fs.realpathSync(f.server), dataDirectory: path.join(fs.realpathSync(f.server), 'data'),
        configPath: path.join(fs.realpathSync(f.server), 'config.yaml') };
    const mapping = f.authorize(options);

    if (mapping.root.startsWith('/private/')) {
        const strippedRoot = mapping.root.slice('/private'.length);
        const strippedServer = mapping.serverDirectory.slice('/private'.length);
        const strippedOptions = {
            ...options,
            serverDirectory: strippedServer,
            dataDirectory: path.join(strippedServer, 'data'),
            configPath: path.join(strippedServer, 'config.yaml'),
        };
        fs.writeFileSync(path.join(f.control, 'locations.json'), JSON.stringify({
            ...mapping,
            root: strippedRoot,
            serverDirectory: strippedServer,
            dataDirectory: strippedOptions.dataDirectory,
            configPath: strippedOptions.configPath,
        }));
        const ok = await f.command(strippedOptions);
        assert.equal(ok.success, true);
        assert.equal(ok.ready, true);
        assert.equal((await f.command({ action: 'stop', instanceId: options.instanceId, operationId: options.operationId })).success, true);
    }

    const symlinkEscape = path.join(path.dirname(options.serverDirectory), 'symlink-escape');
    try {
        fs.symlinkSync(path.dirname(options.serverDirectory), symlinkEscape, 'junction');
        const rootStat = fs.lstatSync(mapping.root, { bigint: true });
        fs.writeFileSync(path.join(f.control, 'locations.json'), JSON.stringify({
            ...mapping,
            root: symlinkEscape,
            rootDevice: String(BigInt.asUintN(32, rootStat.dev)),
            rootInode: String(rootStat.ino),
        }));
        const result = await f.command(options);
        assert.equal(result.success, false);
        assert.match(result.error, /(?:Unsafe authorized runtime root|Authorized runtime directory was replaced)/);
    } catch (e) {
        if (e.code !== 'EPERM') throw e;
    } finally {
        try { fs.unlinkSync(symlinkEscape); } catch {}
    }
});

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

test('production loader accepts upstream same-directory Worker chdir and rejects actual changes', async t => {
    const f = await fixture(t, { actualLoader: true });
    const port = await freePort();
    const identity = { instanceId: 'actual-loader', operationId: 'actual-loader-operation' };
    const started = await f.command({
        action: 'start', ...identity, port,
        serverDirectory: f.server, dataDirectory: path.join(f.server, 'data'),
    });
    assert.deepEqual(started, { success: true, ready: true }, f.output());
    assert.equal(await (await fetch(`http://127.0.0.1:${port}/`)).text(), 'first-instance-data');
    assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
    await assert.rejects(fetch(`http://127.0.0.1:${port}/`));
});

test('production loader restart uses the next instance directory after the old Worker terminates', async t => {
    const f = await fixture(t, { actualLoader: true });
    const next = path.join(path.dirname(f.server), 'second-server');
    prepareActualLoader(next, 'second-instance-data');
    const port = await freePort();
    const first = { instanceId: 'first-loader', operationId: 'first-loader-operation' };
    const second = { instanceId: 'second-loader', operationId: 'second-loader-operation' };
    for (const [identity, server, contents] of [
        [first, f.server, 'first-instance-data'], [second, next, 'second-instance-data'],
    ]) {
        assert.deepEqual(await f.command({
            action: 'start', ...identity, port, serverDirectory: server, dataDirectory: path.join(server, 'data'),
        }), { success: true, ready: true }, f.output());
        assert.equal(await (await fetch(`http://127.0.0.1:${port}/`)).text(), contents);
        assert.equal((await f.command({ action: 'stop', ...identity })).success, true);
        await assert.rejects(fetch(`http://127.0.0.1:${port}/`));
    }
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
    assert.match(source, /append\(frame\.line, frame\.instanceId, frame\.operationId, true\)/);
    const append = source.slice(source.indexOf('public func appendLog'), source.indexOf('public func getLogs'));
    assert.match(append, /instance id: String = "runtime", operation op: String = ""/);
    assert.doesNotMatch(append, /self\.(?:instanceId|operationId)/);
    assert.match(append, /pendingLogCount < 256, pendingLogBytes \+ size <= 512 \* 1024/);
    assert.match(append, /defer \{[\s\S]*pendingLogCount -= 1[\s\S]*pendingLogBytes -= size/);
});

test('native captured-output routing stores host diagnostics without relaying JavaScript events', () => {
    const source = fs.readFileSync(new URL('../native-src/NodeRunner.swift', import.meta.url), 'utf8');
    const consume = source.slice(source.indexOf('private func consumeOutputLine'), source.indexOf('static func routeCapturedOutput'));
    assert.match(consume, /Self\.routeCapturedOutput\(raw\)/);
    assert.match(consume, /appendLog\(line, instance: instance, operation: operation, publishEvent: publishEvent\)/);
    const route = source.slice(source.indexOf('static func routeCapturedOutput'), source.indexOf('public func appendLog'));
    assert.match(route, /raw\.count <= 65536/);
    assert.match(route, /append\(frame\.line, frame\.instanceId, frame\.operationId, true\)/);
    assert.match(route, /append\(String\(decoding: raw, as: UTF8\.self\), "runtime", "", false\)/);
    assert.match(route, /append\("\[Malformed runtime log frame discarded\]", "runtime", "", false\)/);
    assert.match(route, /append\("\[Oversized runtime log line discarded\]", "runtime", "", false\)/);
    assert.doesNotMatch(route, /self\.(?:instanceId|operationId)|logEvent/);
    const append = source.slice(source.indexOf('public func appendLog'), source.indexOf('public func getLogs'));
    assert.match(append, /appendLog\(raw, instance: id, operation: op, publishEvent: true\)/);
    assert.match(append, /if publishEvent \{ self\.logEvent\?\(id, op, line\) \}/);
    const redirect = source.slice(source.indexOf('private func redirectOutput'), source.indexOf('private func consumeOutputLine'));
    assert.match(redirect, /appendLog\("\[Oversized runtime log line discarded\]", publishEvent: false\)/);
});

async function invokeDebugBridge(method, options, plugin) {
    const source = fs.readFileSync(new URL('../native-src/IOSDebugHarness.swift', import.meta.url), 'utf8');
    const script = source.match(/static let bridgeInvocationScript = """\n([\s\S]*?)\n\s*"""/)?.[1];
    assert.ok(script, 'Missing the real Debug bridge invocation script');
    const body = script.replace(/\\\\/g, '\\');
    const response = await vm.runInNewContext(`(async () => {\n${body}\n})()`, {
        window: { Capacitor: { Plugins: { TarvenEnv: plugin } } }, method, options,
        console: { log() { assert.fail('Bridge diagnostics were printed to captured stdout'); } },
    }, { timeout: 1000 });
    return JSON.parse(JSON.stringify(response));
}

test('Debug bridge envelopes preserve successful native results and the actual invocation', async () => {
    const options = { instanceId: 'debug-fixture' };
    let calls = 0;
    const response = await invokeDebugBridge('getInstanceInfo', options, {
        async getInstanceInfo(actual) {
            calls += 1;
            assert.equal(actual, options);
            return { instanceId: actual.instanceId, version: '1.19.0' };
        },
    });
    assert.equal(calls, 1);
    assert.deepEqual(response, { success: true, result: { instanceId: 'debug-fixture', version: '1.19.0' } });
});

test('Debug bridge rejection preserves the native message and safe error code', async () => {
    const response = await invokeDebugBridge('provisionAndStart', {}, {
        async provisionAndStart() {
            throw Object.assign(new Error('Stop the current operation before starting an instance'),
                { code: 'ERR_SESSION_BUSY' });
        },
    });
    assert.equal(response.success, false);
    assert.match(response.error, /provisionAndStart.*ERR_SESSION_BUSY.*Stop the current operation/);
    assert.doesNotMatch(response.error, /A JavaScript exception occurred/);
    const secretCode = 'fixture-native-code-secret';
    const redactedCode = await invokeDebugBridge('getStatus', { password: secretCode }, {
        async getStatus() { throw Object.assign(new Error('Native method failed'), { code: secretCode }); },
    });
    assert.equal(redactedCode.success, false);
    assert.doesNotMatch(redactedCode.error, /fixture-native-code-secret/);
    for (const code of ['ERR_NEWLINE\n', 'overlong-code-'.repeat(10000)]) {
        const invalidCode = await invokeDebugBridge('getStatus', {}, {
            async getStatus() { throw Object.assign(new Error('Native method failed'), { code }); },
        });
        assert.equal(invalidCode.error, 'getStatus: Native method failed');
    }
});

test('Debug bridge reports unavailable native methods without a WebKit promise rejection', async () => {
    const response = await invokeDebugBridge('getPlatform', {}, {});
    assert.equal(response.success, false);
    assert.match(response.error, /getPlatform.*Native bridge method is unavailable/);
});

test('Debug bridge diagnostics redact option secrets, authenticated URLs, and authorization text', async () => {
    const options = { password: 'fixture-password', nested: { apiKey: 'fixture-api-key' } };
    const response = await invokeDebugBridge('enterImmersive', options, {
        async enterImmersive() {
            throw new Error('Denied fixture-password fixture-api-key at https://user:uri-secret@example.test/a'
                + '?token=query-secret&visible=1; Authorization: Bearer header-secret; password=unbound-secret');
        },
    });
    assert.equal(response.success, false);
    assert.match(response.error, /enterImmersive.*Denied/);
    assert.match(response.error, /\[redacted\]/);
    assert.doesNotMatch(response.error, /fixture-password|fixture-api-key|uri-secret|query-secret|header-secret|unbound-secret/);
    const repeatedSecret = 'synthetic-secret-' + 'x'.repeat(984);
    const longUrl = 'https://fixture-user:' + 'synthetic-long-secret-'.repeat(240) + '@example.test';
    const token = 'synthetic-token-'.repeat(110);
    const cases = [
        { options: { password: repeatedSecret }, message: Array(6).fill(repeatedSecret).join(' '), fragment: 'synthetic-secret-' },
        { options: { url: longUrl }, message: 'URL failure at ' + longUrl, fragment: 'synthetic-long-secret-' },
        { options: { password: 'a'.repeat(2000), token }, message: 'a'.repeat(2000) + ' filler '.repeat(130) + token, fragment: 'synthetic-token-' },
        { options: { password: 'q', nested: { apiKey: repeatedSecret } }, message: 'q'.repeat(150) + ' ' + Array(3).fill(repeatedSecret).join(' '), fragment: 'synthetic-secret-' },
    ];
    for (const fixture of cases) {
        const bounded = await invokeDebugBridge('getStatus', fixture.options, {
            async getStatus() { throw new Error(fixture.message); },
        });
        assert.equal(bounded.success, false);
        assert.ok(bounded.error.length <= 2048);
        assert.match(bounded.error, /^getStatus:/);
        assert.equal(bounded.error.includes(fixture.fragment), false, 'A truncated secret reached the diagnostic');
    }
});

test('Debug bridge rejection text is bounded and never serializes unknown error objects', async () => {
    const response = await invokeDebugBridge('getStatus', {}, {
        async getStatus() { throw new Error('x'.repeat(100000)); },
    });
    assert.equal(response.success, false);
    assert.ok(response.error.length <= 2048);
    assert.match(response.error, /^getStatus:/);
    const unknown = await invokeDebugBridge('getStatus', {}, {
        async getStatus() { throw { stack: 'private-stack', options: { password: 'private-secret' } }; },
    });
    assert.equal(unknown.success, false);
    assert.match(unknown.error, /rejected without a diagnostic/);
    assert.doesNotMatch(unknown.error, /private-stack|private-secret|password|options/);
});

test('Debug bridge Swift responses preserve diagnostic envelopes and numeric WebKit failures', () => {
    const source = fs.readFileSync(new URL('../native-src/IOSDebugHarness.swift', import.meta.url), 'utf8');
    assert.match(source, /callAsyncJavaScript\(Self\.bridgeInvocationScript, arguments:/);
    assert.match(source, /case \.success\(let value\):[\s\S]*value as\? \[String: Any\][\s\S]*respond\(id, response\)/);
    assert.match(source, /case \.failure\(let error\):[\s\S]*Self\.webKitFailureDescription\(error\)/);
    const fallback = source.match(/static func webKitFailureDescription[\s\S]*?(?=\n    public init)/)?.[0];
    assert.ok(fallback);
    assert.match(fallback, /error as NSError/);
    assert.match(fallback, /native\.domain\.prefix\(80\)/);
    assert.match(fallback, /native\.code/);
    assert.doesNotMatch(fallback, /localizedDescription|userInfo|stack|request\[/);
});
