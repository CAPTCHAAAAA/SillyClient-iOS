import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

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

test('unsigned artifact version and monotonic native build agree', () => {
    const plist = read('native-src/Info.plist');
    const workflow = read('.github/workflows/build-ipa.yml');
    assert.match(plist, /CFBundleShortVersionString<\/key>\s*<string>1\.10\.0<\/string>/);
    assert.match(plist, /CFBundleVersion<\/key>\s*<string>18<\/string>/);
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
