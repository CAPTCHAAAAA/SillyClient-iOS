import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath, pathToFileURL } from 'node:url';

const directory = process.env.SILLYCLIENT_IOS_SERVER;
const supervisor = fileURLToPath(new URL('../native-src/Resources/ios-supervisor.mjs', import.meta.url));
const logPrefix = '[SILLYCLIENT_LOG_V1]';
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function freePort() {
    const listener = net.createServer();
    listener.listen(0, '127.0.0.1');
    await once(listener, 'listening');
    const port = listener.address().port;
    await new Promise(resolve => listener.close(resolve));
    return port;
}

function prepareFixture(t, server, prefix) {
    const parent = process.env.SILLYCLIENT_TEST_TMP || os.tmpdir();
    fs.mkdirSync(parent, { recursive: true });
    const temporary = fs.realpathSync(fs.mkdtempSync(path.join(parent, prefix)));
    assert.equal(path.dirname(temporary), fs.realpathSync(parent));
    t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));

    const require = createRequire(path.join(server, 'package.json'));
    const yaml = require('yaml');
    const config = yaml.parse(fs.readFileSync(path.join(server, 'default', 'config.yaml'), 'utf8'));
    config.dataRoot = path.join(temporary, 'data');
    config.listen = false;
    config.protocol = { ...config.protocol, ipv4: true, ipv6: false };
    config.browserLaunch.enabled = false;
    config.extensions.autoUpdate = false;
    config.extensions.models.autoDownload = false;
    const configPath = path.join(temporary, 'config.yaml');
    fs.writeFileSync(configPath, yaml.stringify(config));
    const workerFetchVerified = path.join(temporary, 'worker-fetch-verified.txt');
    const guard = path.join(temporary, 'guard.cjs');
    fs.writeFileSync(guard, `
        const assert = require('node:assert/strict');
        const { isMainThread } = require('node:worker_threads');
        assert.equal(typeof WebAssembly, 'undefined');
        const Module = require('node:module');
        const load = Module._load;
        Module._load = function(request, ...args) {
            if (request === 'webpack' || /(?:^|[/\\\\])webpack[/\\\\]/.test(request)) {
                throw new Error('Runtime must not import webpack: ' + request);
            }
            return load.call(this, request, ...args);
        };
        console.log('[test] WASM disabled; webpack imports blocked. ' + (isMainThread ? 'host' : 'worker'));
        if (!isMainThread) {
            import(${JSON.stringify(pathToFileURL(path.join(server, 'src', 'server-events.js')).href)}).then(({ serverEvents, EVENT_NAMES }) => {
                serverEvents.once(EVENT_NAMES.SERVER_STARTED, async ({ url }) => {
                    const response = await fetch(new Request(url));
                    assert.equal(response.status, 200);
                    assert.ok(response instanceof Response);
                    assert.ok(response.headers instanceof Headers);
                    assert.match(await response.text(), /SillyTavern/);
                    require('node:fs').writeFileSync(${JSON.stringify(workerFetchVerified)}, process.env.SILLYCLIENT_OPERATION_ID);
                    console.log('[test] Worker global fetch and response parsing succeeded without WASM.');
                });
            });
        }
    `);
    return { temporary, dataDirectory: config.dataRoot, configPath, guard, workerFetchVerified };
}

function captureRuntime(child) {
    let log = '';
    let stdout = '';
    let closed = false;
    let failure;
    child.stdout.on('data', data => {
        stdout = (stdout + data).slice(-4 * 1024 * 1024);
        log = (log + data).slice(-4 * 1024 * 1024);
    });
    child.stderr.on('data', data => { log = (log + data).slice(-4 * 1024 * 1024); });
    child.on('error', error => { failure = error; });
    const exit = new Promise(resolve => child.once('close', () => { closed = true; resolve(); }));
    return {
        log: () => log,
        workerLog(operationId) {
            return stdout.split('\n').slice(0, -1).filter(line => line.startsWith(logPrefix)).map(line => {
                const frame = JSON.parse(line.slice(logPrefix.length));
                return !operationId || frame.operationId === operationId
                    ? Buffer.from(frame.lineBase64, 'base64').toString('utf8') : '';
            }).filter(Boolean).join('\n');
        },
        assertRunning(details = log) {
            assert.equal(failure, undefined, details);
            assert.equal(closed, false, details);
            assert.equal(child.exitCode, null, details);
        },
        async stop() {
            if (!closed) child.kill('SIGKILL');
            await exit;
        },
    };
}

