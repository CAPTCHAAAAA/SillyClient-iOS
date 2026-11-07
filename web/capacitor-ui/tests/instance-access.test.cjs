const assert = require("node:assert/strict");
const path = require("node:path");
const { test } = require("node:test");
const { loadSource } = require("./load-source.cjs");
const { preview } = require("./load-native-preview.cjs");

const { InstanceAccessScope, instanceAccessIdentity, instanceAccessTarget,
  readInstancePasswordStatus, requireUnlockedRemoteDeletion } = loadSource(path.join(__dirname, "../src/lib/instance-access.ts"));
const plain = value => JSON.parse(JSON.stringify(value));
const instance = { id: "card-a", installDir: "native-a", type: "local", installPath: "/Documents/a", url: "" };
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

test("native password lookup uses stable installation identity regardless of display label", async () => {
  let options;
  assert.equal(instanceAccessIdentity(instance), "native-a");
  assert.equal(instanceAccessIdentity({ ...instance, installDir: undefined }), "card-a");
  assert.equal(await readInstancePasswordStatus({ ...instance, subtitle: "Renamed" }, async value => {
    options = value;
    return { hasPassword: true };
  }), true);
  assert.equal(options.instanceId, "native-a");
});

test("online and running instances never bypass native password state", async () => {
  let lookups = 0;
  for (const status of ["online", "running", "stopped"]) {
    assert.equal(await readInstancePasswordStatus({ ...instance, status }, async () => {
      lookups++;
      return { hasPassword: true };
    }), true);
  }
  assert.equal(lookups, 3);
});

test("failed or malformed password lookup cannot authorize access", async () => {
  for (const result of [null, undefined, {}, { hasPassword: 0 }, { hasPassword: "false" }]) {
    await assert.rejects(readInstancePasswordStatus(instance, async () => result));
  }
  await assert.rejects(readInstancePasswordStatus(instance, async () => { throw new Error("keychain unavailable"); }));
  assert.equal(await readInstancePasswordStatus(instance, async () => ({ hasPassword: false })), false);
});

test("remote removal requires prior password removal instead of clearing a protected record", () => {
  assert.throws(() => requireUnlockedRemoteDeletion(true), /原密码/);
  assert.doesNotThrow(() => requireUnlockedRemoteDeletion(false));
});

test("closing a dialog revokes a delayed successful verification", async () => {
  const scope = new InstanceAccessScope();
  scope.select(instanceAccessTarget(instance));
  const request = scope.begin();
  const result = deferred();
  let opened = false;
  const completion = result.promise.then(valid => { if (request.isCurrent() && valid) opened = true; });
  scope.select(null);
  result.resolve(true);
  await completion;
  assert.equal(opened, false);
});

test("switching A to B to A cannot revive an earlier response", () => {
  const scope = new InstanceAccessScope();
  const a = instanceAccessTarget(instance);
  scope.select(a);
  const first = scope.begin();
  scope.select(instanceAccessTarget({ ...instance, id: "b" }));
  scope.select(a);
  const latest = scope.begin();
  assert.equal(first.isCurrent(), false);
  assert.equal(latest.isCurrent(), true);
});

test("path, native identity, instance type, and URL changes revoke outstanding access", () => {
  for (const change of [{ installPath: "/Documents/changed" }, { installDir: "other" }, { type: "remote" }, { url: "https://changed.test" }]) {
    const scope = new InstanceAccessScope();
    scope.select(instanceAccessTarget(instance));
    const request = scope.begin();
    scope.select(instanceAccessTarget({ ...instance, ...change }));
    assert.equal(request.isCurrent(), false);
  }
});

test("duplicate submissions are synchronous and stale finish cannot unlock a newer request", () => {
  const scope = new InstanceAccessScope();
  assert.equal(scope.begin(), null);
  scope.select("a");
  const first = scope.begin();
  assert.equal(scope.begin(), null);
  scope.select("b");
  const second = scope.begin();
  first.finish();
  assert.equal(scope.begin(), null);
  second.finish();
  const third = scope.begin();
  assert.equal(second.isCurrent(), false);
  assert.equal(third.isCurrent(), true);
});

test("preview old password is required for every change and removal", async () => {
  const { api, harness } = preview({ platform: "ios" });
  await api.setInstancePassword({ instanceId: "a", password: "first-secret" });
  assert.equal((await api.hasInstancePassword({ instanceId: "a" })).hasPassword, true);
  assert.equal((await api.verifyInstancePassword({ instanceId: "a", password: "wrong" })).valid, false);
  await assert.rejects(api.setInstancePassword({ instanceId: "a", password: "second-secret" }));
  await assert.rejects(api.clearInstancePassword({ instanceId: "a" }));
  await assert.rejects(api.clearInstancePassword({ instanceId: "a", oldPassword: "wrong" }));
  await api.setInstancePassword({ instanceId: "a", password: "second-secret", oldPassword: "first-secret" });
  assert.equal((await api.verifyInstancePassword({ instanceId: "a", password: "second-secret" })).valid, true);
  await api.clearInstancePassword({ instanceId: "a", oldPassword: "second-secret" });
  assert.equal((await api.hasInstancePassword({ instanceId: "a" })).hasPassword, false);
  assert.equal(JSON.stringify(harness.calls).includes("secret"), false);
});

