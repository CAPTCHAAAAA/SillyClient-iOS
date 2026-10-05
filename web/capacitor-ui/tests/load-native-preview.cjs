const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ts = require("typescript");
const { loadSource } = require("./load-source.cjs");

function preview(fixture = {}, search = "") {
  const filename = path.join(__dirname, "../src/dev/native-preview.ts");
  const source = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
  }).outputText;
  const module = { exports: {} };
  const window = { __SILLYCLIENT_PREVIEW_FIXTURE__: fixture, location: { search } };
  const storage = new Map();
  vm.runInNewContext(source, {
    module, exports: module.exports, window, URL, URLSearchParams,
    setTimeout, clearTimeout, setInterval, clearInterval,
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    require: name => name === "@capacitor/core"
      ? { Capacitor: {} }
      : loadSource(path.resolve(path.dirname(filename), name + ".ts")),
  }, { filename });
  module.exports.installNativePreview();
  return { api: module.exports.nativePreview, harness: window.__SILLYCLIENT_TEST__, platform: window.__SILLYCLIENT_PLATFORM__ };
}

module.exports = { preview };