function clearMarkers(server, dataDirectory) {
    for (const file of [
        path.join(path.dirname(server), 'server-ready.txt'),
        path.join(path.dirname(server), 'server-failed.json'),
        path.join(server, 'data', 'server-ready.txt'),
        path.join(dataDirectory, 'server-ready.txt'),
    ]) fs.rmSync(file, { force: true });
}

async function verifyAssets(server, base) {
    const response = await fetch(base, { signal: AbortSignal.timeout(5000) });
    assert.equal(response.status, 200);
    assert.match(await response.text(), /SillyTavern/);
    const manifest = JSON.parse(fs.readFileSync(path.join(server, 'dist', 'ios-frontend', 'manifest.json'), 'utf8'));
    assert.ok(Array.isArray(manifest.assets) && manifest.assets.length > 0, 'The prepared frontend manifest must contain assets.');
    assert.ok(manifest.assets.some(asset => asset.name === 'lib.js'), 'The prepared frontend manifest must contain lib.js.');
    for (const asset of manifest.assets) {
        const url = `${base}/${asset.name}`;
        const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
        assert.equal(response.status, 200, asset.name);
        const bytes = Buffer.from(await response.arrayBuffer());
        assert.equal(bytes.length, asset.bytes, asset.name);
        assert.equal(createHash('sha256').update(bytes).digest('hex'), asset.sha256, asset.name);
        if (asset.name.endsWith('.js')) {
            assert.match(response.headers.get('content-type'), /javascript/);
        }
        const head = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(5000) });
        assert.equal(head.status, 200, asset.name);
        assert.equal((await head.arrayBuffer()).byteLength, 0);
    }
    return manifest.assets.length;
}

