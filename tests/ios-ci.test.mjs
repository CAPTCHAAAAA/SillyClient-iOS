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

test('copy migration is explicitly whitelisted only in the Debug test harness', () => {
    const harness = read('native-src/IOSDebugHarness.swift');
    assert.match(harness, /^#if DEBUG[\s\S]*#endif\s*$/);
    const whitelist = harness.match(/methods: Set<String> = \[([\s\S]*?)\]/)?.[1];
    assert.ok(whitelist);
    const methods = [...whitelist.matchAll(/"([^"]+)"/g)].map(match => match[1]);
    assert.equal(methods.filter(method => method === 'migrateInstance').length, 1);
    assert.match(harness, /guard let method = request\["method"\] as\? String, methods\.contains\(method\)/);
});

test('Debug native fixtures retain current progress and per-group timing on timeout', () => {
    const harness = read('native-src/IOSDebugHarness.swift');
    const fixtures = read('native-src/IOSNativeTests.swift');
    const runner = read('scripts/run-ios-e2e.mjs');
    assert.match(fixtures, /static func run\(progress: \(\(\[String: Any\]\) -> Void\)\? = nil\)/);
    assert.match(fixtures, /"currentGroup": name/);
    assert.match(fixtures, /"completedGroups": results\.count/);
    assert.match(fixtures, /"elapsedMs"/);
    assert.match(fixtures, /autoreleasepool \{/);
    assert.match(harness, /IOSNativeTests\.run \{[\s\S]*"requestId"[\s\S]*native-module-progress\.json/);
    assert.match(runner, /progress\.requestId === id/);
    assert.match(runner, /ios-test\/native-module-progress\.json/);
    assert.match(runner, /'nativeTests', 180000/);
});

test('native bridge initialization disables framework payload logging in every configuration', () => {
    const delegate = read('native-src/AppDelegate.swift');
    const bridge = delegate.slice(delegate.indexOf('class SillyBridgeViewController'),
        delegate.indexOf('@UIApplicationMain'));
    const descriptor = bridge.match(/override func instanceDescriptor\(\) -> InstanceDescriptor \{([\s\S]*?)\n    \}/)?.[1];
    assert.ok(descriptor, 'The native bridge does not override its early configuration');
    assert.match(descriptor, /let descriptor = super\.instanceDescriptor\(\)/);
    assert.match(descriptor, /descriptor\.loggingBehavior = \.none[\s\S]*return descriptor/);
    assert.doesNotMatch(descriptor, /#if DEBUG/);
    const harness = read('native-src/IOSDebugHarness.swift');
    assert.match(harness, /request\["action"\] as\? String == "console"[\s\S]*window\.Capacitor\?\.isLoggingEnabled/);
    const runner = read('scripts/run-ios-e2e.mjs');
    assert.match(runner, /assert\.equal\(consoleStatus\.loggingEnabled, false/);
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

test('only the Debug simulator is ad-hoc signed without protected application claims', () => {
    const workflow = read('.github/workflows/build-ipa.yml');
    const simulator = workflow.slice(workflow.indexOf('- name: Build and verify the actual hosted simulator application'),
        workflow.indexOf('- name: Upload the unsigned build archive'));
    const archive = workflow.slice(workflow.indexOf('- name: Archive the unsigned physical-device binary'),
        workflow.indexOf('- name: Build and verify the actual hosted simulator application'));
    assert.match(archive, /CODE_SIGNING_ALLOWED=NO/);
    assert.doesNotMatch(archive, /codesign --force|ios-simulator\.entitlements/);
    assert.match(simulator, /Debug-iphonesimulator\/App\.app/);
    assert.match(simulator, /codesign --force --sign - "\$APP_PATH"/);
    for (const command of simulator.split('\n').filter(line => /codesign --force/.test(line))) {
        assert.doesNotMatch(command, /--entitlements|--deep|--preserve-metadata/);
    }
    assert.match(simulator, /for COMPONENT in "\$APP_PATH"\/Frameworks\/\*\.framework "\$APP_PATH"\/Frameworks\/\*\.dylib/);
    assert.match(simulator, /codesign --force --sign - "\$COMPONENT"/);
    assert.match(simulator, /codesign --display --verbose=4 "\$APP_PATH"/);
    assert.match(simulator, /codesign --verify --deep --strict/);
    assert.ok(simulator.indexOf('codesign --force') > simulator.indexOf('cp -R sillytavern-src'));
    assert.ok(simulator.indexOf('codesign --force --sign - "$COMPONENT"')
        < simulator.indexOf('codesign --force --sign - "$APP_PATH"'));
    assert.ok(simulator.indexOf('codesign --force --sign - "$APP_PATH"')
        < simulator.indexOf('codesign --display --verbose=4'));
    assert.ok(simulator.indexOf('codesign --verify') < simulator.indexOf('node scripts/run-ios-e2e.mjs'));
    const entitlements = read('scripts/ios-simulator.entitlements');
    assert.match(entitlements, /application-identifier<\/key>\s*<string>SCIOSDEBUG\.com\.sillyclient\.ios/);
    assert.match(entitlements, /keychain-access-groups<\/key>\s*<array>\s*<string>SCIOSDEBUG\.com\.sillyclient\.ios/);
    assert.doesNotMatch(entitlements, /get-task-allow|application-groups/);
});

test('only the App Debug simulator links the test identity into its Mach-O', () => {
    const workflow = read('.github/workflows/build-ipa.yml');
    const simulator = workflow.slice(workflow.indexOf('- name: Build and verify the actual hosted simulator application'),
        workflow.indexOf('- name: Upload the unsigned build archive'));
    const configure = simulator.match(/ruby <<'RUBY'\n([\s\S]*?)\n\s*RUBY/)?.[1];
    assert.ok(configure, 'Missing structured Xcode simulator configuration');
    assert.match(configure, /require 'xcodeproj'/);
    assert.match(configure, /Xcodeproj::Project\.open\('web\/capacitor-ui\/ios\/App\/App\.xcodeproj'\)/);
    assert.match(configure, /project\.targets\.select \{ \|target\| target\.name == 'App' \}/);
    assert.match(configure, /targets\.length == 1/);
    assert.match(configure, /targets\.first\.build_configurations\.select \{ \|config\| config\.name == 'Debug' \}/);
    assert.match(configure, /configurations\.length == 1/);
    assert.match(configure, /configurations\.first\.build_settings/);
    assert.match(configure, /OTHER_LDFLAGS\[sdk=iphonesimulator\*\]/);
    assert.match(configure, /Shellwords\.split/);
    assert.match(configure, /flags\.unshift\('\$\(inherited\)'\)/);
    assert.match(configure, /-Wl,-sectcreate,__TEXT,__entitlements,/);
    assert.match(configure, /File\.expand_path\('scripts\/ios-simulator\.entitlements'\)/);
    assert.match(configure, /flags << linker_flag unless flags\.include\?\(linker_flag\)/);
    assert.match(configure, /settings\[key\] = flags[\s\S]*project\.save/);
    assert.doesNotMatch(configure, /project\.build_configurations|settings\['OTHER_LDFLAGS'\]\s*=/);
    assert.ok(simulator.indexOf("ruby <<'RUBY'") < simulator.indexOf('xcodebuild -workspace'));
    assert.match(simulator, /build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""/);
});

test('simulator evidence validates the linked plist identity before launch', () => {
    const workflow = read('.github/workflows/build-ipa.yml');
    const simulator = workflow.slice(workflow.indexOf('- name: Build and verify the actual hosted simulator application'),
        workflow.indexOf('- name: Upload the unsigned build archive'));
    assert.match(simulator, /xcrun otool-classic -arch "\$\(uname -m\)" -X -V -s __TEXT __entitlements "\$APP_PATH\/App"/);
    assert.match(simulator, /evidence\/simulator-entitlements-macho\.txt/);
    const validate = simulator.match(/ruby <<'VERIFY'\n([\s\S]*?)\n\s*VERIFY/)?.[1];
    assert.ok(validate, 'Missing semantic validation of linked simulator entitlements');
    assert.match(validate, /Xcodeproj::Plist\.read_from_path\('evidence\/simulator-entitlements\.plist'\)/);
    assert.match(validate, /linked\['application-identifier'\] == identity/);
    assert.match(validate, /linked\['keychain-access-groups'\] == \[identity\]/);
    assert.match(validate, /linked == expected/);
    assert.ok(simulator.indexOf("ruby <<'VERIFY'") < simulator.indexOf('node scripts/run-ios-e2e.mjs'));
});

function decodeLinkedEntitlements(dump) {
    const workflow = read('.github/workflows/build-ipa.yml');
    const decoder = workflow.match(/node --input-type=module <<'ENTITLEMENTS'\n([\s\S]*?)\n\s*ENTITLEMENTS/)?.[1];
    assert.ok(decoder, 'Missing linked-entitlement evidence decoder');
    const body = decoder.replace(/^\s*import [^\n]+\n/gm, '');
    let linked;
    vm.runInNewContext(body, {
        assert, Buffer, BigInt,
        fs: {
            readFileSync(file, encoding) {
                assert.equal(file, 'evidence/simulator-entitlements-macho.txt');
                assert.equal(encoding, 'utf8');
                return dump;
            },
            writeFileSync(file, bytes) {
                assert.equal(file, 'evidence/simulator-entitlements.plist');
                assert.ok(Buffer.isBuffer(bytes));
                linked = bytes;
            },
        },
    }, { timeout: 1000 });
    return linked;
}

function sectionDump(bytes) {
    const rows = [];
    for (let offset = 0; offset < bytes.length; offset += 16) {
        const row = bytes.subarray(offset, offset + 16);
        const address = (0x1000 + offset).toString(16).padStart(16, '0');
        rows.push(`${address}  ${[...row].map(byte => byte.toString(16).padStart(2, '0')).join(' ')}  |fixture|`);
    }
    return rows.join('\n') + '\n';
}

test('linked simulator entitlement evidence preserves the actual bytes', () => {
    const expected = Buffer.from(read('scripts/ios-simulator.entitlements'));
    assert.deepEqual(decodeLinkedEntitlements(sectionDump(expected)), expected);
});

for (const [name, dump, message] of [
    ['missing section', '', /No linked simulator entitlement bytes/],
    ['non-byte row', '0000000000001000  zz  |fixture|\n', /Invalid simulator entitlement byte row/],
    ['discontinuous rows', '0000000000001000  3c  |fixture|\n0000000000001010  3e  |fixture|\n',
        /Noncontiguous simulator entitlement byte rows/],
]) {
    test(`linked simulator entitlement evidence rejects ${name}`, () => {
        assert.throws(() => decodeLinkedEntitlements(dump), message);
    });
}

test('maintenance expiration preserves live scan and recovery tokens at capacity', () => {
    const maintenance = read('native-src/IOSInstanceMaintenance.swift');
    const expire = maintenance.slice(maintenance.indexOf('private func expire()'),
        maintenance.indexOf('private func validSegment'));
    assert.match(expire, /scans = scans\.filter \{ \$0\.value\.expires > now\(\) \}/);
    assert.match(expire, /restores = restores\.filter \{ \$0\.value\.expires > now\(\) \}/);
    assert.doesNotMatch(expire, /removeAll|\.count/);
});

test('maintenance limits token issuance without invalidating another live plan', () => {
    const maintenance = read('native-src/IOSInstanceMaintenance.swift');
    const scan = maintenance.slice(maintenance.indexOf('func scan('), maintenance.indexOf('func apply('));
    assert.match(scan, /scans = scans\.filter \{ \$0\.value\.instance != id \}/);
    assert.match(scan, /guard scans\.count < 16 else/);
    assert.ok(scan.indexOf('guard scans.count < 16') < scan.indexOf('scans[scanId] = plan'));
    const list = maintenance.slice(maintenance.indexOf('func list('), maintenance.indexOf('func restore('));
    assert.match(list, /guard restores\.count < 256 else/);
    assert.ok(list.indexOf('guard restores.count < 256') < list.indexOf('restores[token] = RestorePlan'));
    assert.doesNotMatch(list, /restores\.removeAll/);
});

test('maintenance rejects terminal line controls before taking a recoverable snapshot', () => {
    const maintenance = read('native-src/IOSInstanceMaintenance.swift');
    const segment = maintenance.slice(maintenance.indexOf('private func validSegment'),
        maintenance.indexOf('private func config'));
    assert.ok(segment.includes('[A-Za-z0-9_.-]{1,160}\\\\z'));
    const add = maintenance.slice(maintenance.indexOf('func add('), maintenance.indexOf('for user in'));
    assert.ok(add.indexOf('try IOSSafeArchive.relativePath(relative)') >= 0);
    assert.ok(add.indexOf('try IOSSafeArchive.relativePath(relative)') < add.indexOf('try files.snapshot'));
});

test('copy migration routes flat user data to the actual default-user directory', () => {
    const store = read('native-src/IOSInstanceStore.swift');
    const destination = store.slice(store.indexOf('func migrationDataTarget('), store.indexOf('func migrate('));
    assert.match(destination, /singleUser \? dataRoot\.appendingPathComponent\("default-user"\) : dataRoot/);
    assert.match(destination, /guard !singleUser \|\| !nestedUsers else/);
    const migrate = store.slice(store.indexOf('func migrate('), store.indexOf('func uninstall('));
    assert.match(migrate, /copyTarget = try migrationDataTarget\(dataSource, files: dataFiles, dataRoot: dataTarget\)/);
    assert.match(migrate, /dataFiles\.copyTree\(dataSource, to: copyTarget, destination: files/);
});

test('native adapter preserves the existing console events and checks mode freshness on main', () => {
    const plugin = read('native-src/TarvenEnvPlugin.swift');
    const events = read('native-src/IOSRuntimeEvents.swift');
    const load = plugin.slice(plugin.indexOf('public override func load()'), plugin.indexOf('private func perform'));
    assert.match(load, /IOSRuntimeEvents\.log\(instance: id, operation: operation, line: line\)/);
    assert.match(load, /DispatchQueue\.main\.async[\s\S]*IOSRuntimeEvents\.mode\(state, current: NodeRunner\.shared\.status/);
    assert.match(load, /remoteActive: self\.viewSession\?\.2 == true \|\| self\.pendingViewSession\?\.2 == true/);
    assert.match(events, /"message": line/);
    assert.match(events, /value\["mode"\] = "launcher"/);
    assert.match(events, /value\["tavernRunning"\] = event\["serverReady"\]/);
    assert.match(plugin, /appendLog\(message, instance: current\["instanceId"\][\s\S]*operation: current\["operationId"\]/);
});

test('same-URL view reuse refreshes application credentials and matched clears happen on main', () => {
    const controller = read('native-src/TavernViewController.swift');
    const enter = controller.slice(controller.indexOf('public func enterImmersive'), controller.indexOf('public func exitImmersive'));
    assert.ok(enter.indexOf('updateRemoteCredentials(url: url, username: username, password: password)')
        < enter.indexOf('let isAlreadyOnUrl'));
    assert.match(enter, /if isAlreadyOnUrl[\s\S]*else if !isAlreadyLoadingSameUrl/);
    const plugin = read('native-src/TarvenEnvPlugin.swift');
    const clear = plugin.slice(plugin.indexOf('@objc func clearRemoteBasicAuth'), plugin.indexOf('@objc func pingUrl'));
    assert.match(clear, /try IOSRemoteCredentials\.clear\(instance\)[\s\S]*DispatchQueue\.main\.async/);
    assert.match(clear, /current\.2, current\.0 == instance[\s\S]*clearRemoteCredentials\(\)[\s\S]*call\.resolve/);
    const show = plugin.slice(plugin.indexOf('private func show('), plugin.indexOf('private func completeView'));
    const browser = show.slice(show.indexOf('UIApplication.shared.open'), show.indexOf('let auth = remote'));
    assert.match(browser, /guard self\.viewGeneration == generation[\s\S]*guard opened[\s\S]*clearTavernSession\(\)[\s\S]*self\.viewSession =/);
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
    const mkdir = file => {
        let directory = key(file);
        while (!directories.has(directory)) {
            directories.add(directory);
            const parent = path.dirname(directory);
            if (parent === directory) break;
            directory = parent;
        }
    };
    const put = (file, value) => {
        mkdir(path.dirname(file));
        files.set(key(file), Buffer.isBuffer(value) ? value : Buffer.from(value));
    };
    const missing = () => Object.assign(new Error('Virtual file not found'), { code: 'ENOENT' });
    const get = file => {
        if (!files.has(key(file))) throw missing();
        return files.get(key(file));
    };
    const moveTree = (source, destination) => {
        const prefix = key(source);
        const target = key(destination);
        const contains = file => file === prefix || file.startsWith(prefix + path.sep);
        const movedFiles = [...files].filter(([file]) => contains(file));
        const movedDirectories = [...directories].filter(contains);
        assert.ok(movedDirectories.length > 0, 'Virtual native move source is missing');
        for (const [file, value] of movedFiles) {
            put(target + file.slice(prefix.length), value);
            files.delete(file);
        }
        for (const directory of movedDirectories) {
            mkdir(target + directory.slice(prefix.length));
            directories.delete(directory);
        }
    };
    const asset = Buffer.from('verified virtual frontend');
    const loader = 'virtual current loader';
    const runtime = path.join(application, 'sillytavern');
    mkdir(path.join(runtime, 'node_modules'));
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
    const registry = {};
    let migrated;
    let maintenance;
    const respond = request => {
        if (request.action === 'console') {
            return { success: true, result: { loggingEnabled: scenario === 'bridge-payload-logging-enabled' } };
        }
        if (request.action === 'nativeTests') {
            if (['native-fixture-timeout', 'stale-native-fixture-progress'].includes(scenario)) {
                put(path.join(documents, 'ios-test/native-module-progress.json'), JSON.stringify({
                    requestId: scenario === 'stale-native-fixture-progress' ? 'previous-request' : request.id,
                    currentGroup: 'Virtual stalled group', completedGroups: 21,
                    results: Array.from({ length: 21 }, (_, index) =>
                        ({ name: `Virtual group ${index}`, passed: true, elapsedMs: index })),
                }));
                return undefined;
            }
            return { success: true, result: { success: true,
                results: Array.from({ length: 27 }, (_, index) => ({ name: `Virtual group ${index}`, passed: true })) } };
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
            const server = path.join(documents, 'SillyTavern');
            mkdir(server);
            if (!registry[options.instanceId]) {
                registry[options.instanceId] = { instanceId: options.instanceId, path: server, isTakeover: false };
                put(path.join(documents, 'instances-registry.json'), JSON.stringify(registry));
            }
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
        case 'migrateInstance': {
            assert.equal(active, undefined, 'Driver migrated before stopping its local session');
            assert.equal(options.mode, 'copy');
            assert.equal(options.includeSecrets, false);
            assert.ok(options.instanceId && options.instanceId !== 'default' && options.operationId);
            const target = path.join(documents, 'instances', options.instanceId);
            const sourceData = path.join(options.sourcePath, 'selected-data');
            for (const [file, value] of [...files]) {
                if (file.startsWith(key(runtime) + path.sep)) {
                    put(path.join(target, path.relative(runtime, file)), value);
                } else if (file.startsWith(key(sourceData) + path.sep)) {
                    const relative = path.relative(sourceData, file);
                    if (!relative.split(path.sep).some(part =>
                        ['.git', 'node_modules', 'secrets.json', 'secrets.json.enc'].includes(part))) {
                        put(path.join(target, 'data', relative), value);
                    }
                }
            }
            mkdir(path.join(target, 'node_modules'));
            migrated = { instanceId: options.instanceId, target, source: options.sourcePath };
            registry[options.instanceId] = { instanceId: options.instanceId, path: target, isTakeover: false };
            if (scenario === 'migration-registry-mismatch') registry[options.instanceId].path = path.join(documents, 'wrong-target');
            put(path.join(documents, 'instances-registry.json'), JSON.stringify(registry));
            if (scenario === 'migration-source-changed') put(path.join(options.sourcePath, 'config.yaml'), 'changed source\n');
            if (scenario === 'migration-excluded-data') {
                put(path.join(target, 'data/default-user/secrets.json'), get(path.join(sourceData, 'default-user/secrets.json')));
            }
            if (scenario === 'migration-auto-start') {
                active = { instanceId: options.instanceId, operationId: options.operationId };
                state = 'ready';
                listening = true;
            }
            return success({ success: true, instanceId: options.instanceId, targetPath: target });
        }
        case 'scanInstanceMaintenance':
            assert.equal(options.instanceId, migrated.instanceId);
            maintenance = { scanId: 'virtual-scan', candidateId: 'virtual-candidate', candidateToken: 'virtual-selection-token',
                relative: 'data/default-user/extensions/broken-bridge-fixture',
                recoveryId: '00000000-0000-4000-8000-000000000001', applied: false, restored: false };
            return success({ instanceId: migrated.instanceId, scanId: maintenance.scanId, warnings: [],
                items: [{ id: maintenance.candidateId, token: maintenance.candidateToken, kind: 'broken_extension',
                    action: 'quarantine', relativePath: maintenance.relative }] });
        case 'applyInstanceMaintenance': {
            assert.equal(options.instanceId, migrated.instanceId);
            if (maintenance.applied) {
                if (scenario === 'maintenance-scan-reused') return success({ success: true });
                return reject('Maintenance scan expired or was already used');
            }
            assert.equal(options.scanId, maintenance.scanId);
            assert.deepEqual(options.items, [{ id: maintenance.candidateId, token: maintenance.candidateToken }]);
            const original = path.join(migrated.target, maintenance.relative);
            maintenance.folder = path.join(migrated.target, '.sillyclient-maintenance/recovery', maintenance.recoveryId);
            moveTree(original, path.join(maintenance.folder, 'payload'));
            put(path.join(maintenance.folder, 'record.json'), JSON.stringify({
                revision: 1, owner: 'sillyclient', instanceId: migrated.instanceId, recoveryId: maintenance.recoveryId,
                relativePath: maintenance.relative, kind: 'broken_extension', action: 'quarantine', phase: 'quarantined',
            }));
            if (scenario === 'maintenance-payload-corrupted') put(path.join(maintenance.folder, 'payload/index.js'), 'corrupted payload\n');
            maintenance.applied = true;
            return success({ success: true, recoveryIds: [maintenance.recoveryId],
                results: [{ id: maintenance.candidateId, success: true, action: 'quarantine', recoveryId: maintenance.recoveryId }] });
        }
        case 'listInstanceMaintenanceRecovery':
            assert.equal(options.instanceId, migrated.instanceId);
            if (maintenance.restored) return success({ items: [], warnings: [] });
            maintenance.restoreToken = 'virtual-restore-token';
            return success({ warnings: [], items: [{ recoveryId: maintenance.recoveryId, relativePath: maintenance.relative,
                canRestore: true, token: maintenance.restoreToken }] });
        case 'restoreInstanceMaintenance': {
            assert.equal(options.instanceId, migrated.instanceId);
            if (maintenance.restored) {
                if (scenario === 'maintenance-token-reused') return success({ success: true });
                return reject('Recovery token expired or was already used');
            }
            assert.equal(options.recoveryId, maintenance.recoveryId);
            assert.equal(options.token, maintenance.restoreToken);
            const restored = path.join(migrated.target, maintenance.relative);
            moveTree(path.join(maintenance.folder, 'payload'), restored);
            if (scenario === 'maintenance-restore-corrupted') put(path.join(restored, 'index.js'), 'corrupted restore\n');
            const record = JSON.parse(get(path.join(maintenance.folder, 'record.json')).toString());
            record.phase = 'restored';
            put(path.join(maintenance.folder, 'record.json'), JSON.stringify(record));
            moveTree(maintenance.folder, path.join(migrated.target, '.sillyclient-maintenance/history', maintenance.recoveryId));
            maintenance.restored = true;
            return success({ success: true, recoveryId: maintenance.recoveryId, relativePath: maintenance.relative });
        }
        default: throw new Error(`Unexpected virtual native method: ${request.method}`);
        }
    };
    const fakeFs = {
        mkdirSync(file) { mkdir(file); },
        existsSync(file) { return files.has(key(file)) || directories.has(key(file)); },
        readFileSync(file, encoding) { const value = get(file); return encoding ? value.toString(encoding) : value; },
        writeFileSync(file, value) { put(file, value); },
        statSync(file) {
            const directory = directories.has(key(file));
            return { size: directory ? 0 : get(file).length, isFile: () => !directory, isDirectory: () => directory };
        },
        realpathSync(file) {
            if (!files.has(key(file)) && !directories.has(key(file))) throw missing();
            return key(file);
        },
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
        if (binary === '/usr/bin/log') {
            assert.equal(args[0], 'show');
            assert.ok(args.includes('--predicate'));
            return 'Virtual host signing diagnostic log\n';
        }
        assert.equal(binary, 'xcrun');
        assert.equal(args[0], 'simctl');
        const action = args[1];
        if (action === 'install' && scenario === 'install-denied') throw new Error('Simulator installation denied');
        if (['boot', 'bootstatus', 'install'].includes(action)) return '';
        if (action === 'get_app_container') return container + '\n';
        if (action === 'terminate') { alive = false; return ''; }
        if (action === 'spawn') return 'Virtual simulator diagnostic log\n';
        assert.equal(action, 'launch');
        if (scenario === 'probe-launch-denied' && args.includes('--sillyclient-runtime-probe')) {
            throw new Error('Capability probe launch denied by codesigning');
        }
        if (scenario === 'test-launch-denied' && args.includes('--sillyclient-test')) {
            throw new Error('Test application launch denied by codesigning');
        }
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
    const hostDiagnostics = get(path.join(evidence, 'host-signing.log')).toString();
    const nativeProgress = files.get(key(path.join(evidence, 'ios-test-native-module-progress.json')));
    return { report, error, clock, acceptedStops, listening, hostDiagnostics,
        nativeProgress: nativeProgress && JSON.parse(nativeProgress.toString()) };
}

test('real simulator driver completes all lifecycle stages using isolated protocol fixtures', async () => {
    const actual = await simulateDriver();
    assert.equal(actual.error, undefined, actual.error?.message);
    assert.equal(actual.report.results.length, 22);
    assert.ok(actual.report.results.every(result => result.passed));
    assert.equal(actual.report.results.find(result => result.name.includes('native filesystem')).actual.groups, 27);
    assert.equal(actual.report.results.find(result => result.name.includes('Real Capacitor')).actual.loggingEnabled, false);
    const remoteRejection = actual.report.results.find(result => result.name.includes('Remote navigation')).actual;
    assert.equal(remoteRejection.rejected, true);
    assert.equal(remoteRejection.instanceId, 'default');
    assert.ok(remoteRejection.homepageBytes > 0);
    const copy = actual.report.results.find(result => result.name.includes('Actual copy migration')).actual;
    assert.ok(copy.instanceId.startsWith('simulator-copy-'));
    assert.match(copy.chatSha256, /^[0-9a-f]{64}$/);
    assert.equal(copy.verifiedSourceFiles, 11);
    assert.equal(copy.portClosedAfterStop, true);
    assert.equal(actual.report.results.at(-1).actual.portClosedAfterStop, true);
    assert.equal(actual.acceptedStops, 2);
    assert.equal(actual.listening, false);
    assert.equal(actual.report.physicalDeviceTested, false);
    assert.equal(actual.report.visualReviewPerformed, false);
    assert.match(actual.hostDiagnostics, /Virtual host signing diagnostic log/);
});

test('simulator native fixture timeout retains the current group and completed timings', async () => {
    const actual = await simulateDriver('native-fixture-timeout');
    assert.match(actual.error?.message, /Timed out waiting.*Virtual stalled group.*21 completed/);
    assert.equal(actual.nativeProgress.currentGroup, 'Virtual stalled group');
    assert.equal(actual.nativeProgress.results.length, 21);
    assert.equal(actual.report.results.length, 4);
    assert.equal(actual.report.results.at(-1).passed, false);
});

test('simulator native fixture timeout does not attach another request progress', async () => {
    const actual = await simulateDriver('stale-native-fixture-progress');
    assert.match(actual.error?.message, /Timed out waiting/);
    assert.doesNotMatch(actual.error?.message, /Virtual stalled group|21 completed/);
    assert.equal(actual.nativeProgress.requestId, 'previous-request');
    assert.equal(actual.report.results.at(-1).passed, false);
});

for (const [scenario, stage, message] of [
    ['install-denied', 'Simulator setup or transition', /Simulator installation denied/],
    ['probe-launch-denied', 'Actual NodeMobile worker', /Capability probe launch denied by codesigning/],
    ['test-launch-denied', 'Real Capacitor native bridge', /Test application launch denied by codesigning/],
    ['bridge-payload-logging-enabled', 'Real Capacitor native bridge', /Capacitor payload logging must be disabled/],
    ['remote-navigation-success', 'Remote navigation', /unexpectedly accepted/],
    ['remote-navigation-replaces-operation', 'Remote navigation', /remote-hardening-operation/],
    ['listener-left-open', 'Native stop closes', /listener open/],
    ['stale-stop-success', 'stale operation stop', /unexpectedly accepted/],
    ['process-exit', 'embedded server startup', /application exited before replying/],
    ['rejection-timeout', 'stale operation stop', /Timed out waiting/],
    ['migration-source-changed', 'Actual copy migration', /Source fixture changed/],
    ['migration-excluded-data', 'Actual copy migration', /Excluded migration data was copied/],
    ['migration-registry-mismatch', 'Actual copy migration', /Migration registry path differs/],
    ['migration-auto-start', 'Actual copy migration', /listener open/],
    ['maintenance-payload-corrupted', 'maintenance quarantines', /Quarantined extension hash changed/],
    ['maintenance-scan-reused', 'scan selections are single-use', /unexpectedly accepted/],
    ['maintenance-restore-corrupted', 'recovery restores', /Restored extension hash changed/],
    ['maintenance-token-reused', 'Recovery tokens are single-use', /unexpectedly accepted/],
]) {
    test(`simulator driver fails instead of reporting success: ${scenario}`, async () => {
        const actual = await simulateDriver(scenario);
        assert.ok(actual.error, 'Invalid native behavior was accepted');
        assert.match(actual.error.message, message);
        const failed = actual.report.results.filter(result => !result.passed);
        assert.equal(failed.length, 1);
        assert.ok(failed[0].name.includes(stage), failed[0].name);
        assert.match(actual.hostDiagnostics, /Virtual host signing diagnostic log/);
        if (scenario === 'process-exit') assert.ok(actual.clock < 1000, 'Application exit waited for the startup deadline');
    });
}
