const assert = require("node:assert/strict");
const path = require("node:path");
const { test } = require("node:test");
const { loadSource } = require("./load-source.cjs");

const location = loadSource(path.join(__dirname, "../src/lib/install-location.ts"));
const plain = value => JSON.parse(JSON.stringify(value));

test("installation selection preserves the full path, never the display name", () => {
  for (const selectedPath of [
    "D:\\Taverns\\Same name",
    "/data/user/0/com.sillyclient/files/tarven/installations",
    "/private/var/mobile/Containers/Data/Application/test/Documents/Custom",
  ]) {
    assert.deepEqual(plain(location.installationSelection({ name: "Same name", path: selectedPath })),
      { path: selectedPath, mode: "exact" });
  }
});

test("path quotes normalize without damaging spaces or platform separators", () => {
  assert.equal(location.cleanInstallPath('  "D:\\Taverns\\My Tavern"  '), "D:\\Taverns\\My Tavern");
  assert.equal(location.cleanInstallPath(" '/private/My Tavern' "), "/private/My Tavern");
  assert.equal(location.cleanInstallPath(""), undefined);
});

test("missing picker path cannot silently fall back to a folder name", () => {
  for (const path of ["", "  ", undefined]) {
    assert.throws(() => location.installationSelection({ name: "Tavern", path }));
  }
});

test("installation modes are explicit and invalid modes are rejected", () => {
  assert.equal(location.installationSelection({ path: "/root/exact", installPathMode: "exact" }).mode, "exact");
  assert.throws(() => location.installationSelection({ path: "/root", installPathMode: "guess" }));
});

test("only an explicit root selection adds the dedicated instance folder", () => {
  const selected = location.installationSelection({ path: "/external/Selected", installPathMode: "root" });
  assert.equal(selected.mode, "root");
  assert.equal(location.exactInstallTarget(selected.path, selected.mode, "New instance"), "/external/Selected/New instance");
  assert.equal(location.exactInstallTarget("/external/New instance", selected.mode, "New instance"),
    "/external/New instance");
  const exact = location.installationSelection({ path: "/external/Selected" });
  assert.equal(location.exactInstallTarget(exact.path, exact.mode, "New instance"), "/external/Selected");
});

test("copy migration turns a selected root into a new exact target without changing identity", () => {
  assert.equal(location.exactInstallTarget("D:\\Custom\\", "root", "local-100"), "D:\\Custom\\local-100");
  assert.equal(location.exactInstallTarget("/private/Custom/", "root", "local-100"), "/private/Custom/local-100");
  assert.equal(location.exactInstallTarget("/", "root", "local-100"), "/local-100");
  assert.equal(location.exactInstallTarget("D:\\Custom\\chosen-name", "exact", "local-100"), "D:\\Custom\\chosen-name");
  assert.equal(location.exactInstallTarget("", "root", "local-100"), undefined);
});

test("document-provider URIs cannot be disguised as executable install paths", () => {
  assert.throws(() => location.installationSelection({ path: "content://provider/tree/test" }));
  assert.throws(() => location.exactInstallTarget("content://provider/tree/test", "exact", "local-100"));
});

test("iOS picker hides only its explicit cancellation code, not provider errors or unexpected dismissals", () => {
  assert.equal(location.shouldShowDirectoryPickerError({ code: "PICKER_CANCELLED", message: "Selection cancelled" }, true), false);
  assert.equal(location.shouldShowDirectoryPickerError(new Error("PICKER_CANCELLED"), true), false);
  assert.equal(location.shouldShowDirectoryPickerError({ code: "PICKER_DISMISSED_WITHOUT_RESULT", message: "PICKER_DISMISSED_WITHOUT_RESULT" }, true), true);
  assert.equal(location.shouldShowDirectoryPickerError(new Error("PICKER_DISMISSED_WITHOUT_RESULT"), true), true);
  assert.equal(location.shouldShowDirectoryPickerError(new Error("NSFileProviderError: operation cancelled by provider"), true), true);
  assert.equal(location.shouldShowDirectoryPickerError(new Error("Selection cancelled"), true), true);
});

