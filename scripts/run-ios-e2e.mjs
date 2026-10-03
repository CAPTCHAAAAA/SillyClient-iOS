import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const [device, appPath] = process.argv.slice(2);
assert.ok(device && appPath, 'Simulator UUID and built application path are required');
const bundleId = 'com.sillyclient.ios';
const evidence = path.resolve('evidence');
fs.mkdirSync(evidence, { recursive: true });
const results = [];
let documents;
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 120000,
});
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function waitForFile(file, timeout = 10000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
        await sleep(100);
    }
    throw new Error(`Timed out waiting for ${path.basename(file)}`);
}

async function command(method, options = {}, action = 'call', timeout = 10000) {
    const id = randomUUID();
    const directory = path.join(documents, 'ios-test');
    fs.mkdirSync(directory, { recursive: true });
    const temporary = path.join(directory, 'request.tmp');
    fs.writeFileSync(temporary, JSON.stringify({ id, action, method, options }));
    fs.renameSync(temporary, path.join(directory, 'request.json'));
    const response = await waitForFile(path.join(directory, `${id}.json`), timeout);
    if (!response.success) throw new Error(response.error || `${method} rejected`);
    return response.result;
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
        fs.writeFileSync(path.join(evidence, 'simulator-results.json'), JSON.stringify({
            platform: 'GitHub-hosted iOS simulator', device, results,
            physicalDeviceTested: false, paidApiTested: false, visualReviewPerformed: false,
        }, null, 2));
    }
}

function get(url) {
    return new Promise((resolve, reject) => {
        const request = http.get(url, response => {
            const chunks = [];
            response.on('data', chunk => chunks.push(chunk));
            response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks) }));
        });
        request.once('error', reject);
        request.setTimeout(3000, () => request.destroy(new Error('HTTP response timed out')));
    });
}

try {
    try { simctl('boot', device); } catch {}
    simctl('bootstatus', device, '-b');
    simctl('install', device, appPath);
    documents = path.join(simctl('get_app_container', device, bundleId, 'data').trim(), 'Documents');
    simctl('launch', device, bundleId, '--sillyclient-runtime-probe');
    await check('Actual NodeMobile worker HTTP, termination, and restart capability', async () => {
        const result = await waitForFile(path.join(documents, 'ios-test', 'runtime-probe.json'), 45000);
        fs.writeFileSync(path.join(evidence, 'node-mobile-runtime-probe.json'), JSON.stringify(result, null, 2));
        assert.equal(result.success, true, result.error);
        assert.equal(result.cycles.length, 2);
        assert.ok(result.cycles.every(cycle => cycle.httpStatus === 200 && cycle.portClosedAfterTermination));
        return result;
    });
    simctl('terminate', device, bundleId);
    simctl('launch', device, bundleId, '--sillyclient-test');
    await sleep(5000);
    await check('Real Capacitor native bridge and application version', async () => {
        assert.equal((await command('getPlatform')).platform, 'ios');
        const version = await command('getAppVersion');
        assert.equal(version.version, '1.10.0');
        return version;
    });
    await check('Actual native filesystem, URL policy, and archive module regressions', async () => {
        const result = await command(undefined, {}, 'nativeTests', 30000);
        fs.writeFileSync(path.join(evidence, 'native-module-results.json'), JSON.stringify(result, null, 2));
        assert.equal(result.success, true, JSON.stringify(result.results.filter(item => !item.passed)));
        return result;
    });
    await check('Real embedded server startup through the native plugin', async () => {
        const result = await command('provisionAndStart', { instanceId: 'default', port: 8000 }, 'call', 100000);
        assert.equal(result.ready, true);
        const response = await get('http://127.0.0.1:8000/');
        assert.equal(response.status, 200);
        assert.ok(response.body.includes(Buffer.from('SillyTavern')));
        return { ready: result.ready, homepageBytes: response.body.length };
    });
    await check('Served frontend bytes match the build-time manifest', async () => {
        const manifest = JSON.parse(fs.readFileSync(path.join(appPath, 'sillytavern', 'dist', 'ios-frontend', 'manifest.json')));
        const asset = manifest.assets.find(item => item.name === 'lib.js');
        assert.ok(asset);
        const response = await get('http://127.0.0.1:8000/lib.js');
        assert.equal(response.status, 200);
        assert.equal(createHash('sha256').update(response.body).digest('hex'), asset.sha256);
        return { bytes: response.body.length, sha256: asset.sha256 };
    });
    await check('Real Tavern WebView loads the embedded server DOM', async () => {
        await command('enterImmersive', { instanceId: 'default', url: 'http://127.0.0.1:8000/' });
        const deadline = Date.now() + 30000;
        let actual;
        while (Date.now() < deadline) {
            actual = await command(undefined, {}, 'tavern');
            if (actual?.hasChat && actual?.hasInput && actual?.hasClient && actual.ready === 'complete') break;
            await sleep(300);
        }
        assert.ok(actual?.hasChat && actual?.hasInput && actual?.hasClient && actual.ready === 'complete',
            'Real Tavern JavaScript and DOM did not become ready');
        assert.ok(actual.url.startsWith('http://127.0.0.1:8000/'));
        return actual;
    });
} finally {
    if (documents) {
        for (const relative of ['server-failed.json', 'server-ready.txt', 'SillyTavern/data/server.log']) {
            const file = path.join(documents, relative);
            if (fs.existsSync(file)) fs.copyFileSync(file, path.join(evidence, relative.replaceAll('/', '-')));
        }
    }
    try {
        fs.writeFileSync(path.join(evidence, 'simulator-system.log'),
            simctl('spawn', device, 'log', 'show', '--predicate', 'processImagePath contains "App"', '--last', '5m'));
    } catch (error) { console.warn('System log collection failed:', error.message); }
    try { simctl('terminate', device, bundleId); } catch {}
}