test("preview passwords do not share Basic Auth storage", async () => {
  const { api } = preview();
  await api.setInstancePassword({ instanceId: "a", password: "lock-secret" });
  await api.setRemoteBasicAuth({ instanceId: "a", username: "account", password: "http-secret" });
  await api.clearRemoteBasicAuth({ instanceId: "a" });
  assert.equal((await api.verifyInstancePassword({ instanceId: "a", password: "lock-secret" })).valid, true);
  await api.setRemoteBasicAuth({ instanceId: "a", username: "account", password: "http-secret" });
  await api.clearInstancePassword({ instanceId: "a", oldPassword: "lock-secret" });
  assert.equal((await api.getRemoteBasicAuthStatus({ instanceId: "a" })).configured, true);
});

test("iOS rename and relocation preserve the lock and successful uninstall clears it", async () => {
  const { api } = preview({ platform: "ios", scannedInstanceIds: ["a"] });
  await api.setInstancePassword({ instanceId: "a", password: "lock" });
  assert.equal((await api.renameInstance({ instanceId: "a", newName: "New name" })).newId, "a");
  await api.relocateInstance({ instanceId: "a", targetPath: "/Documents/New name" });
  assert.equal((await api.verifyInstancePassword({ instanceId: "a", password: "lock" })).valid, true);
  await api.uninstallInstance({ instanceId: "a" });
  assert.equal((await api.hasInstancePassword({ instanceId: "a" })).hasPassword, false);
});

test("successful uninstall removes the selected instance and clears its password", async () => {
  const { api } = preview({ platform: "ios", scannedInstanceIds: ["a"] });
  await api.setInstancePassword({ instanceId: "a", password: "lock" });
  const result = await api.uninstallInstance({ instanceId: "a" });
  assert.deepEqual(plain(result), { success: true, freedBytes: 1, instanceId: "a" });
  assert.equal((await api.scanInstances()).instances.length, 0);
  assert.equal((await api.hasInstancePassword({ instanceId: "a" })).hasPassword, false);
});

test("preview password status list follows set and clear operations", async () => {
  const { api } = preview();
  assert.deepEqual(plain(await api.listInstancePasswordStatus()), {});
  await api.setInstancePassword({ instanceId: "a", password: "lock" });
  assert.deepEqual(plain(await api.listInstancePasswordStatus()), { a: true });
  await api.clearInstancePassword({ instanceId: "a", oldPassword: "lock" });
  assert.deepEqual(plain(await api.listInstancePasswordStatus()), {});
});

test("a pending access request is revoked when its scope closes", async () => {
  const { api } = preview();
  const scope = new InstanceAccessScope();
  scope.select("a");
  const request = scope.begin();
  const status = api.hasInstancePassword({ instanceId: "a" });
  scope.select(null);
  await api.setInstancePassword({ instanceId: "a", password: "new-lock" });
  const old = await status;
  assert.equal(old.hasPassword, false);
  assert.equal(request.isCurrent(), false);
  assert.equal((await api.hasInstancePassword({ instanceId: "a" })).hasPassword, true);
});

test("preview platform query supports iOS but fixture takes precedence and unknown values are ignored", () => {
  assert.equal(preview({}, "?nativePreview=1&platform=ios").platform, "ios");
  assert.equal(preview({ platform: "android" }, "?platform=ios").platform, "android");
  assert.equal(preview({}, "?platform=unknown").platform, "windows");
});

test("iOS preview rejects runtime ZIP while allowing data ZIP import", async () => {
  const { api, harness } = preview({
    platform: "ios",
    zipSelection: { path: "/Documents/backup.zip", uri: "file:///Documents/backup.zip", sizeBytes: 12 },
  });
  assert.equal((await api.fetchReleases()).releases[0].zipballUrl, "");
  await assert.rejects(api.provisionAndStart({ instanceId: "a", port: 8000, localZipPath: "/backup.zip" }));
  const selected = await api.pickZipFile({ purpose: "dataImport" });
  assert.deepEqual(selected, { path: "/Documents/backup.zip", uri: "file:///Documents/backup.zip", sizeBytes: 12 });
  assert.equal((await api.inspectImportArchive({
    archivePath: selected.path,
    archiveUri: selected.uri,
  })).importable, true);
  await api.importInstanceData({
    instanceId: "a",
    installPath: "/private/Synthetic/Documents/instances/a",
    archivePath: selected.path,
    archiveUri: selected.uri,
    includeOptional: false,
  });
  assert.deepEqual(plain(harness.calls.find(call => call.method === "importInstanceData").options), {
    instanceId: "a",
    installPath: "/private/Synthetic/Documents/instances/a",
    archivePath: selected.path,
    archiveUri: selected.uri,
    includeOptional: false,
  });
});

test("native preview preserves ZIP export cancellation forms and explicit picker cancellation", async () => {
  const { api, harness } = preview({ platform: "ios", zipSelection: null });
  await assert.rejects(api.pickZipFile({ purpose: "dataImport" }), /cancel/);
  for (const cancellation of [{ cancelled: true }, { canceled: true }]) {
    harness.configure({ exportResult: cancellation });
    assert.deepEqual(plain(await api.exportInstance({ instanceId: "a" })), cancellation);
  }
});
