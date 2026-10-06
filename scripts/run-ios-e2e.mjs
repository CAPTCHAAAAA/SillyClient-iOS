import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const [device, appPath] = process.argv.slice(2);
assert.ok(device && appPath, 'Simulator UUID and built application path are required');
const bundleId = 'com.sillyclient.ios';
const evidence = path.resolve('evidence');
fs.mkdirSync(evidence, { recursive: true });
const results = [];
let documents;
let container;
let appPid;
let installationRoot;
let instanceDirectory;
let commandInFlight = false;
const instanceId = 'default';
const port = 8000;
const origin = `http://127.0.0.1:${port}`;
const firstOperation = `simulator-${randomUUID()}`;
const secondOperation = `simulator-${randomUUID()}`;
const nativeFixtureGroups = 44;
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 120000,
});
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const uiDelay = milliseconds => device.startsWith('virtual') ? Promise.resolve() : sleep(milliseconds);
const digest = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');

const timestampsFile = path.join(evidence, 'step-timestamps.json');
const stepTimestamps = [];

function recordStepTimestamp(name) {
    const startFile = path.join(evidence, 'recorder-start-time.txt');
    let startTime = Date.now();
    try {
        if (fs.existsSync(startFile)) {
            startTime = Number(fs.readFileSync(startFile, 'utf8'));
        }
    } catch {}
    const timeSec = Math.max(0.1, (Date.now() - startTime) / 1000);
    stepTimestamps.push({ name, time: Number(timeSec.toFixed(2)) });
    fs.writeFileSync(timestampsFile, JSON.stringify(stepTimestamps, null, 2), 'utf8');
    if (typeof console?.log === 'function') console.log(`[E2E] Recorded diagnostic checkpoint: ${name} @ ${timeSec.toFixed(2)}s`);
}

function launch(argument) {
    const output = simctl('launch', device, bundleId, argument);
    const pid = output.trim().match(/:\s*(\d+)\s*$/);
    assert.ok(pid, 'Simulator launch did not report the application PID');
    appPid = Number(pid[1]);
}

function assertAppAlive() {
    if (!appPid) return;
    try { process.kill(appPid, 0); }
    catch (error) {
        if (error.code === 'ESRCH') throw new Error(`Simulator application exited before replying (PID ${appPid})`);
        throw error;
    }
}

async function waitForFile(file, timeout = 10000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        assertAppAlive();
        try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
        catch (error) {
            if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
        }
        await sleep(100);
    }
    throw new Error(`Timed out waiting for ${path.basename(file)}`);
}

async function nativeRequest(method, options = {}, action = 'call', timeout = 10000) {
    assert.equal(commandInFlight, false, 'The single-request debug bridge requires serialized commands');
    commandInFlight = true;
    try {
        const id = randomUUID();
        const directory = path.join(documents, 'ios-test');
        fs.mkdirSync(directory, { recursive: true });
        const temporary = path.join(directory, 'request.tmp');
        fs.writeFileSync(temporary, JSON.stringify({ id, action, method, options }));
        fs.renameSync(temporary, path.join(directory, 'request.json'));
        try {
            return await waitForFile(path.join(directory, `${id}.json`), timeout);
        } catch (error) {
            if (action === 'nativeTests') {
                try {
                    const progress = JSON.parse(fs.readFileSync(path.join(directory, 'native-module-progress.json'), 'utf8'));
                    if (progress.requestId === id && typeof progress.currentGroup === 'string'
                        && Number.isInteger(progress.completedGroups)) {
                        error.message += `; native group ${progress.currentGroup} (${progress.completedGroups} completed)`;
                    }
                } catch {}
            }
            throw error;
        }
    } finally {
        commandInFlight = false;
    }
}

async function command(method, options = {}, action = 'call', timeout = 10000) {
    const response = await nativeRequest(method, options, action, timeout);
    if (response.success !== true) throw new Error(response.error || `${method} rejected`);
    return response.result;
}

async function rejectedCommand(method, options) {
    const response = await nativeRequest(method, options);
    assert.equal(response.success, false, `${method} unexpectedly accepted an obsolete or unavailable session`);
    assert.ok(typeof response.error === 'string' && response.error.length > 0, 'Native rejection omitted its error');
    return { rejected: true, error: response.error };
}