test('the prepared server starts without WASM and serves verified frontend assets', {
    skip: directory ? false : 'Set SILLYCLIENT_IOS_SERVER to a disposable, prepared SillyTavern copy.',
    timeout: 60000,
}, async t => {
    const server = fs.realpathSync(directory);
    const { temporary, dataDirectory, configPath, guard } = prepareFixture(t, server, 'ios-server-');
    const port = await freePort();
    const fetchVerified = path.join(temporary, 'fetch-verified.txt');
    const entry = path.join(temporary, 'entry.mjs');
    fs.writeFileSync(entry, `
        import assert from 'node:assert/strict';
        import fs from 'node:fs';
        import { serverEvents, EVENT_NAMES } from ${JSON.stringify(pathToFileURL(path.join(server, 'src', 'server-events.js')).href)};
        serverEvents.once(EVENT_NAMES.SERVER_STARTED, async ({ url }) => {
            const response = await fetch(new Request(url));
            assert.equal(response.status, 200);
            assert.ok(response instanceof Response);
            assert.ok(response.headers instanceof Headers);
            assert.match(await response.text(), /SillyTavern/);
            fs.writeFileSync(${JSON.stringify(fetchVerified)}, 'verified');
            console.log('[test] Global fetch and response parsing succeeded without WASM.');
        });
        await import(${JSON.stringify(pathToFileURL(path.join(server, 'ios-loader.mjs')).href)});
    `);

    const readyFile = path.join(path.dirname(server), 'server-ready.txt');
    const failureFile = path.join(path.dirname(server), 'server-failed.json');
    clearMarkers(server, dataDirectory);
    const child = spawn(process.execPath, [
        '--jitless', '--require', guard, entry,
        `--configPath=${configPath}`, `--dataRoot=${dataDirectory}`, `--port=${port}`,
        '--listen=false', '--enableIPv4=true', '--enableIPv6=false', '--browserLaunchEnabled=false',
    ], {
        cwd: server,
        env: { ...process.env, TARVEN_SERVER_DIR: server, DATA_DIR: dataDirectory },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    const runtime = captureRuntime(child);
    const base = `http://127.0.0.1:${port}`;
    const startedAt = Date.now();
    try {
        while (!runtime.log().includes('[ios-frontend] Verified') || !fs.existsSync(readyFile) || !fs.existsSync(fetchVerified)) {
            runtime.assertRunning();
            // The loader removes any stale markers before announcing this startup.
            if (runtime.log().includes('[test] WASM disabled') && fs.existsSync(failureFile)) {
                assert.fail(fs.readFileSync(failureFile, 'utf8') + '\n' + runtime.log());
            }
            assert.ok(Date.now() - startedAt < 45000, 'Server startup timed out:\n' + runtime.log());
            await delay(100);
        }
        const assets = await verifyAssets(server, base);
        assert.equal(fs.existsSync(failureFile), false, runtime.log());
        assert.doesNotMatch(runtime.log(), /Runtime must not import webpack|Compiling frontend libraries/);
        t.diagnostic(`HTTP 200 for the homepage and ${assets} hash-verified assets; startup ${Date.now() - startedAt}ms.`);
    } finally {
        await runtime.stop();
        clearMarkers(server, dataDirectory);
        if (process.env.SILLYCLIENT_TEST_LOG) {
            fs.writeFileSync(process.env.SILLYCLIENT_TEST_LOG, runtime.log());
        }
    }
});

test('the production supervisor starts the prepared no-WASM server and restarts it in the same host', {
    skip: directory ? false : 'Set SILLYCLIENT_IOS_SERVER to a disposable, prepared SillyTavern copy.',
    timeout: 120000,
}, async t => {
    assert.equal(process.versions.node, '18.20.4', 'Use the embedded-runtime matching Node 18.20.4 for real server integration.');
    const server = fs.realpathSync(directory);
    const { temporary, dataDirectory, configPath, guard, workerFetchVerified } = prepareFixture(t, server, 'ios-supervisor-server-');
    const control = path.join(temporary, 'control');
    const port = await freePort();
    const env = { ...process.env, SILLYCLIENT_CONTROL_DIR: control, SILLYCLIENT_STARTUP_TIMEOUT: '40000' };
    delete env.SILLYCLIENT_INSTANCES_ROOT;
    clearMarkers(server, dataDirectory);
    const entry = path.join(temporary, 'supervisor-entry.mjs');
    fs.writeFileSync(entry, `
        // Jitless is a host-global capability simulation, not an embedded Worker option.
        process.execArgv = process.execArgv.filter(argument => argument !== '--jitless');
        await import(${JSON.stringify(pathToFileURL(supervisor).href)});
    `);
    const child = spawn(process.execPath, ['--jitless', '--expose-gc', '--require', guard, entry], {
        cwd: temporary, env, stdio: ['ignore', 'pipe', 'pipe'],
    });
    const runtime = captureRuntime(child);
    const hostPid = child.pid;
    const base = `http://127.0.0.1:${port}`;
    const diagnostics = () => runtime.workerLog() + '\nHost output:\n' + runtime.log();
    let serial = 0;
    async function command(options, timeout = 45000) {
        const requestId = `production-request-${++serial}`;
        const file = path.join(control, 'requests', `${requestId}.json`);
        fs.writeFileSync(file + '.tmp', JSON.stringify({ ...options, requestId }));
        fs.renameSync(file + '.tmp', file);
        const response = path.join(control, 'responses', `${requestId}.json`);
        const startedAt = Date.now();
        while (!fs.existsSync(response)) {
            runtime.assertRunning(diagnostics());
            assert.ok(Date.now() - startedAt < timeout, 'Supervisor command timed out:\n' + diagnostics());
            await delay(25);
        }
        return JSON.parse(fs.readFileSync(response, 'utf8'));
    }
    async function assertPortClosed() {
        const socket = net.createConnection({ host: '127.0.0.1', port });
        try {
            const result = await new Promise(resolve => {
                socket.once('connect', () => resolve('open'));
                socket.once('error', error => resolve(error.code));
                socket.setTimeout(2000, () => resolve('timeout'));
            });
            assert.equal(result, 'ECONNREFUSED', diagnostics());
        } finally {
            socket.destroy();
        }
    }
    try {
        const mailboxStartedAt = Date.now();
        while (!fs.existsSync(path.join(control, 'status.json'))) {
            runtime.assertRunning(diagnostics());
            assert.ok(Date.now() - mailboxStartedAt < 10000, 'Supervisor mailbox did not initialize:\n' + diagnostics());
            await delay(25);
        }
        assert.equal(JSON.parse(fs.readFileSync(path.join(control, 'status.json'), 'utf8')).state, 'idle');
        for (let cycle = 1; cycle <= 2; cycle++) {
            const operationId = `production-start-${cycle}`;
            const identity = { instanceId: 'production-worker', operationId };
            const result = await command({
                action: 'start', ...identity, port,
                serverDirectory: server, dataDirectory, configPath,
            });
            assert.deepEqual(result, { success: true, ready: true }, diagnostics());
            runtime.assertRunning(diagnostics());
            assert.equal(child.pid, hostPid);
            const report = JSON.parse(fs.readFileSync(path.join(control, 'status.json'), 'utf8'));
            assert.equal(report.state, 'ready', diagnostics());
            assert.equal(report.operationId, operationId);
            assert.equal(report.instanceId, identity.instanceId);
            assert.equal(report.port, port);
            assert.equal(report.url, base + '/');
            const startedAt = Date.now();
            while (!runtime.workerLog(operationId).includes('[ios-frontend] Verified')
                || !runtime.workerLog(operationId).includes('[test] Worker global fetch and response parsing succeeded without WASM.')
                || !fs.existsSync(workerFetchVerified)
                || fs.readFileSync(workerFetchVerified, 'utf8') !== operationId) {
                runtime.assertRunning(diagnostics());
                assert.equal(JSON.parse(fs.readFileSync(path.join(control, 'status.json'), 'utf8')).state, 'ready', diagnostics());
                assert.ok(Date.now() - startedAt < 10000, 'Worker asset or no-WASM fetch verification did not complete:\n' + diagnostics());
                await delay(25);
            }
            const workerLog = runtime.workerLog(operationId);
            assert.match(workerLog, /\[test\] WASM disabled; webpack imports blocked\. worker/);
            assert.match(workerLog, /\[ios-loader\] Node\.js Version: v18\.20\.4/);
            assert.match(workerLog, /\[ios-loader\] Using node-fetch without a WASM HTTP parser\./);
            assert.match(workerLog, /\[test\] Worker global fetch and response parsing succeeded without WASM\./);
            assert.doesNotMatch(workerLog, /Runtime must not import webpack|Compiling frontend libraries|process\.chdir\(\) is not supported in workers/);
            const assets = await verifyAssets(server, base);
            assert.equal(fs.existsSync(path.join(path.dirname(server), 'server-failed.json')), false, diagnostics());
            assert.equal((await command({ action: 'stop', ...identity }, 10000)).success, true, diagnostics());
            await assertPortClosed();
            runtime.assertRunning(diagnostics());
            assert.equal(child.pid, hostPid);
            const stopped = JSON.parse(fs.readFileSync(path.join(control, 'status.json'), 'utf8'));
            assert.equal(stopped.state, 'stopped');
            assert.equal(stopped.operationId, operationId);
            t.diagnostic(`Cycle ${cycle}: host PID ${hostPid}, HTTP 200 and ${assets} hash-verified assets; stop confirmed closed port ${port}.`);
        }
    } finally {
        await runtime.stop();
        clearMarkers(server, dataDirectory);
        if (process.env.SILLYCLIENT_TEST_LOG) {
            fs.writeFileSync(process.env.SILLYCLIENT_TEST_LOG + '.supervisor', diagnostics());
        }
    }
});
