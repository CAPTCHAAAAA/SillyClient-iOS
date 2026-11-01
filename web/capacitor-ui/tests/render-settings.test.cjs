const test = require("node:test");
const assert = require("node:assert/strict");
const { loadSource } = require("./load-source.cjs");
const path = require("node:path");

const { normalizeRenderEngineSettings } = loadSource(
  path.join(__dirname, "../src/lib/render-settings.ts")
);
const plain = (val) => JSON.parse(JSON.stringify(val));

test("normalizeRenderEngineSettings defaults all options to enabled with realtime mode", () => {
  const settings = normalizeRenderEngineSettings();
  assert.deepEqual(plain(settings), {
    immersiveColor: true,
    colorExtractionMode: "realtime",
    clickEffect: true,
  });
});

test("normalizeRenderEngineSettings handles once mode properly", () => {
  const settings = normalizeRenderEngineSettings({
    immersiveColor: true,
    colorExtractionMode: "once",
    clickEffect: true,
  });
  assert.equal(settings.colorExtractionMode, "once");
});

test("normalizeRenderEngineSettings forces clickEffect to false when immersiveColor is disabled", () => {
  const settings = normalizeRenderEngineSettings({
    immersiveColor: false,
    colorExtractionMode: "realtime",
    clickEffect: true,
  });
  assert.equal(settings.immersiveColor, false);
  assert.equal(settings.clickEffect, false);
});

test("normalizeRenderEngineSettings normalizes unknown mode to realtime", () => {
  const settings = normalizeRenderEngineSettings({
    colorExtractionMode: "unknown_mode",
  });
  assert.equal(settings.colorExtractionMode, "realtime");
});
