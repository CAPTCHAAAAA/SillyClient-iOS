import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');

test('cloud verification never configures or calls a paid model API', () => {
    const workflow = read('.github/workflows/build-ipa.yml');
    const runner = read('scripts/run-ios-e2e.mjs');
    assert.doesNotMatch(workflow + runner, /api\.deepseek|DEEPSEEK|deepseek-chat|proxy_password|Buffer\.from\([^)]*base64/);
    assert.match(workflow, /pnpm install --frozen-lockfile/);
    assert.match(workflow, /contents: read/);
    assert.match(workflow, /if: always\(\)/);
    assert.match(runner, /physicalDeviceTested: false/);
    assert.match(runner, /paidApiTested: false/);
    assert.doesNotMatch(runner, /chat_reply|createElement|screenshot/);
});

test('test execution is guarded by Debug and an explicit launch argument', () => {
    const delegate = read('native-src/AppDelegate.swift');
    const harness = read('native-src/IOSDebugHarness.swift');
    assert.match(delegate, /#if DEBUG[\s\S]*--sillyclient-runtime-probe/);
    assert.match(delegate, /#if DEBUG[\s\S]*--sillyclient-test/);
    assert.match(harness, /^#if DEBUG/);
    assert.match(delegate, /open url: URL[\s\S]*return false/);
    assert.doesNotMatch(delegate, /__onAutoTourStage|chat_reply|api-badge|--auto-tour/);
    assert.match(harness, /callAsyncJavaScript/);
    assert.match(harness, /data\.count <= 65536/);
});

test('capability probe returns before creating the real console and stays isolated on foreground', () => {
    const delegate = read('native-src/AppDelegate.swift');
    const launch = delegate.slice(delegate.indexOf('func application(_ application: UIApplication, didFinishLaunching'));
    const branch = launch.slice(0, launch.indexOf('#endif'));
    assert.match(branch, /#if DEBUG[\s\S]*--sillyclient-runtime-probe[\s\S]*IOSDebugHarness\.runRuntimeProbe\(\)[\s\S]*return true/);
    assert.doesNotMatch(branch, /TavernViewController\.shared|SillyBridgeViewController\(\)/);
    const foreground = delegate.slice(delegate.indexOf('func applicationWillEnterForeground'),
        delegate.indexOf('func applicationWillTerminate'));
    assert.match(foreground, /#if DEBUG[\s\S]*--sillyclient-runtime-probe.*return[\s\S]*#endif[\s\S]*ensureActiveConnection/);
});

test('unsigned artifact version and monotonic native build agree', () => {
    const plist = read('native-src/Info.plist');
    const workflow = read('.github/workflows/build-ipa.yml');
    assert.match(plist, /CFBundleShortVersionString<\/key>\s*<string>1\.10\.0<\/string>/);
    const build = Number(plist.match(/CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/)?.[1]);
    assert.ok(build >= 18);
    assert.match(workflow, /SillyClient-iOS-v1\.10\.0-unsigned/);
    assert.doesNotMatch(workflow, /万能|直接安装|真机截图/);
});

test('host capability probe really terminates and restarts HTTP workers', t => {
    const parent = process.env.SILLYCLIENT_TEST_TMP || os.tmpdir();
    fs.mkdirSync(parent, { recursive: true });
    const directory = fs.mkdtempSync(path.join(parent, 'ios-capability-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const report = path.join(directory, 'report.json');
    const result = spawnSync(process.execPath, [path.join(root, 'native-src/Resources/ios-runtime-probe.mjs')], {
        env: { ...process.env, SILLYCLIENT_PROBE_REPORT: report },
        encoding: 'utf8', timeout: 15000,
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const actual = JSON.parse(fs.readFileSync(report, 'utf8'));
    assert.equal(actual.success, true, actual.error);
    assert.equal(actual.cycles.length, 2);
    assert.ok(actual.cycles.every(cycle => cycle.httpStatus === 200 && cycle.portClosedAfterTermination));
});

async function simulateDriver(scenario = 'success') {
    const files = new Map();
    const directories = new Set();
    const virtualRoot = path.resolve(os.tmpdir(), 'sillyclient-driver-virtual');
    const application = path.join(virtualRoot, 'App.app');
    const container = path.join(virtualRoot, 'container');
    const documents = path.join(container, 'Documents');
    const evidence = path.resolve('evidence');
    const key = file => path.resolve(file);
    const put = (file, value) => files.set(key(file), Buffer.isBuffer(value) ? value : Buffer.from(value));
    const missing = () => Object.assign(new Error('Virtual file not found'), { code: 'ENOENT' });
    const get = file => {
        if (!files.has(key(file))) throw missing();
        return files.get(key(file));
    };
    const asset = Buffer.from('verified virtual frontend');
    const loader = 'virtual current loader';
    const runtime = path.join(application, 'sillytavern');
    for (const name of ['server.js', 'patch-sillytavern.mjs', 'config.yaml']) put(path.join(runtime, name), name);
    put(path.join(runtime, 'ios-loader.mjs'), loader);
    put('native-src/ios-loader.mjs', loader);
    put(path.join(runtime, 'package.json'), JSON.stringify({ version: '1.19.0' }));
    put(path.join(runtime, 'dist/ios-frontend/lib.js'), asset);
    put(path.join(runtime, 'dist/ios-frontend/manifest.json'), JSON.stringify({
        format: 1, version: '1.19.0',
        assets: [{ name: 'lib.js', bytes: asset.length, sha256: createHash('sha256').update(asset).digest('hex') }],
    }));
    let clock = 0;
    let sequence = 0;
    let alive = false;
    let listening = false;
    let active;
    let state = 'idle';
    let acceptedStops = 0;
    const respond = request => {
        if (request.action === 'nativeTests') {
            return { success: true, result: { success: true,
                results: Array.from({ length: 19 }, (_, index) => ({ name: `Virtual group ${index}`, passed: true })) } };
        }
        if (request.action === 'tavern') {
            return { success: true, result: { ready: 'complete', hasChat: true, hasInput: true, hasClient: true,
                title: 'SillyTavern', url: 'http://127.0.0.1:8000/' } };
        }
        const options = request.options;
        const success = result => ({ success: true, result });
        const reject = error => ({ success: false, error });
        switch (request.method) {
        case 'getPlatform': return success({ platform: 'ios' });
        case 'getAppVersion': return success({ version: '1.10.0' });
        case 'getStatus': return success({ serverReady: !!active, state, port: active ? 8000 : 0,
            url: active ? 'http://127.0.0.1:8000/' : '', ...active });
        case 'provisionAndStart':
            if (active) return reject('Stop the current operation before starting an instance');
            if (scenario === 'process-exit') { alive = false; return undefined; }
            active = { instanceId: options.instanceId, operationId: options.operationId };
            state = 'ready';
            listening = true;
            directories.add(key(path.join(documents, 'SillyTavern')));
            return success({ ready: true, ...active });
        case 'stop':
            if (options.instanceId !== active?.instanceId || options.operationId !== active?.operationId) {
                if (scenario === 'stale-stop-success') return success({ success: true });
                if (scenario === 'rejection-timeout') return undefined;
                return reject('The requested session is no longer current');
            }
            active = undefined;
            state = 'stopped';
            if (scenario !== 'listener-left-open') listening = false;
            acceptedStops += 1;
            return success({ success: true });
        case 'returnToTavern': return active ? success({ success: true }) : reject('No ready local Tavern session exists');
        case 'enterImmersive':
            if (active && options.instanceId !== active.instanceId) {
                if (scenario === 'remote-navigation-success') return success({ success: true });
                if (scenario === 'remote-navigation-replaces-operation') active.operationId = 'remote-hardening-operation';
                return reject('Stop the current local operation before opening a remote Tavern');
            }
            return success({ success: true });
        case 'exitImmersive': return success({ success: true });
        default: throw new Error(`Unexpected virtual native method: ${request.method}`);
        }
    };
    const fakeFs = {
        mkdirSync(file) { directories.add(key(file)); },
        existsSync(file) { return files.has(key(file)) || directories.has(key(file)); },
        readFileSync(file, encoding) { const value = get(file); return encoding ? value.toString(encoding) : value; },
        writeFileSync(file, value) { put(file, value); },
        statSync(file) { return { size: get(file).length, isFile: () => true }; },
        copyFileSync(source, destination) { put(destination, get(source)); },
        rmSync(file, options) {
            assert.equal(options.recursive, undefined, 'Driver attempted a recursive deletion');
            files.delete(key(file));
        },
        renameSync(source, destination) {
            put(destination, get(source));
            files.delete(key(source));
            if (path.basename(destination) !== 'request.json') return;
            const request = JSON.parse(get(destination).toString());
            const response = respond(request);
            if (response) put(path.join(path.dirname(destination), `${request.id}.json`), JSON.stringify(response));
        },
    };
    const fakeSimctl = (binary, args) => {
        assert.equal(binary, 'xcrun');
        assert.equal(args[0], 'simctl');
        const action = args[1];
        if (['boot', 'bootstatus', 'install'].includes(action)) return '';
        if (action === 'get_app_container') return container + '\n';
        if (action === 'terminate') { alive = false; return ''; }
        if (action === 'spawn') return 'Virtual simulator diagnostic log\n';
        assert.equal(action, 'launch');
        alive = true;
        if (args.includes('--sillyclient-runtime-probe')) {
            put(path.join(documents, 'ios-test/runtime-probe.json'), JSON.stringify({
                success: true, cycles: [0, 1].map(cycle => ({ cycle, httpStatus: 200, portClosedAfterTermination: true })),
            }));
        }
        return 'com.sillyclient.ios: 9001\n';
    };
    const fakeHttp = {
        get(url, callback) {
            assert.equal(new URL(url).origin, 'http://127.0.0.1:8000');
            const request = new EventEmitter();
            request.setTimeout = () => request;
            request.destroy = error => { if (error) request.emit('error', error); };
            queueMicrotask(() => {
                if (!listening) { request.emit('error', new Error('Virtual connection refused')); return; }
                const response = new EventEmitter();
                response.statusCode = 200;
                callback(response);
                response.emit('data', new URL(url).pathname === '/lib.js' ? asset : Buffer.from('SillyTavern virtual homepage'));
                response.emit('end');
            });
            return request;
        },
    };
    const fakeNet = {
        createConnection(options) {
            assert.equal(options.host, '127.0.0.1');
            assert.equal(options.port, 8000);
            const socket = new EventEmitter();
            socket.destroy = () => {};
            socket.setTimeout = () => socket;
            queueMicrotask(() => {
                if (listening) socket.emit('connect');
                else socket.emit('error', Object.assign(new Error('Virtual connection refused'), { code: 'ECONNREFUSED' }));
            });
            return socket;
        },
    };
    const source = read('scripts/run-ios-e2e.mjs');
    // Only the fixed import prologue is excluded; the entire real driver body runs.
    const bodyStart = source.indexOf('const [device, appPath] =');
    assert.ok(bodyStart >= 0, 'Driver entry point changed; update the isolated VM bindings');
    let error;
    try {
        await vm.runInNewContext(`(async () => {\n${source.slice(bodyStart)}\n})()`, {
            assert, fs: fakeFs, path, http: fakeHttp, net: fakeNet, createHash, randomUUID: () => `request-${++sequence}`,
            execFileSync: fakeSimctl, Buffer, URL, Date: { now: () => clock },
            console: { warn() {} },
            setTimeout(callback, milliseconds) { clock += milliseconds; queueMicrotask(callback); },
            process: { argv: ['node', 'run-ios-e2e.mjs', 'virtual-device', application],
                kill(pid, signal) {
                    assert.equal(pid, 9001);
                    assert.equal(signal, 0, 'Driver sent a process termination signal');
                    if (!alive) throw Object.assign(new Error('Virtual application exited'), { code: 'ESRCH' });
                } },
        }, { timeout: 1000 });
    } catch (failure) { error = failure; }
    const report = JSON.parse(get(path.join(evidence, 'simulator-results.json')).toString());
    return { report, error, clock, acceptedStops, listening };
}

test('real simulator driver completes all lifecycle stages using isolated protocol fixtures', async () => {
    const actual = await simulateDriver();
    assert.equal(actual.error, undefined, actual.error?.message);
    assert.equal(actual.report.results.length, 16);
    assert.ok(actual.report.results.every(result => result.passed));
    assert.equal(actual.report.results.find(result => result.name.includes('native filesystem')).actual.groups, 19);
    const remoteRejection = actual.report.results.find(result => result.name.includes('Remote navigation')).actual;
    assert.equal(remoteRejection.rejected, true);
    assert.equal(remoteRejection.instanceId, 'default');
    assert.ok(remoteRejection.homepageBytes > 0);
    assert.equal(actual.acceptedStops, 2);
    assert.equal(actual.listening, false);
    assert.equal(actual.report.physicalDeviceTested, false);
    assert.equal(actual.report.visualReviewPerformed, false);
});

for (const [scenario, stage, message] of [
    ['remote-navigation-success', 'Remote navigation', /unexpectedly accepted/],
    ['remote-navigation-replaces-operation', 'Remote navigation', /remote-hardening-operation/],
    ['listener-left-open', 'Native stop closes', /listener open/],
    ['stale-stop-success', 'stale operation stop', /unexpectedly accepted/],
    ['process-exit', 'embedded server startup', /application exited before replying/],
    ['rejection-timeout', 'stale operation stop', /Timed out waiting/],
]) {
    test(`simulator driver fails instead of reporting success: ${scenario}`, async () => {
        const actual = await simulateDriver(scenario);
        assert.ok(actual.error, 'Invalid native behavior was accepted');
        assert.match(actual.error.message, message);
        const failed = actual.report.results.filter(result => !result.passed);
        assert.equal(failed.length, 1);
        assert.ok(failed[0].name.includes(stage), failed[0].name);
        if (scenario === 'process-exit') assert.ok(actual.clock < 1000, 'Application exit waited for the startup deadline');
    });
}
