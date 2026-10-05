import assert from 'node:assert/strict';
import { pbkdf2Sync } from 'node:crypto';
import fs from 'node:fs';
import { test } from 'node:test';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('iOS password bridge exports the five Windows-compatible methods without exposing secrets', () => {
    const swift = read('native-src/TarvenEnvPlugin.swift');
    const objc = read('native-src/TarvenEnvPlugin.m');
    for (const name of ['setInstancePassword', 'verifyInstancePassword', 'hasInstancePassword',
        'clearInstancePassword', 'listInstancePasswordStatus']) {
        assert.ok(swift.includes(`"${name}"`), `Missing Swift method registration: ${name}`);
        assert.ok(swift.includes(`@objc func ${name}(`), `Missing method: ${name}`);
        assert.ok(objc.includes(`CAP_PLUGIN_METHOD(${name},`), `Missing ObjC method registration: ${name}`);
    }
    assert.doesNotMatch(swift + objc, /func getInstancePassword\(|CAP_PLUGIN_METHOD\(getInstancePassword,/);
    const locks = read('native-src/IOSInstanceAccessLock.swift');
    assert.match(locks, /SecItemCopyMatching/);
    assert.match(locks, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
    assert.match(locks, /CCKeyDerivationPBKDF/);
    assert.match(locks, /protection was not removed/);
    assert.match(locks, /difference \|= actual\[index\] \^ expected/);
    assert.doesNotMatch(locks, /print\(|UserDefaults|notifyListeners/);
});

test('Swift fixture vectors really match Windows UTF-8 textual-salt PBKDF2', () => {
    const salt = '000102030405060708090a0b0c0d0e0f';
    const vectors = [
        ['correct horse battery staple', '935e0bb26a2cc9b65bca457b4d191b151bfd3f51273cedb0f119ce9f6042c2b7'],
        ['\u9152\u9986\u5bc6\u7801\u{1f510}', '63cd9d38b1fc8e2ef9dcd4f33ff9ef597c4e6b664717699315d0ad3d8f5f3a39'],
        ['nul\0byte', 'ae33938ca85f2bb1d9ba7e2c155ddcdc5601eee479ba80cfaa5b8a909076747c'],
        ['', 'b19386ab293100d40b8839b1361bb475f750274fd7708ee38ac58a9188dbeb7a'],
    ];
    const fixtures = read('native-src/IOSInstanceAccessLockTests.swift');
    for (const [password, hash] of vectors) {
        assert.equal(pbkdf2Sync(password, salt, 10000, 32, 'sha256').toString('hex'), hash);
        assert.ok(fixtures.includes(hash));
        assert.notEqual(pbkdf2Sync(password, Buffer.from(salt, 'hex'), 10000, 32, 'sha256').toString('hex'), hash);
    }
});

test('supported iOS versions come from the prepared runtime, not unsupported upstream releases', () => {
    const swift = read('native-src/TarvenEnvPlugin.swift');
    const method = swift.slice(swift.indexOf('@objc func fetchReleases('), swift.indexOf('@objc func checkUpdate('));
    assert.match(method, /store\.supportedReleases\(\)/);
    assert.doesNotMatch(method, /releases\("SillyTavern/);
    const store = read('native-src/IOSInstanceStore.swift');
    assert.match(store, /func supportedReleases\(/);
});

test('starting remains cancellable before recovery and rechecks its operation before using recovered files', () => {
    const swift = read('native-src/TarvenEnvPlugin.swift');
    const method = swift.slice(swift.indexOf('@objc func provisionAndStart('), swift.indexOf('private func show('));
    const steps = [
        'DispatchQueue.main.async',
        'try self.reserveLocal(instance: instance, operation: operation)',
        'self.io.async',
        'try self.store.recoverRelocation(instance, operation: operation)',
        'try NodeRunner.shared.checkCurrent(instance: instance, operation: operation)',
        'let location = try self.store.location(',
        'let directory = try self.store.prepare(',
    ];
    let previous = -1;
    for (const step of steps) {
        const index = method.indexOf(step);
        assert.ok(index > previous, `Missing or out-of-order startup step: ${step}`);
        previous = index;
    }
    assert.doesNotMatch(method, /DispatchQueue\.main\.sync/);
    assert.match(method, /failProvision\(instance: instance, operation: operation, error: error\)/);
});

test('provision recovery binds its maintenance lease to one cancellable operation', () => {
    const runner = read('native-src/NodeRunner.swift');
    const recovery = runner.slice(runner.indexOf('func beginProvisionRecovery('), runner.indexOf('func beginMaintenance('));
    assert.match(recovery, /try queue\.sync/);
    assert.match(recovery, /instanceId == instance, operationId == operation, state == "provisioning", maintenance\.isEmpty/);
    assert.match(recovery, /maintenance\.insert\(instance\)/);
    assert.doesNotMatch(recovery, /recover\(|FileManager|body\(/);
    const reserve = runner.slice(runner.indexOf('func reserve('), runner.indexOf('func checkCurrent('));
    assert.match(reserve, /instanceId == nil, maintenance\.isEmpty/);
    const stop = runner.slice(runner.indexOf('public func stop('), runner.indexOf('public func triggerGarbageCollection('));
    const cancelledProvision = stop.slice(stop.indexOf('if self.state == "provisioning"'), stop.indexOf('guard self.state != "stopping"'));
    assert.match(cancelledProvision, /self\.instanceId = nil/);
    assert.match(cancelledProvision, /self\.operationId = nil/);
    assert.doesNotMatch(cancelledProvision, /maintenance\.(remove|removeAll)/);
    const journal = read('native-src/IOSRelocationJournal.swift');
    const entry = journal.slice(journal.indexOf('func recoverRelocation('));
    assert.match(entry, /beginProvisionRecovery\(instance: id, operation: operation\)/);
    assert.match(entry, /defer \{ NodeRunner\.shared\.endMaintenance\(instance: id\) \}/);
});

test('relocation recovery is durable before moving the source and does not invalidate pending backups', () => {
    const relocation = read('native-src/IOSInstanceRelocation.swift');
    const journal = read('native-src/IOSRelocationJournal.swift');
    assert.ok(relocation.indexOf('let journal = try IOSRelocationJournal') < relocation.indexOf('try source.files.move(original, to: staging'));
    assert.ok(relocation.indexOf('try journal.willWrite(configuration') < relocation.indexOf('try destination.files.write(configuration'));
    assert.match(relocation, /requireNoPendingRecovery\(original/);
    assert.match(relocation, /try journal\.recover\(\)/);
    assert.match(journal, /source\.rootIdentity == value\["sourceRootIdentity"\]/);
    assert.match(journal, /stagedIdentity == sourceIdentity/);
    assert.match(journal, /actual == expected \|\| actual == before/);
    const native = read('native-src/IOSNativeTests.swift');
    assert.match(native, /IOSRelocationJournalTests\.run/);
    assert.match(native, /IOSInstanceAccessLockTests\.runKeychain/);
});

test('deletion persists a retryable identity before touching files and removes registration last', () => {
    const store = read('native-src/IOSInstanceStore.swift');
    const removal = store.slice(store.indexOf('func uninstall('));
    assert.ok(removal.indexOf('record["removalPending"] = true') < removal.indexOf('try fm.removeItem(at: checked)'));
    const finalCommit = removal.slice(removal.indexOf('try fm.removeItem(at: checked)'));
    assert.ok(finalCommit.indexOf('guard errno == ENOENT') < finalCommit.indexOf('records.removeValue(forKey: id)'));
    assert.doesNotMatch(removal, /sillyclient-removed/);
    assert.match(read('native-src/IOSNativeTests.swift'), /IOSInstanceDeletionTests\.run/);
});

test('uninstall clears only the canonical returned identity and preserves locks when it is missing', () => {
    const store = read('native-src/IOSInstanceStore.swift');
    const removal = store.slice(store.indexOf('func uninstall('));
    const successReturns = [...removal.matchAll(/return \["success": true[^\n]+/g)];
    assert.equal(successReturns.length, 2);
    for (const [statement] of successReturns) assert.match(statement, /"instanceId": id/);
    const swift = read('native-src/TarvenEnvPlugin.swift');
    const methodStart = swift.indexOf('@objc func uninstallInstance(');
    const method = swift.slice(methodStart, swift.indexOf('\n    @objc func ', methodStart + 1));
    assert.match(method, /guard let removedId = result\["instanceId"\] as\? String else \{\s*result\["warning"\] = "[^"]*access locks were preserved"\s*return result\s*\}/);
    const cleanups = [...method.matchAll(/IOSInstanceAccessLock\.shared\.remove\(instanceId: (\w+)\)/g)];
    assert.deepEqual(cleanups.map(([, id]) => id), ['removedId']);
    const fixtures = read('native-src/IOSInstanceDeletionTests.swift');
    assert.match(fixtures, /takeoverResult\["instanceId"\] as\? String == "scan-kept"/);
    assert.match(fixtures, /aliasResult\["instanceId"\] as\? String == "kept"/);
});