function writeReport() {
    fs.writeFileSync(path.join(evidence, 'simulator-results.json'), JSON.stringify({
        platform: 'GitHub-hosted iOS simulator', device, results,
        physicalDeviceTested: false, paidApiTested: false, visualReviewPerformed: false,
        uiInteractionTested: false,
    }, null, 2));
}

async function check(name, callback) {
    const startedAt = Date.now();
    try {
        const actual = await callback();
        results.push({ name, passed: true, elapsedMs: Date.now() - startedAt, actual });
    } catch (error) {
        results.push({ name, passed: false, elapsedMs: Date.now() - startedAt, error: error.message });
        throw error;
    } finally {
        writeReport();
    }
}

function get(url) {
    return new Promise((resolve, reject) => {
        const request = http.get(url, response => {
            const chunks = [];
            response.on('data', chunk => chunks.push(chunk));
            response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks) }));
            response.once('error', reject);
            response.once('aborted', () => reject(new Error('HTTP response was aborted')));
        });
        request.once('error', reject);
        request.setTimeout(3000, () => request.destroy(new Error('HTTP response timed out')));
    });
}

function portIsClosed() {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection({ host: '127.0.0.1', port });
        socket.once('connect', () => { socket.destroy(); resolve(false); });
        socket.once('error', error => {
            if (error.code === 'ECONNREFUSED') resolve(true);
            else reject(error);
        });
        socket.setTimeout(1000, () => socket.destroy(new Error('Listener closure could not be confirmed')));
    });
}

async function verifyStopped() {
    const deadline = Date.now() + 10000;
    let closed = false;
    while (Date.now() < deadline) {
        assertAppAlive();
        closed = await portIsClosed();
        if (closed) break;
        await sleep(100);
    }
    assert.equal(closed, true, 'Native stop left the real listener open');
    await sleep(250);
    assert.equal(await portIsClosed(), true, 'A delayed worker reopened the stopped port');
    const status = await command('getStatus');
    assert.equal(status.serverReady, false);
    assert.equal(status.state, 'stopped');
    assert.equal(status.instanceId, undefined);
    assert.equal(status.operationId, undefined);
    return { port, portClosedAfterStop: true, state: status.state };
}

async function verifyReady(operationId) {
    const status = await command('getStatus');
    assert.equal(status.serverReady, true);
    assert.equal(status.instanceId, instanceId);
    assert.equal(status.operationId, operationId);
    assert.equal(status.port, port);
    assert.equal(new URL(status.url).origin, origin);
    const response = await get(`${origin}/`);
    assert.equal(response.status, 200);
    assert.ok(response.body.includes(Buffer.from('SillyTavern')));
    return { instanceId, operationId, port, homepageBytes: response.body.length };
}

async function verifyTavern() {
    const deadline = Date.now() + 90000;
    let actual;
    let lastError;
    while (Date.now() < deadline) {
        try {
            actual = await command(undefined, {}, 'tavern');
            if (actual?.hasChat && actual?.hasInput && actual?.hasClient && actual.ready === 'complete') break;
        } catch (error) {
            lastError = error;
            assertAppAlive();
        }
        await sleep(300);
    }
    assert.ok(actual?.hasChat && actual?.hasInput && actual?.hasClient && actual.ready === 'complete',
        `Real Tavern JavaScript and DOM did not become ready: ${lastError?.message || ''}`);
    assert.equal(new URL(actual.url).origin, origin);
    return actual;
}

async function waitForBridge() {
    const deadline = Date.now() + 30000;
    let lastError;
    while (Date.now() < deadline) {
        try {
            const platform = await command('getPlatform', {}, 'call', 3000);
            assert.equal(platform.platform, 'ios');
            return platform;
        } catch (error) {
            lastError = error;
            assertAppAlive();
            await sleep(200);
        }
    }
    throw lastError || new Error('The real Capacitor bridge did not become available');
}

