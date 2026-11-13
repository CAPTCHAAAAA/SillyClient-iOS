const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const ts = require("typescript");
const { loadSource } = require("./load-source.cjs");
const { preview } = require("./load-native-preview.cjs");

const state = loadSource(path.join(__dirname, "../src/lib/instance-location-state.ts"));
const plain = value => JSON.parse(JSON.stringify(value));
const local = { id: "stable-id", installDir: "stable-id", name: "Old", type: "local", installPath: "/old/Old", port: 8000 };

test("returned native ID and path are authoritative and unrelated instances stay unchanged", () => {
  const changed = state.applyInstanceLocation(local, "stable-id", "returned-id", "/actual/New", "New");
  assert.equal(changed.id, "returned-id");
  assert.equal(changed.installDir, "returned-id");
  assert.equal(changed.installPath, "/actual/New");
  assert.equal(changed.installPathMode, "exact");
  assert.equal(changed.subtitle, "New");
  assert.equal(changed.port, 8000);
  assert.equal(state.applyInstanceLocation(local, "other", "wrong", "/wrong"), local);
});

test("unsuccessful or incomplete native relocation results cannot update the UI", () => {
  const valid = { success: true, instanceId: "a", oldPath: "/old/a", newPath: "/new/a" };
  for (const response of [{ ...valid, success: false }, { ...valid, instanceId: "" }, { ...valid, newPath: "" }]) {
    assert.throws(() => state.requireRelocationResult(response));
  }
});

test("Android preview rename updates the native ID and persists the returned path", async () => {
  const { api } = preview({ platform: "android", scannedInstanceIds: ["stable-id"] });
  const renamed = await api.renameInstance({ instanceId: "stable-id", newName: "New name", installPath: "/storage/emulated/0/instances/Old" });
  assert.equal(renamed.newId, "New name");
  assert.equal(renamed.newPath, "/storage/emulated/0/instances/New name");
  const scanned = await api.scanInstances();
  assert.equal(scanned.instances[0].path, renamed.newPath);
  assert.equal((await api.getInstanceInfo({ instanceId: "New name" })).path, renamed.newPath);
});

test("Windows preview rename updates the native ID and preserves a custom parent", async () => {
  const { api } = preview({ platform: "windows", scannedInstanceIds: ["old"] });
  const renamed = await api.renameInstance({ instanceId: "old", newName: "New name", installPath: "E:\\Custom\\Old" });
  assert.equal(renamed.newId, "New name");
  assert.equal(renamed.newPath, "E:\\Custom\\New name");
  const scanned = await api.scanInstances();
  assert.deepEqual(plain(scanned.instances.map(item => item.instanceId)), ["New name"]);
});

test("iOS preview rename keeps its ID and moves only the physical folder within Documents", async () => {
  const { api } = preview({ platform: "ios", scannedInstanceIds: ["stable-id"] });
  const renamed = await api.renameInstance({ instanceId: "stable-id", newName: "New name" });
  assert.equal(renamed.oldId, "stable-id");
  assert.equal(renamed.newId, "stable-id");
  assert.equal(renamed.oldPath, "/private/Synthetic/Documents/instances/stable-id");
  assert.equal(renamed.newPath, "/private/Synthetic/Documents/instances/New name");
  assert.equal((await api.getInstanceInfo({ instanceId: "stable-id" })).path, renamed.newPath);
});

test("iOS relocation defaults to Documents and retains native IDs", async () => {
  const { api } = preview({ platform: "ios", scannedInstanceIds: ["stable-id"] });
  const relocated = await api.relocateInstance({ instanceId: "stable-id", installPath: "/old/Renamed folder" });
  assert.equal(relocated.instanceId, "stable-id");
  assert.equal(relocated.newPath, "/private/Synthetic/Documents/instances/stable-id");
});

test("new-instance wizard receives iOS identity and its installation picker callback", () => {
  const filename = path.join(__dirname, "../src/routes/index.tsx");
  const route = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"),
    ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const wizards = [];
  function visit(node) {
    if ((ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node))
        && node.tagName.getText(route) === "NewInstanceWizardModal") wizards.push(node);
    ts.forEachChild(node, visit);
  }
  visit(route);
  assert.equal(wizards.length, 1);
  const attributes = new Map(wizards[0].attributes.properties
    .filter(ts.isJsxAttribute)
    .map(attribute => [attribute.name.getText(route), attribute.initializer?.getText(route)]));
  assert.equal(attributes.get("isIOS"), "{isIOS}");
  assert.equal(attributes.get("onPickInstallFolder"), "{handlePickInstallFolder}");

  const source = fs.readFileSync(filename, "utf8");
  assert.match(source, /setNewInstancePathMode\(selection\.mode\)/);
  assert.match(source, /exactInstallTarget\(customParentDir, newInstancePathMode, instanceId\)/);
  assert.match(source, /setNewInstancePathMode\("exact"\)/);
  assert.match(source, /if \(newInstanceMode === "local" && !cleanInstallPath\(newInstanceDir\)\)/);
  assert.match(source, /请先点「浏览」选择实例安装目录（必选）/);

  const picker = source.slice(source.indexOf("const handlePickInstallFolder"), source.indexOf("// 实例列表持久化", source.indexOf("const handlePickInstallFolder")));
  assert.match(picker, /shouldShowDirectoryPickerError\(error, isIOS\)/);
  assert.match(picker, /\}, \[isAndroid, isIOS\]\)/);
  const pickerErrorHandler = picker.slice(picker.lastIndexOf("} catch (error)"));
  assert.doesNotMatch(pickerErrorHandler, /setNewInstanceDir\(""\)/);
});