test("validateInstallPathInput blocks iOS Files breadcrumbs and non-local inputs before creation", () => {
  assert.match(location.validateInstallPathInput("我的 iPhone ▸ SillyClient", { isIOS: true }), /浏览.*显示名称/);
  assert.match(location.validateInstallPathInput("SillyClient", { isIOS: true }), /浏览.*显示名称/);
  assert.match(location.validateInstallPathInput("instances/demo", { isIOS: true }), /浏览.*显示名称/);
  assert.match(location.validateInstallPathInput("/private/var/mobile/../escape", { isIOS: true }), /上级目录跳转/);
  assert.match(location.validateInstallPathInput("file:///private/var/mobile/test", { isIOS: true }), /可执行的本地路径/);
  assert.equal(location.validateInstallPathInput("/private/var/mobile/Containers/Data/Application/test/Documents/instances", { isIOS: true }), null);
  assert.equal(location.validateInstallPathInput("D:\\Taverns\\My Tavern", { isIOS: false }), null);
  assert.match(location.validateInstallPathInput("我的 iPhone ▸ SillyClient", { isIOS: false }), /显示名称/);
  assert.equal(location.validateInstallPathInput("", { isIOS: true }), null);
});

test("non-iOS picker cancellation keeps the existing message-based behavior", () => {
  assert.equal(location.shouldShowDirectoryPickerError(new Error("Selection cancelled"), false), false);
  assert.equal(location.shouldShowDirectoryPickerError(new Error("Permission denied"), false), true);
});

test("normalizeInstanceIdentity strictly produces ASCII characters satisfying ^[A-Za-z0-9_-]{1,128}$", () => {
  const regex = /^[A-Za-z0-9_-]{1,128}$/;
  assert.ok(regex.test(location.normalizeInstanceIdentity("")));
  assert.ok(regex.test(location.normalizeInstanceIdentity("新实例")));
  assert.ok(regex.test(location.normalizeInstanceIdentity("我的酒馆 (2)")));
  assert.equal(location.normalizeInstanceIdentity("My Tavern"), "My-Tavern");
  assert.equal(location.normalizeInstanceIdentity("test_instance-123"), "test_instance-123");
  assert.ok(regex.test(location.normalizeInstanceIdentity("  ...---special###!!!$$$   ")));
});

test("humanizeNativeError translates iOS provider, path validation, and dismissal diagnostics cleanly", () => {
  const nativeErrors = loadSource(path.join(__dirname, "../src/lib/native-errors.ts"));
  assert.match(nativeErrors.humanizeNativeError("PICKER_DISMISSED_WITHOUT_RESULT"), /选择窗口关闭了/);
  assert.match(nativeErrors.humanizeNativeError("An absolute local installation path is required"), /浏览/);
  assert.match(nativeErrors.humanizeNativeError("Only absolute local paths and credential-free file URLs are supported"), /浏览/);
  assert.match(nativeErrors.humanizeNativeError("Installation paths cannot be relative or contain parent traversal"), /相对路径/);
  assert.match(nativeErrors.humanizeNativeError("Installation root bookmark is stale; select the same directory again"), /持久化访问授权已失效/);
  assert.match(nativeErrors.humanizeNativeError("This iCloud installation folder is not downloaded locally; download it or choose a local folder"), /iCloud 文件夹尚未下载/);
  assert.match(nativeErrors.humanizeNativeError("The selected provider cannot retain local runtime files [NSPOSIXErrorDomain:45]: Operation not supported"), /不支持直接运行本地酒馆文件/);
  assert.match(nativeErrors.humanizeNativeError("Installation folder selection failed at coordinate-selected-directory [NSCocoaErrorDomain:257]: Permission denied"), /目录选择失败（coordinate-selected-directory NSCocoaErrorDomain:257）/);
  assert.match(nativeErrors.humanizeNativeError("An explicit valid instance identity is required"), /实例目录标识仅支持英文字母/);
});