try {
    await check('Packaged runtime contains the current loader and verified frontend', async () => {
        const runtime = path.join(appPath, 'sillytavern');
        for (const name of ['server.js', 'ios-loader.mjs', 'patch-sillytavern.mjs', 'config.yaml', 'dist/ios-frontend/manifest.json']) {
            assert.equal(fs.statSync(path.join(runtime, name)).isFile(), true, `Missing packaged runtime file: ${name}`);
        }
        const loaderSha256 = digest(path.join(runtime, 'ios-loader.mjs'));
        assert.equal(loaderSha256, digest('native-src/ios-loader.mjs'), 'Packaged loader differs from the checked-out source');
        const manifest = JSON.parse(fs.readFileSync(path.join(runtime, 'dist/ios-frontend/manifest.json'), 'utf8'));
        const version = JSON.parse(fs.readFileSync(path.join(runtime, 'package.json'), 'utf8')).version;
        assert.equal(manifest.format, 1);
        assert.equal(manifest.version, version);
        const assetRoot = path.resolve(runtime, 'dist/ios-frontend');
        for (const asset of manifest.assets) {
            const file = path.resolve(assetRoot, asset.name);
            const relative = path.relative(assetRoot, file);
            assert.ok(relative && !path.isAbsolute(relative) && relative !== '..'
                && !relative.startsWith(`..${path.sep}`), 'Frontend manifest path escaped the prepared directory');
            assert.equal(fs.statSync(file).size, asset.bytes, `Packaged frontend size differs: ${asset.name}`);
            assert.equal(digest(file), asset.sha256, `Packaged frontend digest differs: ${asset.name}`);
        }
        assert.ok(manifest.assets.some(asset => asset.name === 'lib.js' && asset.bytes > 0));
        return { loaderSha256, serverVersion: version, frontendAssets: manifest.assets.length };
    });
    try { simctl('boot', device); } catch {}
    simctl('bootstatus', device, '-b');
    simctl('install', device, appPath);
    await uiDelay(2000);
    recordStepTimestamp('00-app-installed');
    container = simctl('get_app_container', device, bundleId, 'data').trim();
    documents = path.join(container, 'Documents');
    const runtimePaths = ['SillyTavern', 'instances', 'instances-registry.json'];
    for (const relative of runtimePaths) {
        assert.equal(fs.existsSync(path.join(documents, relative)), false, 'Simulator verification requires a fresh application sandbox');
    }
    await check('Actual NodeMobile worker HTTP, termination, and restart capability', async () => {
        fs.rmSync(path.join(documents, 'ios-test', 'runtime-probe.json'), { force: true });
        launch('--sillyclient-runtime-probe');
        const result = await waitForFile(path.join(documents, 'ios-test', 'runtime-probe.json'), 45000);
        fs.writeFileSync(path.join(evidence, 'node-mobile-runtime-probe.json'), JSON.stringify(result, null, 2));
        assert.equal(result.success, true, result.error);
        assert.equal(result.cycles.length, 2);
        assert.ok(result.cycles.every(cycle => cycle.httpStatus === 200 && cycle.portClosedAfterTermination));
        for (const relative of runtimePaths) {
            assert.equal(fs.existsSync(path.join(documents, relative)), false, 'Capability probe unexpectedly provisioned a normal instance');
        }
        return result;
    });
    await check('Real Capacitor native bridge and application version', async () => {
        simctl('terminate', device, bundleId);
        appPid = undefined;
        launch('--sillyclient-test');
        await waitForBridge();
        const version = await command('getAppVersion');
        assert.equal(version.version, '1.10.0');
        const consoleStatus = await command(undefined, {}, 'console');
        assert.equal(consoleStatus.loggingEnabled, false, 'Capacitor payload logging must be disabled');
        recordStepTimestamp('01-native-bridge-ready');
        return { ...version, loggingEnabled: consoleStatus.loggingEnabled };
    });
    await check('Actual native filesystem, URL policy, and archive module regressions', async () => {
        const result = await command(undefined, {}, 'nativeTests', 180000);
        fs.writeFileSync(path.join(evidence, 'native-module-results.json'), JSON.stringify(result, null, 2));
        assert.ok(Array.isArray(result.results) && result.results.length === nativeFixtureGroups,
            'Native tests did not report all current groups');
        assert.ok(result.results.every(item => typeof item.name === 'string' && item.name.length > 0),
            'Native test groups must have names');
        assert.equal(new Set(result.results.map(item => item.name)).size, nativeFixtureGroups,
            'Native test group names must be distinct');
        assert.equal(result.success, true, JSON.stringify(result.results.filter(item => item.passed !== true)));
        assert.ok(result.results.every(item => item.passed === true), 'One or more real Swift test groups failed');
        return { groups: result.results.length, ...result };
    });
    await check('Real embedded server startup through the native plugin', async () => {
        fs.mkdirSync(path.join(documents, 'selected-runtime-root'), { recursive: true });
        installationRoot = fs.realpathSync(path.join(documents, 'selected-runtime-root'));
        instanceDirectory = path.join(installationRoot, instanceId);
        const selected = await command(undefined, { path: installationRoot }, 'installationRoot');
        assert.equal(selected.path, installationRoot);
        assert.equal(selected.installPathMode, 'root');
        assert.equal(selected.persistentAuthorization, true);
        const result = await command('provisionAndStart', { instanceId, port, operationId: firstOperation,
            installPath: installationRoot, installPathMode: 'root' }, 'call', 120000);
        assert.equal(result.ready, true);
        assert.equal(result.instanceId, instanceId);
        assert.equal(result.operationId, firstOperation);
        assert.equal(result.installPath, fs.realpathSync(instanceDirectory));
        const info = await command('getInstanceInfo', { instanceId, installPath: result.installPath });
        assert.equal(info.installPath, result.installPath, 'Info did not retain the selected runtime path');
        assert.equal(fs.existsSync(path.join(documents, 'SillyTavern')), false, 'Selected runtime silently used the default directory');
        assert.ok(fs.readFileSync(path.join(instanceDirectory, 'config.yaml'), 'utf8').includes(path.join(instanceDirectory, 'data')),
            'Selected runtime config uses another data directory');
        recordStepTimestamp('02-instance-server-ready');
        return { ...await verifyReady(firstOperation), installPath: info.installPath, installPathMode: 'exact' };
    });
    await check('Remote navigation cannot replace an active local session', async () => {
        const rejection = await rejectedCommand('enterImmersive', {
            instanceId: 'remote-hardening-test',
            url: 'https://example.test/',
        });
        const local = await verifyReady(firstOperation);
        return { ...rejection, ...local };
    });
    await check('Served frontend bytes match the build-time manifest', async () => {
        const manifest = JSON.parse(fs.readFileSync(path.join(appPath, 'sillytavern', 'dist', 'ios-frontend', 'manifest.json')));
        const asset = manifest.assets.find(item => item.name === 'lib.js');
        assert.ok(asset);
        const response = await get(`${origin}/lib.js`);
        assert.equal(response.status, 200);
        assert.equal(response.body.length, asset.bytes);
        assert.equal(createHash('sha256').update(response.body).digest('hex'), asset.sha256);
        return { bytes: response.body.length, sha256: asset.sha256 };
    });
    await check('Real Tavern WebView loads the embedded server DOM', async () => {
        await command('enterImmersive', { instanceId, url: `${origin}/` });
        const tavern = await verifyTavern();
        await uiDelay(1500);
        recordStepTimestamp('03-tavern-dom-ready');
        return tavern;
    });
    await check('Return to Tavern reopens the current ready session', async () => {
        await command('exitImmersive');
        await uiDelay(1000);
        recordStepTimestamp('04-console-return');
        assert.equal((await command('returnToTavern')).success, true);
        return verifyTavern();
    });
    await check('A second start cannot replace a reserved running session', async () => {
        const rejection = await rejectedCommand('provisionAndStart', {
            instanceId: 'obsolete-instance', operationId: `simulator-${randomUUID()}`, port,
        });
        assert.equal(fs.existsSync(path.join(documents, 'instances', 'obsolete-instance')), false,
            'Rejected startup still provisioned an instance');
        await verifyReady(firstOperation);
        return rejection;
    });
    await check('Native stop closes the actual server port', async () => {
        assert.equal((await command('stop', { instanceId, operationId: firstOperation }, 'call', 25000)).success, true);
        return verifyStopped();
    });
    await check('Return to Tavern rejects a stopped session', async () => {
        return rejectedCommand('returnToTavern', {});
    });
    await check('The existing instance restarts on the same port in the same application', async () => {
        const result = await command('provisionAndStart', { instanceId, port, operationId: secondOperation,
            installPath: instanceDirectory, installPathMode: 'exact' }, 'call', 120000);
        assert.equal(result.ready, true);
        assert.equal(result.instanceId, instanceId);
        assert.equal(result.operationId, secondOperation);
        await command('returnToTavern');
        await verifyTavern();
        return verifyReady(secondOperation);
    });
    await check('A stale operation stop cannot terminate the restarted listener', async () => {
        const rejection = await rejectedCommand('stop', { instanceId, operationId: firstOperation });
        await verifyReady(secondOperation);
        return rejection;
    });
    await check('A different instance stop cannot terminate the current listener', async () => {
        const rejection = await rejectedCommand('stop', { instanceId: 'obsolete-instance', operationId: secondOperation });
        await verifyReady(secondOperation);
        return rejection;
    });
    await check('The restarted session also stops and closes its listener', async () => {
        await command('stop', { instanceId, operationId: secondOperation }, 'call', 25000);
        return verifyStopped();
    });
    await check('Application restart scans and starts the same selected runtime directory', async () => {
        simctl('terminate', device, bundleId);
        appPid = undefined;
        launch('--sillyclient-test');
        await waitForBridge();
        const scan = await command('scanInstances');
        const registered = scan.instances.find(item => item.instanceId === instanceId);
        assert.equal(registered?.installPath, instanceDirectory, 'Relaunch scan forgot the selected directory');
        const thirdOperation = `simulator-${randomUUID()}`;
        const result = await command('provisionAndStart', { instanceId, operationId: thirdOperation, port,
            installPath: instanceDirectory, installPathMode: 'exact' }, 'call', 120000);
        assert.equal(result.installPath, instanceDirectory, 'Relaunch substituted another runtime');
        const ready = await verifyReady(thirdOperation);
        await command('stop', { instanceId, operationId: thirdOperation }, 'call', 25000);
        return { ...ready, installPath: instanceDirectory, ...await verifyStopped() };
    });

    const copiedInstance = `simulator-copy-${randomUUID()}`;
    const copyOperation = `simulator-${randomUUID()}`;
    const sourceDirectory = path.join(documents, 'ios-test', `copy-source-${randomUUID()}`);
    const copiedDirectory = path.join(installationRoot, copiedInstance);
    const userDirectory = path.join(copiedDirectory, 'data', 'default-user');
    const chatRelative = 'default-user/chats/bridge-chat.jsonl';
    const extensionRelative = 'data/default-user/extensions/broken-bridge-fixture';
    const copiedExtension = path.join(copiedDirectory, extensionRelative);
    const sourceFiles = new Map([
        ['config.yaml', 'dataRoot: selected-data\nunrelated: source-preserved\n'],
        [`selected-data/${chatRelative}`, '{"user_name":"Synthetic user","is_user":true,"mes":"Preserved chat"}\n'],
        ['selected-data/default-user/settings.json', '{"unrelated":"preserved","extension_settings":{"disabledExtensions":[]}}\n'],
        ['selected-data/default-user/secrets.json', '{"syntheticCredential":true}\n'],
        ['selected-data/default-user/secrets.json.enc', 'synthetic encrypted credential\n'],
        ['selected-data/default-user/node_modules/legacy-only.js', 'synthetic old user dependency\n'],
        ['selected-data/.git/config', 'synthetic old data repository\n'],
        ['selected-data/default-user/extensions/broken-bridge-fixture/index.js', '// Synthetic incomplete extension fixture.\n'],
        ['node_modules/legacy-server-only.js', 'synthetic old server dependency\n'],
        ['.git/config', 'synthetic old server repository\n'],
        ['data/default-user/chats/bridge-chat.jsonl', 'wrong data root; this must not be selected\n'],
    ]);
    const sourceHashes = new Map([...sourceFiles].map(([relative, bytes]) => [
        relative, createHash('sha256').update(bytes).digest('hex'),
    ]));
    const chatHash = sourceHashes.get(`selected-data/${chatRelative}`);
    const extensionHash = sourceHashes.get('selected-data/default-user/extensions/broken-bridge-fixture/index.js');
    const settingsHash = sourceHashes.get('selected-data/default-user/settings.json');
    const excludedData = ['default-user/secrets.json', 'default-user/secrets.json.enc', 'default-user/node_modules', '.git'];
    let scan;
    let selected;
    let recoveryId;
    let recoveryFolder;
    let recoveryRecordHash;
    let restoreOptions;

    function verifySource() {
        for (const [relative, sha256] of sourceHashes) {
            assert.equal(digest(path.join(sourceDirectory, relative)), sha256, `Source fixture changed: ${relative}`);
        }
    }

    function verifyCopiedData() {
        assert.equal(digest(path.join(copiedDirectory, 'data', chatRelative)), chatHash, 'Copied chat hash changed');
        assert.equal(digest(path.join(userDirectory, 'settings.json')), settingsHash, 'Unrelated copied settings changed');
        for (const relative of excludedData) {
            assert.equal(fs.existsSync(path.join(copiedDirectory, 'data', relative)), false,
                `Excluded migration data was copied: ${relative}`);
        }
        assert.equal(fs.existsSync(path.join(copiedDirectory, '.git')), false, 'Old server Git metadata was copied');
        assert.equal(fs.existsSync(path.join(copiedDirectory, 'node_modules', 'legacy-server-only.js')), false,
            'Old server dependency was copied into the pinned runtime');
        verifySource();
    }

    await check('Actual copy migration commits a pinned runtime without starting it', async () => {
        assert.equal(fs.existsSync(sourceDirectory), false, 'Migration fixture source already exists');
        assert.equal(fs.existsSync(copiedDirectory), false, 'Migration fixture destination already exists');
        for (const [relative, bytes] of sourceFiles) {
            const file = path.join(sourceDirectory, relative);
            fs.mkdirSync(path.dirname(file), { recursive: true });
            fs.writeFileSync(file, bytes);
        }
        const beforeRegistry = JSON.parse(fs.readFileSync(path.join(documents, 'instances-registry.json'), 'utf8'));
        const result = await command('migrateInstance', {
            instanceId: copiedInstance,
            operationId: copyOperation,
            sourcePath: fs.realpathSync(sourceDirectory),
            targetPath: installationRoot,
            installPathMode: 'root',
            mode: 'copy',
            includeSecrets: false,
        }, 'call', 120000);
        assert.equal(result.success, true);
        assert.equal(result.instanceId, copiedInstance);
        assert.equal(result.targetPath, fs.realpathSync(copiedDirectory), 'Migration returned a different committed path');
        const runtime = path.join(appPath, 'sillytavern');
        for (const relative of ['server.js', 'ios-loader.mjs', 'package.json', 'dist/ios-frontend/manifest.json']) {
            assert.equal(fs.statSync(path.join(copiedDirectory, relative)).isFile(), true,
                `Copied runtime file is missing: ${relative}`);
            assert.equal(digest(path.join(copiedDirectory, relative)), digest(path.join(runtime, relative)),
                `Copied runtime differs from the pinned bundle: ${relative}`);
        }
        assert.equal(fs.statSync(path.join(copiedDirectory, 'node_modules')).isDirectory(), true);
        const manifest = JSON.parse(fs.readFileSync(path.join(copiedDirectory, 'dist/ios-frontend/manifest.json'), 'utf8'));
        for (const asset of manifest.assets) {
            const file = path.join(copiedDirectory, 'dist/ios-frontend', asset.name);
            assert.equal(fs.statSync(file).size, asset.bytes);
            assert.equal(digest(file), asset.sha256, `Copied frontend asset changed: ${asset.name}`);
        }
        const registry = JSON.parse(fs.readFileSync(path.join(documents, 'instances-registry.json'), 'utf8'));
        assert.deepEqual(Object.keys(registry).sort(), [...Object.keys(beforeRegistry), copiedInstance].sort(),
            'Migration registered an unexpected instance identity');
        for (const [id, record] of Object.entries(beforeRegistry)) {
            assert.deepEqual(registry[id], record, 'Migration changed an existing registration');
        }
        assert.equal(registry[copiedInstance].instanceId, copiedInstance);
        assert.equal(registry[copiedInstance].path, result.targetPath, 'Migration registry path differs from its committed target');
        assert.equal(registry[copiedInstance].isTakeover, false);
        verifyCopiedData();
        assert.equal(digest(path.join(copiedExtension, 'index.js')), extensionHash, 'Copied extension hash changed');
        const stopped = await verifyStopped();
        return { instanceId: copiedInstance, operationId: copyOperation, targetPath: result.targetPath,
            chatSha256: chatHash, verifiedSourceFiles: sourceHashes.size, excludedData, ...stopped };
    });
    await check('Actual maintenance scan finds the copied broken extension', async () => {
        scan = await command('scanInstanceMaintenance', { instanceId: copiedInstance });
        assert.equal(scan.instanceId, copiedInstance);
        assert.ok(typeof scan.scanId === 'string' && scan.scanId.length > 0);
        assert.equal(scan.items.length, 1, 'Tiny migration fixture produced unexpected maintenance candidates');
        const candidate = scan.items[0];
        assert.equal(candidate.kind, 'broken_extension');
        assert.equal(candidate.action, 'quarantine');
        assert.equal(candidate.relativePath, extensionRelative);
        assert.ok(typeof candidate.id === 'string' && candidate.id.length > 0);
        assert.ok(typeof candidate.token === 'string' && candidate.token.length > 0);
        assert.deepEqual(scan.warnings, []);
        selected = [{ id: candidate.id, token: candidate.token }];
        verifyCopiedData();
        return { instanceId: copiedInstance, scanId: scan.scanId, relativePath: candidate.relativePath };
    });
    await check('Actual maintenance quarantines the copy and preserves its recovery payload', async () => {
        const result = await command('applyInstanceMaintenance', {
            instanceId: copiedInstance, scanId: scan.scanId, items: selected,
        });
        assert.equal(result.success, true, JSON.stringify(result.results));
        assert.equal(result.results.length, 1);
        assert.equal(result.results[0].success, true);
        assert.equal(result.results[0].id, selected[0].id);
        assert.equal(result.results[0].action, 'quarantine');
        assert.equal(result.recoveryIds.length, 1);
        recoveryId = result.recoveryIds[0];
        assert.match(recoveryId, /^[A-Fa-f0-9-]{36}$/);
        assert.equal(result.results[0].recoveryId, recoveryId);
        assert.equal(fs.existsSync(copiedExtension), false, 'Quarantine left the copied broken extension in place');
        recoveryFolder = path.join(copiedDirectory, '.sillyclient-maintenance', 'recovery', recoveryId);
        assert.equal(digest(path.join(recoveryFolder, 'payload', 'index.js')), extensionHash,
            'Quarantined extension hash changed');
        const record = JSON.parse(fs.readFileSync(path.join(recoveryFolder, 'record.json'), 'utf8'));
        assert.equal(record.owner, 'sillyclient');
        assert.equal(record.instanceId, copiedInstance);
        assert.equal(record.recoveryId, recoveryId);
        assert.equal(record.relativePath, extensionRelative);
        assert.equal(record.phase, 'quarantined');
        recoveryRecordHash = digest(path.join(recoveryFolder, 'record.json'));
        verifyCopiedData();
        await verifyStopped();
        return { recoveryId, extensionSha256: extensionHash, sourcePreserved: true };
    });
    await check('Maintenance scan selections are single-use over the actual bridge', async () => {
        const result = await rejectedCommand('applyInstanceMaintenance', {
            instanceId: copiedInstance, scanId: scan.scanId, items: selected,
        });
        assert.equal(fs.existsSync(copiedExtension), false);
        assert.equal(digest(path.join(recoveryFolder, 'payload', 'index.js')), extensionHash);
        assert.equal(digest(path.join(recoveryFolder, 'record.json')), recoveryRecordHash);
        verifyCopiedData();
        return result;
    });
    await check('Actual recovery restores the extension and archives its record', async () => {
        const listed = await command('listInstanceMaintenanceRecovery', { instanceId: copiedInstance });
        assert.equal(listed.items.length, 1);
        assert.deepEqual(listed.warnings, []);
        const item = listed.items[0];
        assert.equal(item.recoveryId, recoveryId);
        assert.equal(item.relativePath, extensionRelative);
        assert.equal(item.canRestore, true);
        assert.ok(typeof item.token === 'string' && item.token.length > 0);
        restoreOptions = { instanceId: copiedInstance, recoveryId, token: item.token };
        const result = await command('restoreInstanceMaintenance', restoreOptions);
        assert.equal(result.success, true);
        assert.equal(result.recoveryId, recoveryId);
        assert.equal(result.relativePath, extensionRelative);
        assert.equal(digest(path.join(copiedExtension, 'index.js')), extensionHash, 'Restored extension hash changed');
        assert.equal(fs.existsSync(recoveryFolder), false, 'Restored recovery remained active');
        const history = path.join(copiedDirectory, '.sillyclient-maintenance', 'history', recoveryId, 'record.json');
        const record = JSON.parse(fs.readFileSync(history, 'utf8'));
        assert.equal(record.phase, 'restored');
        assert.equal(record.instanceId, copiedInstance);
        assert.equal(record.relativePath, extensionRelative);
        verifyCopiedData();
        await verifyStopped();
        return { recoveryId, extensionSha256: extensionHash, archived: true };
    });
    await check('Recovery tokens are single-use and migration maintenance leaves no listener', async () => {
        const rejection = await rejectedCommand('restoreInstanceMaintenance', restoreOptions);
        const listed = await command('listInstanceMaintenanceRecovery', { instanceId: copiedInstance });
        assert.deepEqual(listed.items, []);
        assert.deepEqual(listed.warnings, []);
        assert.equal(digest(path.join(copiedExtension, 'index.js')), extensionHash);
        verifyCopiedData();
        return { ...rejection, ...await verifyStopped() };
    });
    await check('Custom runtime uninstall preserves the selected root, source, and unrelated files', async () => {
        const unrelated = path.join(installationRoot, 'unrelated-user-file.txt');
        fs.writeFileSync(unrelated, 'preserved unrelated file\n');
        for (const [id, installPath] of [[copiedInstance, copiedDirectory], [instanceId, instanceDirectory]]) {
            assert.equal((await command('uninstallInstance', { instanceId: id, installPath }, 'call', 30000)).success, true);
            assert.equal(fs.existsSync(installPath), false, 'Uninstall left its registered runtime');
        }
        assert.equal(fs.statSync(installationRoot).isDirectory(), true, 'Uninstall removed the selected root');
        assert.equal(fs.readFileSync(unrelated, 'utf8'), 'preserved unrelated file\n');
        verifySource();
        const scan = await command('scanInstances');
        assert.equal(scan.instances.some(item => [copiedInstance, instanceId].includes(item.instanceId)), false,
            'Removed runtimes remained registered');
        return { selectedRootPreserved: true, sourcePreserved: true, unrelatedFilePreserved: true, ...await verifyStopped() };
    });
} catch (error) {
    if (results.every(result => result.passed)) {
        results.push({ name: 'Simulator setup or transition failed', passed: false, error: error.message });
        writeReport();
    }
    throw error;
} finally {
    const diagnosticRoots = [
        [documents, ['server-failed.json', 'server-ready.txt', 'SillyTavern/data/server.log',
            'ios-test/native-module-progress.json']],
        [container, ['status.json', 'default.log', 'default.log.1', 'runtime.log', 'runtime.log.1']
            .map(name => `Library/Application Support/SillyClient/runtime/${name}`)],
    ];
    for (const [root, relatives] of diagnosticRoots) {
        if (!root) continue;
        for (const relative of relatives) {
            try {
                const file = path.join(root, relative);
                if (fs.existsSync(file)) fs.copyFileSync(file, path.join(evidence, relative.replaceAll('/', '-')));
            } catch (error) {
                console.warn(`Diagnostic file collection failed (${relative}):`, error.message);
            }
        }
    }
    try {
        fs.writeFileSync(path.join(evidence, 'simulator-system.log'),
            simctl('spawn', device, 'log', 'show', '--predicate',
                'process == "App" OR process == "runningboardd" OR process == "ReportCrash"'
                    + ' OR process == "SpringBoard" OR process == "amfid" OR process == "securityd"', '--last', '10m'));
    } catch (error) { console.warn('System log collection failed:', error.message); }
    try {
        fs.writeFileSync(path.join(evidence, 'host-signing.log'), execFileSync('/usr/bin/log',
            ['show', '--predicate', 'eventMessage CONTAINS[c] "com.sillyclient.ios"'
                + ' OR ((process == "amfid" OR process == "kernel") AND eventMessage CONTAINS[c] "App.app")',
            '--last', '10m'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60000 }));
    } catch (error) { console.warn('Host signing log collection failed:', error.message); }
    try { simctl('terminate', device, bundleId); } catch {}
}