test("iOS storage wiring preserves platform affordances and requests installation bookmark access", () => {
  const read = filename => fs.readFileSync(path.join(__dirname, "../src", filename), "utf8");
  const route = read("routes/index.tsx");
  assert.ok(route.includes('const isIOS = Capacitor.getPlatform() === "ios"'));
  assert.ok(route.includes('"iOS 控制台"'));
  assert.ok(route.includes('"ios >"'));
  assert.ok(route.includes('isIOS={isIOS}'));
  assert.ok(route.includes('isWindows={isWindows}'));
  assert.match(route, /const configured = settings\?\.configuredInstancesRoot\?\.trim\(\);[\s\S]*setNewInstanceDir\(current => \{[\s\S]*if \(cancelled \|\| current\.trim\(\)\) return current;[\s\S]*setNewInstancePathMode\("root"\);[\s\S]*return configured;[\s\S]*\}\);/);
  assert.doesNotMatch(route, /LegacyMigration|migrateLegacy|migrateInstance|checkLegacyInstances|createInstanceBackup|parseInstanceBackup/);
  const wizard = read("components/modals/NewInstanceWizardModal.tsx");
  assert.ok(wizard.includes('右上角「打开」'));
  const relocate = read("components/modals/RelocateInstanceModal.tsx");
  assert.ok(relocate.includes('purpose: "installation"'));
  assert.ok(relocate.includes('应用 Documents 下的'));
  assert.ok(relocate.includes('右上角「打开」'));
  assert.ok(relocate.includes('retainedSourcePath'));
  assert.equal(fs.existsSync(path.join(__dirname, "../src/components/modals/LegacyMigrationModal.tsx")), false);
  const manage = read("components/modals/ManageInstanceModal.tsx");
  assert.ok(manage.includes('label="导出实例（ZIP）"'));
  assert.ok(manage.includes('label="导入数据（ZIP）"'));
  assert.ok(manage.includes("TarvenEnv.inspectImportArchive"));
  assert.ok(manage.includes("TarvenEnv.importInstanceData"));
  assert.ok(manage.includes("TarvenEnv.exportInstance"));
  const running = read("components/instance/RunningConsoleCard.tsx");
  assert.ok(running.includes("isIOS?: boolean"));
  assert.match(running, /isIOS[\s\S]*"ios >"/);
  assert.ok(running.includes("iOS 进程内环境（可查看服务运行日志）"));
  assert.ok(running.includes("输入 Android shell 命令..."));
  const card = read("components/instance/InstanceCard.tsx");
  const carousel = read("components/instance/InstanceCarousel.tsx");
  assert.ok(card.includes("isIOS={props.isIOS}"));
  assert.ok(carousel.includes("isIOS={isIOS}"));
});

test("preview relocation persists the actual target path and identity", async () => {
  const { api } = preview({ platform: "android", scannedInstanceIds: ["a"] });
  const relocated = await api.relocateInstance({ instanceId: "a", installPath: "/private/a", targetPath: "/external/a" });
  assert.equal(relocated.instanceId, "a");
  assert.equal(relocated.newPath, "/external/a");
  assert.equal((await api.getInstanceInfo({ instanceId: "a" })).path, "/external/a");
});

test("preview refuses native storage mutation while the runtime is busy", async () => {
  const { api } = preview({ status: { serverReady: true, instanceId: "a", mode: "launcher" } });
  await assert.rejects(api.renameInstance({ instanceId: "a", newName: "B" }));
  await assert.rejects(api.relocateInstance({ instanceId: "a", targetPath: "/new" }));
});

test("approved button palette, motion layers and inline async wiring remain present", () => {
  const read = filename => fs.readFileSync(path.join(__dirname, "../src", filename), "utf8");
  const running = read("components/instance/RunningConsoleCard.tsx");
  assert.ok(running.includes("flat-capsule"));
  assert.ok(running.includes("text-red-900/55 hover:text-red-900/80"));
  assert.ok(running.includes("text-red-300/70 hover:text-red-200"));
  const relocate = read("components/modals/RelocateInstanceModal.tsx");
  assert.ok(relocate.includes("LAYERS.DIALOG_SURFACE"));
  assert.ok(relocate.includes("motion-panel-stack"));
  assert.ok(relocate.includes("retainedSourcePath"));
  const stopped = read("components/instance/InstanceStoppedCard.tsx");
  assert.ok(stopped.includes("await onRenameSave"));
  assert.ok(stopped.includes("motion-instance-card"));
});
