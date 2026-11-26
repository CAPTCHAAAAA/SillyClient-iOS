/**
 * SillyClient iOS SillyTavern 兼容性补丁脚本 (patch-sillytavern.mjs)
 *
 * 运行于构建期与启动预备期。
 * 核心任务：
 * 1. 修复 sillytavern-transformers 中 NodeMobile (iOS small-icu) 不支持的 Unicode 属性转义正则 (/^\p{Cc}|\p{Cf}|\p{Co}|\p{Cs}$/u) 与分词模式串；
 * 2. 修复 gpt-3-encoder 中不支持的 \p{L} / \p{N} 正则语法错误 (SyntaxError: Invalid regular expression: Invalid property name)；
 * 3. 修复 @jsquash/png, @jsquash/oxipng, isomorphic-git 中由于 small-icu 不支持 fatal: true 抛出 ERR_NO_ICU 的问题；
 * 4. 修复 tiktoken 在 iOS jitless / 无 WebAssembly 运行时环境下的安全降级适配；
 * 5. 将 SillyTavern src/transformers.js 改造成按需懒加载 (Lazy import)，杜绝服务启动阶段不必要的 100MB+ 模型库解析与内存占用；
 * 6. 深度递归扫描并防御性替换 node_modules 中任何潜在的 ICU 正则与 TextDecoder 选项冲突。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 精确解析目标目录，过滤形如 --port=8000 的命令行参数
let targetDir = process.cwd();
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (!arg.startsWith('-') && fs.existsSync(arg)) {
    targetDir = path.resolve(arg);
    break;
  }
}
console.log(`[patch-sillytavern] Starting patch on directory: ${targetDir}`);

const origPatStr = "/'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+/gu";
const safePatStr = "/'s|'t|'re|'ve|'m|'ll|'d| ?[a-zA-Z\\u0080-\\uFFFF]+| ?[0-9]+| ?[^\\s\\w\\u0080-\\uFFFF]+|\\s+(?!\\S)|\\s+/g";

// 1. 补丁 sillytavern-transformers 的 src/tokenizers.js
const tokenizersPath = path.join(targetDir, 'node_modules', 'sillytavern-transformers', 'src', 'tokenizers.js');
if (fs.existsSync(tokenizersPath)) {
  let content = fs.readFileSync(tokenizersPath, 'utf8');
  const targetRegex = /return\s+\/\^\\p\{Cc\}\|\\p\{Cf\}\|\\p\{Co\}\|\\p\{Cs\}\$\/u\.test\(char\);/g;
  const replacement = 'const code = char.charCodeAt(0);\n                return (code <= 31 || (code >= 127 && code <= 159) || (code >= 55296 && code <= 57343) || (code >= 57344 && code <= 63743));';
  if (targetRegex.test(content)) {
    content = content.replace(targetRegex, replacement);
  }
  if (content.includes(origPatStr)) {
    content = content.replaceAll(origPatStr, safePatStr);
  }
  fs.writeFileSync(tokenizersPath, content, 'utf8');
  console.log(`[patch-sillytavern] [1/6] Successfully patched: ${tokenizersPath}`);
}

// 2. 补丁 sillytavern-transformers 的 dist/transformers.js
const distPath = path.join(targetDir, 'node_modules', 'sillytavern-transformers', 'dist', 'transformers.js');
if (fs.existsSync(distPath)) {
  let content = fs.readFileSync(distPath, 'utf8');
  const targetRegex = /return\s+\/\^\\p\{Cc\}\|\\p\{Cf\}\|\\p\{Co\}\|\\p\{Cs\}\$\/u\.test\(char\);/g;
  const replacement = 'const code = char.charCodeAt(0); return (code <= 31 || (code >= 127 && code <= 159) || (code >= 55296 && code <= 57343) || (code >= 57344 && code <= 63743));';
  if (targetRegex.test(content)) {
    content = content.replace(targetRegex, replacement);
  }
  if (content.includes(origPatStr)) {
    content = content.replaceAll(origPatStr, safePatStr);
  }
  fs.writeFileSync(distPath, content, 'utf8');
  console.log(`[patch-sillytavern] [2/6] Successfully patched: ${distPath}`);
}

// 补丁 sillytavern-transformers 的 dist/transformers.min.js
const distMinPath = path.join(targetDir, 'node_modules', 'sillytavern-transformers', 'dist', 'transformers.min.js');
if (fs.existsSync(distMinPath)) {
  let content = fs.readFileSync(distMinPath, 'utf8');
  const targetRegex = /\/\^\\p\{Cc\}\|\\p\{Cf\}\|\\p\{Co\}\|\\p\{Cs\}\$\/u\.test\(([a-zA-Z0-9_$]+)\)/g;
  if (targetRegex.test(content)) {
    content = content.replace(targetRegex, '($1.charCodeAt(0)<=31||($1.charCodeAt(0)>=127&&$1.charCodeAt(0)<=159)||($1.charCodeAt(0)>=55296&&$1.charCodeAt(0)<=63743))');
  }
  if (content.includes(origPatStr)) {
    content = content.replaceAll(origPatStr, safePatStr);
  }
  fs.writeFileSync(distMinPath, content, 'utf8');
  console.log(`[patch-sillytavern] [2b/6] Successfully patched minified: ${distMinPath}`);
}

// 3. 补丁 gpt-3-encoder 的 Encoder.js (vectra -> gpt-3-encoder 依赖)
const gpt3EncoderPath = path.join(targetDir, 'node_modules', 'gpt-3-encoder', 'Encoder.js');
if (fs.existsSync(gpt3EncoderPath)) {
  let content = fs.readFileSync(gpt3EncoderPath, 'utf8');
  if (content.includes(origPatStr)) {
    content = content.replaceAll(origPatStr, safePatStr);
    fs.writeFileSync(gpt3EncoderPath, content, 'utf8');
    console.log(`[patch-sillytavern] [3/6] Successfully patched gpt-3-encoder: ${gpt3EncoderPath}`);
  } else {
    console.log(`[patch-sillytavern] [3/6] gpt-3-encoder already patched or pattern not found: ${gpt3EncoderPath}`);
  }
}

// 4. 补丁 TextDecoder { fatal: true } (ERR_NO_ICU: fatal option is not supported on Node.js compiled without ICU)
const textDecoderTargets = [
  path.join(targetDir, 'node_modules', '@jsquash', 'png', 'codec', 'pkg', 'squoosh_png.js'),
  path.join(targetDir, 'node_modules', '@jsquash', 'oxipng', 'codec', 'pkg', 'squoosh_oxipng.js'),
  path.join(targetDir, 'node_modules', '@jsquash', 'oxipng', 'codec', 'pkg-parallel', 'squoosh_oxipng.js'),
  path.join(targetDir, 'node_modules', 'isomorphic-git', 'models', 'index.js'),
  path.join(targetDir, 'node_modules', 'isomorphic-git', 'models', 'index.cjs'),
  path.join(targetDir, 'node_modules', 'tiktoken', 'tiktoken_bg.cjs'),
  path.join(targetDir, 'node_modules', 'tiktoken', 'lite', 'tiktoken_bg.cjs')
];
for (const tf of textDecoderTargets) {
  if (fs.existsSync(tf)) {
    let c = fs.readFileSync(tf, 'utf8');
    if (c.includes('fatal: true')) {
      c = c.replace(/ignoreBOM:\s*true,\s*fatal:\s*true/g, 'ignoreBOM: true');
      c = c.replace(/fatal:\s*true/g, 'fatal: false');
      fs.writeFileSync(tf, c, 'utf8');
      console.log(`[patch-sillytavern] [4/6] Successfully stripped fatal: true from: ${tf}`);
    }
  }
}

// 5. Keep imports usable without WASM, but never fabricate token IDs or decoded text.
const tiktokenFiles = [
  path.join(targetDir, 'node_modules', 'tiktoken', 'tiktoken.cjs'),
  path.join(targetDir, 'node_modules', 'tiktoken', 'lite', 'tiktoken.cjs')
];
for (const tf of tiktokenFiles) {
  if (fs.existsSync(tf)) {
    let c = fs.readFileSync(tf, 'utf8');
    if (!c.includes('// SillyClient iOS tiktoken fallback')) {
      const exportNames = tf.includes(`${path.sep}lite${path.sep}`)
        ? ['Tiktoken']
        : ['get_encoding', 'encoding_for_model', 'get_encoding_name_for_model', 'Tiktoken'];
      const exportAssignments = exportNames.map(name => `exports["${name}"] = wasm["${name}"];`).join('\n');
      const origInstantiation = `const wasmModule = new WebAssembly.Module(bytes);
const wasmInstance = new WebAssembly.Instance(wasmModule, imports);
wasm.__wbg_set_wasm(wasmInstance.exports);
${exportAssignments}`;

      const safeInstantiation = `// SillyClient iOS tiktoken fallback
function unavailableTokenizer() {
  const error = new Error("This tokenizer requires WebAssembly, which is unavailable in the iOS runtime.");
  error.code = "ERR_IOS_WASM_UNAVAILABLE";
  throw error;
}

try {
  if (typeof WebAssembly !== 'undefined' && typeof WebAssembly.Module === 'function' && typeof WebAssembly.Instance === 'function') {
    const wasmModule = new WebAssembly.Module(bytes);
    const wasmInstance = new WebAssembly.Instance(wasmModule, imports);
    if (wasmInstance && wasmInstance.exports && Object.keys(wasmInstance.exports).length > 0) {
      wasm.__wbg_set_wasm(wasmInstance.exports);
      exports["get_encoding"] = wasm["get_encoding"];
      exports["encoding_for_model"] = wasm["encoding_for_model"];
      exports["get_encoding_name_for_model"] = wasm["get_encoding_name_for_model"];
      exports["Tiktoken"] = wasm["Tiktoken"];
    } else {
      throw new Error("WebAssembly exports empty");
    }
  } else {
    throw new Error("WebAssembly not supported");
  }
} catch (e) {
  exports["get_encoding"] = unavailableTokenizer;
  exports["encoding_for_model"] = unavailableTokenizer;
  exports["get_encoding_name_for_model"] = unavailableTokenizer;
  exports["Tiktoken"] = class { constructor() { unavailableTokenizer(); } };
}`;

      if (c.includes('const wasmModule = new WebAssembly.Module(bytes);')) {
        if (!c.includes(origInstantiation)) {
          throw new Error(`Unsupported tiktoken initialization in ${tf}`);
        }
        c = c.replace(origInstantiation, safeInstantiation);
        fs.writeFileSync(tf, c, 'utf8');
        console.log(`[patch-sillytavern] [5/6] Successfully injected tiktoken WebAssembly fallback in: ${tf}`);
      }
    }
  }
}

// 6. 补丁 SillyTavern 官方源码 src/transformers.js 使其按需懒加载
const serverTransformersPath = path.join(targetDir, 'src', 'transformers.js');
if (fs.existsSync(serverTransformersPath)) {
  let content = fs.readFileSync(serverTransformersPath, 'utf8');
  if (content.includes("import { pipeline, env, RawImage } from 'sillytavern-transformers';")) {
    content = content.replace(
      "import { pipeline, env, RawImage } from 'sillytavern-transformers';",
      `// SillyClient iOS: 懒加载 sillytavern-transformers 运行时
let _transformersModule = null;
async function getTransformers() {
    if (!_transformersModule) {
        _transformersModule = await import('sillytavern-transformers');
        _transformersModule.env.backends.onnx.wasm.numThreads = 1;
        _transformersModule.env.backends.onnx.wasm.wasmPaths = path.join(serverDirectory, 'node_modules', 'sillytavern-transformers', 'dist') + path.sep;
    }
    return _transformersModule;
}`
    );
    content = content.replace('configureTransformers();', '// configureTransformers() is handled on-demand in getTransformers()');

    content = content.replace(
      'const rawImage = await RawImage.fromBlob(blob);',
      'const { RawImage } = await getTransformers();\n        const rawImage = await RawImage.fromBlob(blob);'
    );

    content = content.replace(
      "const instance = await pipeline(task, model, { cache_dir: cacheDir, quantized: tasks[task].quantized ?? true, local_files_only: localOnly });",
      "const { pipeline } = await getTransformers();\n    const instance = await pipeline(task, model, { cache_dir: cacheDir, quantized: tasks[task].quantized ?? true, local_files_only: localOnly });"
    );

    fs.writeFileSync(serverTransformersPath, content, 'utf8');
    console.log(`[patch-sillytavern] [6/7] Successfully made transformers lazy in: ${serverTransformersPath}`);
  } else {
    console.log(`[patch-sillytavern] [6/7] Notice: src/transformers.js does not contain static import or is already patched`);
  }
}

// 7. 补丁 SillyTavern 官方源码 src/middleware/webpack-serve.js 确保使用 prebuilt-webpack，杜绝运行时导入 webpack
const webpackServePath = path.join(targetDir, 'src', 'middleware', 'webpack-serve.js');
if (fs.existsSync(webpackServePath)) {
  let content = fs.readFileSync(webpackServePath, 'utf8');
  if (content.includes('ios-frontend') || content.includes('prebuilt-webpack')) {
    console.log(`[patch-sillytavern] [7/8] Notice: webpack-serve.js is already using prebuilt-webpack: ${webpackServePath}`);
  } else {
    const prebuiltCandidates = [
      path.join(path.dirname(fileURLToPath(import.meta.url)), 'prebuilt-webpack.mjs'),
      path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'native-src', 'prebuilt-webpack.mjs'),
    ];
    let installed = false;
    for (const cand of prebuiltCandidates) {
      if (fs.existsSync(cand)) {
        fs.copyFileSync(cand, webpackServePath);
        console.log(`[patch-sillytavern] [7/8] Successfully installed prebuilt-webpack from ${cand} into: ${webpackServePath}`);
        installed = true;
        break;
      }
    }
    if (!installed) {
      const safeWebpackServe = `import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

// Installed as SillyTavern/src/middleware/webpack-serve.js after the host build.
const serverRoot = fileURLToPath(new URL('../../', import.meta.url));
const assetRoot = path.join(serverRoot, 'dist', 'ios-frontend');

export default function getWebpackServeMiddleware() {
    let assets = null;

    function middleware(req, res, next) {
        const name = req.path?.slice(1);
        if (assets?.has(name) && (req.method === 'GET' || req.method === 'HEAD')) {
            return res.sendFile(name, { root: assetRoot, dotfiles: 'deny' });
        }
        next();
    }

    middleware.runWebpackCompiler = async () => {
        assets = null;
        const manifestFile = path.join(assetRoot, 'manifest.json');
        if (!fs.existsSync(manifestFile)) {
            console.log('[ios-frontend] Notice: manifest.json not found, frontend prebuild bypassed.');
            return;
        }
        const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
        const pkg = JSON.parse(fs.readFileSync(path.join(serverRoot, 'package.json'), 'utf8'));
        if (manifest.format !== 1 || manifest.version !== pkg.version || !Array.isArray(manifest.assets)) {
            throw new Error('Invalid or incompatible iOS frontend manifest. Rebuild the application.');
        }

        const verified = new Set();
        for (const asset of manifest.assets) {
            const name = asset.name;
            if (typeof name !== 'string' || !name || name.includes('\\\\') || name.includes(':')
                || name.split('/').some(part => !part || part === '.' || part === '..' || part.startsWith('.'))
                || verified.has(name) || !/^[a-f0-9]{64}$/.test(asset.sha256)) {
                throw new Error('Invalid asset entry in the iOS frontend manifest.');
            }
            const file = path.join(assetRoot, name);
            const realRoot = fs.realpathSync(assetRoot);
            const relative = path.relative(realRoot, fs.realpathSync(file));
            if (relative.startsWith('..') || path.isAbsolute(relative) || !fs.statSync(file).isFile()) {
                throw new Error(\`Invalid iOS frontend asset path: \${name}\`);
            }
            const content = fs.readFileSync(file);
            if (content.length !== asset.bytes
                || createHash('sha256').update(content).digest('hex') !== asset.sha256) {
                throw new Error(\`iOS frontend asset verification failed: \${name}\`);
            }
            verified.add(name);
        }
        if (!verified.has('lib.js')) {
            throw new Error('The prebuilt iOS frontend is missing lib.js.');
        }
        assets = verified;
        console.log(\`[ios-frontend] Verified \${assets.size} prebuilt assets; runtime compilation disabled.\`);
    };

    return middleware;
}
`;
      fs.writeFileSync(webpackServePath, safeWebpackServe, 'utf8');
      console.log(`[patch-sillytavern] [7/8] Successfully installed embedded prebuilt-webpack into: ${webpackServePath}`);
    }
  }
}

// 7b. 补丁 SillyTavern 官方源码 src/jimp.js：在无 WebAssembly 的 iOS 运行时自动切换纯 JS JPEG/PNG 解码器并限制单图峰值内存
const jimpPath = path.join(targetDir, 'src', 'jimp.js');
if (fs.existsSync(jimpPath)) {
  let content = fs.readFileSync(jimpPath, 'utf8');
  if (!content.includes('// SillyClient iOS pure-JS Jimp fallback')) {
    const wasmImports = `import webp from '@jimp/wasm-webp';
import png from '@jimp/wasm-png';
import jpeg from '@jimp/wasm-jpeg';
import avif from '@jimp/wasm-avif';`;
    const formatList = 'formats: [webp, png, jpeg, avif, bmp, msBmp, gif, tiff],';
    if (content.includes(wasmImports) && content.includes(formatList)) {
      content = content.replace(
        wasmImports,
        `// SillyClient iOS pure-JS Jimp fallback
import webp from '@jimp/wasm-webp';
import png from '@jimp/wasm-png';
import jpeg from '@jimp/wasm-jpeg';
import avif from '@jimp/wasm-avif';
import jsPng from '@jimp/js-png';
import jsJpeg from '@jimp/js-jpeg';

const hasWebAssembly = typeof WebAssembly !== 'undefined' && typeof WebAssembly.instantiate === 'function';
function safeJsJpeg() {
    const codec = jsJpeg();
    return {
        ...codec,
        decode: (data, options = {}) => codec.decode(data, {
            maxResolutionInMP: 16,
            maxMemoryUsageInMB: 128,
            ...options,
        }),
    };
}`
      );
      content = content.replace(
        formatList,
        'formats: hasWebAssembly ? [webp, png, jpeg, avif, bmp, msBmp, gif, tiff] : [jsPng, safeJsJpeg, bmp, msBmp, gif, tiff],'
      );
      fs.writeFileSync(jimpPath, content, 'utf8');
      console.log(`[patch-sillytavern] [7b/8] Successfully patched src/jimp.js with no-WASM pure-JS JPEG/PNG fallback: ${jimpPath}`);
    }
  } else {
    console.log(`[patch-sillytavern] [7b/8] Notice: src/jimp.js already has pure-JS fallback: ${jimpPath}`);
  }
}

// 7c. 补丁 simple-git 与 isomorphic-git/http/node：
// iOS NodeMobile 无系统 git 可执行文件且运行在 Worker 线程中（Module.register 对 Worker 与 CJS 无效），
// 直接在 node_modules 包入口注入纯 JS Git 桥接 + 多镜像回退 + pull 孤儿文件清理，同时覆盖 Main/Worker 与 ESM/CJS。
const simpleGitDir = path.join(targetDir, 'node_modules', 'simple-git');
const isoGitHttpDir = path.join(targetDir, 'node_modules', 'isomorphic-git', 'http', 'node');
const isoGitHttpCjs = path.join(isoGitHttpDir, 'index.cjs');
const isoGitHttpEsm = path.join(isoGitHttpDir, 'index.js');
const isoGitHttpOrigCjs = path.join(targetDir, 'node_modules', '.sillyclient-ios-git-http-orig.cjs');
const bridgeCjsPath = path.join(targetDir, 'node_modules', '.sillyclient-ios-git-bridge.cjs');

if (fs.existsSync(isoGitHttpCjs) && fs.existsSync(simpleGitDir)) {
  const currentIsoHttp = fs.readFileSync(isoGitHttpCjs, 'utf8');
  if (!fs.existsSync(isoGitHttpOrigCjs) && !currentIsoHttp.includes('SillyClient iOS Git HTTP bridge')) {
    fs.copyFileSync(isoGitHttpCjs, isoGitHttpOrigCjs);
  }
  if (fs.existsSync(isoGitHttpOrigCjs)) {
    const bridgeSource = `'use strict';
// SillyClient iOS pure-JS Git bridge (ESM + CJS + Worker compatible, zero system git required)
const fs = require('node:fs');
const path = require('node:path');
const isomorphicGit = require('./isomorphic-git');
const origHttp = require('./.sillyclient-ios-git-http-orig.cjs');

const KNOWN_REPOS = {
  'JS-Slash-Runner': { repo: 'N0VI028/JS-Slash-Runner', version: '4.11.2', commit: '46ec10df770b47e1ce6562de747d72f1bde3549e' },
  'LittleWhiteBox': { repo: 'RT15548/LittleWhiteBox', version: '3.1.6', commit: '66cb1001e860cdddd77e5a3911c7c47ea325df3a' },
  'ST-Prompt-Template': { repo: 'zonde306/ST-Prompt-Template', version: '1.17.9', commit: 'd6f520d149aba146305b0b781ddd691d449c28d2' },
  'Extension-Dice': { repo: 'SillyTavern/Extension-Dice', version: '2.0.0', commit: 'b4047508a1191ba3b32cb20f64ebc5f7877d689b' },
};

const DEFAULT_GIT_MIRRORS = [
  'https://gh-proxy.com/',
  'https://gh-proxy.org/',
  'https://edgeone.gh-proxy.com/',
  'https://ghproxy.vip/',
  'https://v6.gh-proxy.org/',
];

function createBridge(fsMod, pathMod, isoGit, baseHttp) {
  let preferredMirrorPrefix = null;

  function isSha(val) {
    return typeof val === 'string' && val.length === 40 && /^[0-9a-f]{40}$/i.test(val);
  }

  function stripGitSuffix(rawUrl) {
    const text = String(rawUrl || '').trim();
    return text.toLowerCase().endsWith('.git') ? text.slice(0, -4) : text;
  }

  async function collectBody(body) {
    if (!body) return undefined;
    if (Buffer.isBuffer(body) || body instanceof Uint8Array) return [Buffer.from(body)];
    if (Array.isArray(body)) return [Buffer.concat(body.map(b => Buffer.from(b)))];
    const chunks = [];
    for await (const chunk of body) chunks.push(Buffer.from(chunk));
    return [Buffer.concat(chunks)];
  }

  function withTimeout(promise, ms) {
    let timer;
    return Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Git HTTP request timed out')), ms);
      }),
    ]).finally(() => clearTimeout(timer));
  }

  function buildCandidateUrls(rawUrl) {
    const envMirrors = process.env.SILLYCLIENT_GIT_MIRRORS;
    const mirrorList = (envMirrors !== undefined ? envMirrors.split(',') : DEFAULT_GIT_MIRRORS)
      .map(s => s.trim())
      .filter(Boolean)
      .map(m => (m.endsWith('/') ? m : m + '/'));
    const isGitHub = /^https:\\/\\/github\\.com\\//i.test(rawUrl);
    if (!isGitHub && !envMirrors) {
      return [{ prefix: '', url: rawUrl }];
    }
    const orderedPrefixes = [];
    if (preferredMirrorPrefix !== null && (preferredMirrorPrefix === '' || mirrorList.includes(preferredMirrorPrefix))) {
      orderedPrefixes.push(preferredMirrorPrefix);
    }
    for (const m of mirrorList) {
      if (!orderedPrefixes.includes(m)) orderedPrefixes.push(m);
    }
    if (!orderedPrefixes.includes('')) {
      const insertAt = Math.min(2, orderedPrefixes.length);
      orderedPrefixes.splice(insertAt, 0, '');
    }
    return orderedPrefixes.map(prefix => ({ prefix, url: prefix ? prefix + rawUrl : rawUrl }));
  }

  const http = {
    async request(req) {
      const candidates = buildCandidateUrls(req.url);
      const bufferedBody = await collectBody(req.body);
      const isPackTransfer = String(req.method || 'GET').toUpperCase() === 'POST' || /git-upload-pack/i.test(req.url);
      const failures = [];
      for (const candidate of candidates) {
        const timeoutMs = isPackTransfer ? 60000 : (candidate.prefix === '' ? 10000 : 15000);
        try {
          const res = await withTimeout(
            baseHttp.request({
              ...req,
              url: candidate.url,
              headers: { 'User-Agent': 'git/2.43.0 SillyClient-iOS', ...(req.headers || {}) },
              body: bufferedBody ? [Buffer.from(bufferedBody[0])] : undefined,
            }),
            timeoutMs
          );
          if (res && res.statusCode >= 200 && res.statusCode < 400) {
            preferredMirrorPrefix = candidate.prefix;
            return { ...res, url: req.url };
          }
          failures.push((candidate.prefix || 'direct') + ': HTTP ' + (res && res.statusCode));
        } catch (err) {
          failures.push((candidate.prefix || 'direct') + ': ' + (err && err.message ? err.message : String(err)));
        }
      }
      throw new Error('Git HTTP request failed for ' + req.url + ' (' + failures.join('; ') + ')');
    },
  };

  function writeGitFiles(baseDir, remoteUrl, branch, commit) {
    const gitDir = pathMod.join(baseDir, '.git');
    fsMod.mkdirSync(pathMod.join(gitDir, 'refs/heads'), { recursive: true });
    fsMod.mkdirSync(pathMod.join(gitDir, 'refs/remotes/origin'), { recursive: true });
    fsMod.mkdirSync(pathMod.join(gitDir, 'objects/info'), { recursive: true });
    fsMod.mkdirSync(pathMod.join(gitDir, 'objects/pack'), { recursive: true });
    fsMod.writeFileSync(pathMod.join(gitDir, 'HEAD'), 'ref: refs/heads/' + branch + '\\n');
    fsMod.writeFileSync(
      pathMod.join(gitDir, 'config'),
      '[core]\\n\\trepositoryformatversion = 0\\n\\tfilemode = false\\n\\tbare = false\\n\\tlogallrefupdates = true\\n' +
      '[remote "origin"]\\n\\turl = ' + remoteUrl + '\\n\\tfetch = +refs/heads/*:refs/remotes/origin/*\\n' +
      '[branch "' + branch + '"]\\n\\tremote = origin\\n\\tmerge = refs/heads/' + branch + '\\n'
    );
    fsMod.writeFileSync(pathMod.join(gitDir, 'refs/heads', branch), commit + '\\n');
    fsMod.writeFileSync(pathMod.join(gitDir, 'refs/remotes/origin', branch), commit + '\\n');
  }

  function ensureExtensionGitRepo(baseDir) {
    if (!baseDir || typeof baseDir !== 'string') return;
    const headFile = pathMod.join(baseDir, '.git/HEAD');
    if (fsMod.existsSync(headFile)) return;
    const manifestFile = pathMod.join(baseDir, 'manifest.json');
    if (!fsMod.existsSync(manifestFile)) return;
    try {
      const manifest = JSON.parse(fsMod.readFileSync(manifestFile, 'utf8'));
      const dirName = pathMod.basename(baseDir);
      const known = KNOWN_REPOS[dirName];
      let remoteUrl = '';
      let commit = '1111111111111111111111111111111111111111';
      if (known) {
        remoteUrl = 'https://github.com/' + known.repo + '.git';
        if (manifest.version === known.version) commit = known.commit;
      } else {
        const rawRepo = manifest.homePage || manifest.homepage ||
          (manifest.repository && typeof manifest.repository === 'object' ? manifest.repository.url : manifest.repository) || '';
        const parsed = new URL(String(rawRepo).trim());
        if (parsed.hostname.toLowerCase() === 'github.com') {
          const parts = parsed.pathname.split('/').filter(Boolean);
          if (parts.length >= 2) {
            remoteUrl = 'https://github.com/' + parts[0] + '/' + stripGitSuffix(parts[1]) + '.git';
          }
        }
      }
      if (remoteUrl) writeGitFiles(baseDir, remoteUrl, 'main', commit);
    } catch (_) {}
  }

  function readRef(baseDir, refPath) {
    const full = pathMod.join(baseDir, '.git', refPath);
    if (fsMod.existsSync(full) && fsMod.statSync(full).isFile()) {
      const val = fsMod.readFileSync(full, 'utf8').trim();
      if (val.startsWith('ref: ')) return readRef(baseDir, val.slice(5).trim());
      if (isSha(val)) return val.toLowerCase();
    }
    const packed = pathMod.join(baseDir, '.git/packed-refs');
    if (fsMod.existsSync(packed)) {
      for (const line of fsMod.readFileSync(packed, 'utf8').split(/\\r?\\n/)) {
        if (!line || line.startsWith('#') || line.startsWith('^')) continue;
        const [oid, ref] = line.trim().split(/\\s+/);
        if (ref === refPath && isSha(oid)) return oid.toLowerCase();
      }
    }
    return '';
  }

  function getHeadInfo(baseDir) {
    const headFile = pathMod.join(baseDir, '.git/HEAD');
    if (!fsMod.existsSync(headFile)) return { detached: false, current: '', oid: '' };
    const raw = fsMod.readFileSync(headFile, 'utf8').trim();
    if (raw.startsWith('ref: ')) {
      const ref = raw.slice(5).trim();
      const branch = ref.replace(/^refs\\/heads\\//, '');
      return { detached: false, current: branch, oid: readRef(baseDir, ref) };
    }
    return { detached: true, current: 'HEAD', oid: raw.toLowerCase() };
  }

  function getOriginUrl(baseDir) {
    const cfgFile = pathMod.join(baseDir, '.git/config');
    if (!fsMod.existsSync(cfgFile)) return '';
    const text = fsMod.readFileSync(cfgFile, 'utf8');
    const m = text.match(/\\[remote\\s+"origin"\\][\\s\\S]*?^\\s*url\\s*=\\s*(\\S+)/m);
    return m ? m[1].trim() : '';
  }

  function listRefFiles(rootDir, prefix = '') {
    if (!fsMod.existsSync(rootDir)) return [];
    const results = [];
    for (const entry of fsMod.readdirSync(rootDir, { withFileTypes: true })) {
      const rel = prefix ? prefix + '/' + entry.name : entry.name;
      const full = pathMod.join(rootDir, entry.name);
      if (entry.isDirectory()) results.push(...listRefFiles(full, rel));
      else if (entry.isFile() && entry.name !== 'HEAD') {
        const oid = fsMod.readFileSync(full, 'utf8').trim();
        if (isSha(oid)) results.push({ name: rel, oid: oid.toLowerCase() });
      }
    }
    return results;
  }

  function listWorktreeFiles(baseDir) {
    if (typeof fsMod.readdirSync !== 'function') return [];
    const results = [];
    const walk = (dir, prefix) => {
      for (const entry of fsMod.readdirSync(dir, { withFileTypes: true })) {
        if (!prefix && (entry.name === '.git' || entry.name.startsWith('.sillyclient'))) continue;
        const rel = prefix ? prefix + '/' + entry.name : entry.name;
        const full = pathMod.join(dir, entry.name);
        if (entry.isDirectory()) walk(full, rel);
        else if (entry.isFile()) results.push(rel);
      }
    };
    try { walk(baseDir, ''); } catch (_) {}
    return results;
  }

  function pruneEmptyDirs(baseDir, startDir) {
    let current = startDir;
    while (current && current !== baseDir && current.startsWith(baseDir + pathMod.sep)) {
      try {
        const entries = fsMod.readdirSync(current);
        if (entries.length > 0) break;
        fsMod.rmdirSync(current);
      } catch (_) {
        break;
      }
      current = pathMod.dirname(current);
    }
  }

  async function pruneOrphanedFilesAfterCheckout(baseDir, targetBranch, previousFiles) {
    if (!previousFiles.length || typeof isoGit.listFiles !== 'function' || typeof fsMod.unlinkSync !== 'function') return;
    try {
      const tracked = await isoGit.listFiles({ fs: fsMod, dir: baseDir, ref: targetBranch });
      if (!Array.isArray(tracked) || tracked.length === 0) return;
      const trackedSet = new Set(tracked.map(p => String(p).replace(/\\\\/g, '/')));
      for (const rel of previousFiles) {
        if (!trackedSet.has(rel)) {
          const full = pathMod.join(baseDir, rel);
          try {
            if (fsMod.existsSync(full)) {
              fsMod.unlinkSync(full);
              pruneEmptyDirs(baseDir, pathMod.dirname(full));
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  const fetchCache = new Map();
  const CheckRepoActions = {
    IS_REPO_ROOT: 'root',
    IS_REPO_HOME: 'home',
    BARE: 'bare',
    IN_TREE: 'tree',
  };
  const ResetMode = { MIXED: 'mixed', SOFT: 'soft', HARD: 'hard', MERGE: 'merge', KEEP: 'keep' };
  const CleanOptions = { DRY_RUN: 'n', FORCE: 'f', IGNORED_INCLUDED: 'x', IGNORED_ONLY: 'X', EXCLUDE: 'e', QUIET: 'q', RECURSIVE: 'd' };

  function simpleGit(optionsOrPath) {
    const requestedBaseDir = typeof optionsOrPath === 'string'
      ? optionsOrPath
      : (optionsOrPath && optionsOrPath.baseDir) || process.cwd();
    let baseDir = pathMod.resolve(requestedBaseDir);
    try { baseDir = fsMod.realpathSync(baseDir); } catch (_) {}
    ensureExtensionGitRepo(baseDir);

    async function doFetch() {
      const url = getOriginUrl(baseDir);
      if (!url) { fetchCache.delete(baseDir); return; }
      const now = Date.now();
      const cached = fetchCache.get(baseDir);
      if (cached && cached.url === url) {
        if (cached.promise) return cached.promise;
        if (now >= cached.time && now - cached.time < 3000) return cached.refs;
      }
      const entry = { url, promise: null, time: 0, refs: null };
      fetchCache.set(baseDir, entry);
      entry.promise = (async () => {
        try {
          const refs = await isoGit.listServerRefs({
            http,
            url,
            symrefs: true,
            prefix: 'refs/heads/',
          });
          if (fetchCache.get(baseDir) !== entry || getOriginUrl(baseDir) !== url) return refs;
          for (const r of refs) {
            if (r.ref && r.ref.startsWith('refs/heads/') && isSha(r.oid)) {
              const branchName = r.ref.slice('refs/heads/'.length);
              const dest = pathMod.join(baseDir, '.git/refs/remotes/origin', branchName);
              fsMod.mkdirSync(pathMod.dirname(dest), { recursive: true });
              fsMod.writeFileSync(dest, r.oid.toLowerCase() + '\\n');
            }
          }
          const head = getHeadInfo(baseDir);
          if (!head.detached && head.current && refs.length > 0) {
            const hasCurrentOnRemote = refs.some(r => r.ref === 'refs/heads/' + head.current);
            if (!hasCurrentOnRemote) {
              const fallbackRef = refs.find(r => r.ref === 'refs/heads/master') || refs[0];
              const fallbackBranch = fallbackRef.ref.slice('refs/heads/'.length);
              const oldHeadOid = head.oid || '1111111111111111111111111111111111111111';
              const newHeadPath = pathMod.join(baseDir, '.git/refs/heads', fallbackBranch);
              fsMod.mkdirSync(pathMod.dirname(newHeadPath), { recursive: true });
              if (!fsMod.existsSync(newHeadPath)) fsMod.writeFileSync(newHeadPath, oldHeadOid + '\\n');
              fsMod.writeFileSync(pathMod.join(baseDir, '.git/HEAD'), 'ref: refs/heads/' + fallbackBranch + '\\n');
              const aliasDest = pathMod.join(baseDir, '.git/refs/remotes/origin', head.current);
              fsMod.mkdirSync(pathMod.dirname(aliasDest), { recursive: true });
              fsMod.writeFileSync(aliasDest, fallbackRef.oid.toLowerCase() + '\\n');
            }
          }
          entry.refs = refs;
          entry.time = Date.now();
          return refs;
        } finally {
          if (fetchCache.get(baseDir) === entry) {
            if (entry.refs) entry.promise = null;
            else fetchCache.delete(baseDir);
          }
        }
      })();
      return entry.promise;
    }

    return {
      async checkIsRepo() {
        ensureExtensionGitRepo(baseDir);
        return fsMod.existsSync(pathMod.join(baseDir, '.git/HEAD'));
      },
      async revparse(args) {
        const arr = Array.isArray(args) ? args : [args];
        if (arr.includes('--is-shallow-repository')) return 'false';
        const head = getHeadInfo(baseDir);
        if (arr.includes('--abbrev-ref')) {
          if (arr.includes('@{u}')) return 'origin/' + (head.current || 'main');
          return head.detached ? 'HEAD' : (head.current || 'main');
        }
        if (arr.includes('--short')) return (head.oid || '').slice(0, 7);
        const target = arr[arr.length - 1] || 'HEAD';
        if (target === 'HEAD') {
          if (!head.oid) throw new Error('HEAD cannot be resolved');
          return head.oid;
        }
        if (target.startsWith('origin/')) {
          return readRef(baseDir, 'refs/remotes/' + target) || head.oid;
        }
        return readRef(baseDir, 'refs/heads/' + target) || head.oid;
      },
      async branch(args) {
        const arr = Array.isArray(args) ? args : [];
        if (arr.includes('-r')) {
          const remotes = listRefFiles(pathMod.join(baseDir, '.git/refs/remotes/origin'));
          const branches = {};
          const all = [];
          for (const r of remotes) {
            const name = 'origin/' + r.name;
            all.push(name);
            branches[name] = { current: false, name, commit: r.oid.slice(0, 7), label: r.oid.slice(0, 7) };
          }
          return { detached: false, current: '', all, branches };
        }
        const head = getHeadInfo(baseDir);
        const locals = listRefFiles(pathMod.join(baseDir, '.git/refs/heads'));
        const branches = {};
        const all = [];
        for (const l of locals) {
          all.push(l.name);
          branches[l.name] = {
            current: !head.detached && l.name === head.current,
            name: l.name,
            commit: l.oid.slice(0, 7),
            label: l.oid.slice(0, 7),
          };
        }
        if (head.current && !branches[head.current] && head.oid) {
          all.push(head.current);
          branches[head.current] = { current: !head.detached, name: head.current, commit: head.oid.slice(0, 7), label: head.oid.slice(0, 7) };
        }
        return { detached: head.detached, current: head.current, all, branches };
      },
      async branchLocal() {
        return this.branch([]);
      },
      async fetch() {
        await doFetch();
        return {};
      },
      async log(options = {}) {
        const head = getHeadInfo(baseDir);
        const fromRef = options.from || head.oid;
        const toSpec = options.to || ('origin/' + (head.current || 'main'));
        const fromOid = isSha(fromRef)
          ? fromRef.toLowerCase()
          : (readRef(baseDir, 'refs/heads/' + fromRef) || head.oid);
        const toOid = toSpec.startsWith('origin/')
          ? readRef(baseDir, 'refs/remotes/' + toSpec)
          : (isSha(toSpec) ? toSpec.toLowerCase() : readRef(baseDir, 'refs/heads/' + toSpec));
        if (!toOid || !fromOid || fromOid === toOid) {
          return { all: [], total: 0, latest: null };
        }
        const entry = { hash: toOid, date: '', message: 'Update available', refs: '', body: '', author_name: '', author_email: '' };
        return { all: [entry], total: 1, latest: entry };
      },
      async getRemotes() {
        const cleanUrl = stripGitSuffix(getOriginUrl(baseDir));
        return cleanUrl ? [{ name: 'origin', refs: { fetch: cleanUrl, push: cleanUrl } }] : [];
      },
      async pull(_remote = 'origin', branch) {
        fetchCache.delete(baseDir);
        try {
          const head = getHeadInfo(baseDir);
          const targetBranch = branch || head.current || 'main';
          const url = getOriginUrl(baseDir);
          if (!url) throw new Error('No origin remote configured');
          const previousFiles = listWorktreeFiles(baseDir);
          const fetchRes = await isoGit.fetch({
            fs: fsMod,
            http,
            dir: baseDir,
            url,
            ref: targetBranch,
            depth: 1,
            singleBranch: true,
            tags: false,
          });
          const latestOid = (fetchRes && fetchRes.fetchHead) || readRef(baseDir, 'refs/remotes/origin/' + targetBranch);
          if (!latestOid) throw new Error('Unable to resolve remote HEAD for ' + targetBranch);
          const localRefFile = pathMod.join(baseDir, '.git/refs/heads', targetBranch);
          fsMod.mkdirSync(pathMod.dirname(localRefFile), { recursive: true });
          fsMod.writeFileSync(localRefFile, latestOid + '\\n');
          const remoteRefFile = pathMod.join(baseDir, '.git/refs/remotes/origin', targetBranch);
          fsMod.mkdirSync(pathMod.dirname(remoteRefFile), { recursive: true });
          fsMod.writeFileSync(remoteRefFile, latestOid + '\\n');
          fsMod.writeFileSync(pathMod.join(baseDir, '.git/HEAD'), 'ref: refs/heads/' + targetBranch + '\\n');
          await isoGit.checkout({ fs: fsMod, dir: baseDir, ref: targetBranch, force: true });
          await pruneOrphanedFilesAfterCheckout(baseDir, targetBranch, previousFiles);
          return {};
        } finally { fetchCache.delete(baseDir); }
      },
      async remote() {
        return '';
      },
      async checkout(branch) {
        fetchCache.delete(baseDir);
        try {
          const targetBranch = String(branch).replace(/^origin\\//, '');
          const url = getOriginUrl(baseDir);
          const previousFiles = listWorktreeFiles(baseDir);
          if (url) {
            const fetchRes = await isoGit.fetch({
              fs: fsMod,
              http,
              dir: baseDir,
              url,
              ref: targetBranch,
              depth: 1,
              singleBranch: true,
              tags: false,
            });
            const oid = (fetchRes && fetchRes.fetchHead) || readRef(baseDir, 'refs/remotes/origin/' + targetBranch);
            if (oid) {
              const localRefFile = pathMod.join(baseDir, '.git/refs/heads', targetBranch);
              fsMod.mkdirSync(pathMod.dirname(localRefFile), { recursive: true });
              fsMod.writeFileSync(localRefFile, oid + '\\n');
            }
          }
          fsMod.writeFileSync(pathMod.join(baseDir, '.git/HEAD'), 'ref: refs/heads/' + targetBranch + '\\n');
          await isoGit.checkout({ fs: fsMod, dir: baseDir, ref: targetBranch, force: true });
          await pruneOrphanedFilesAfterCheckout(baseDir, targetBranch, previousFiles);
        } finally { fetchCache.delete(baseDir); }
      },
      async checkoutBranch(localBranch, startPoint) {
        await this.checkout(localBranch || startPoint);
      },
      async clone(url, localPath, options) {
        let ref;
        let depth = 1;
        if (Array.isArray(options)) {
          const bIdx = options.indexOf('-b') >= 0 ? options.indexOf('-b') : options.indexOf('--branch');
          if (bIdx >= 0 && options[bIdx + 1]) ref = options[bIdx + 1];
        } else if (options && typeof options === 'object') {
          if (options['--branch']) ref = options['--branch'];
          else if (options.branch) ref = options.branch;
          if (options['--depth'] !== undefined) depth = Number(options['--depth']) || 1;
          else if (options.depth !== undefined) depth = Number(options.depth) || 1;
        }
        await isoGit.clone({
          fs: fsMod,
          http,
          dir: localPath,
          url,
          ref,
          depth,
          singleBranch: Boolean(ref) || depth !== undefined,
        });
      },
      async show() {
        return '';
      },
    };
  }

  return { http, CheckRepoActions, ResetMode, CleanOptions, simpleGit };
}

const bridge = createBridge(fs, path, isomorphicGit, origHttp);
module.exports = Object.assign(bridge.simpleGit, bridge, {
  default: bridge.simpleGit,
  gitP: bridge.simpleGit,
  createBridge,
});
`;
    fs.writeFileSync(bridgeCjsPath, bridgeSource, 'utf8');

    const isoHttpCjsWrapper = `'use strict';
// SillyClient iOS Git HTTP bridge
const bridge = require('../../../.sillyclient-ios-git-bridge.cjs');
module.exports = bridge.http;
`;
    const isoHttpEsmWrapper = `// SillyClient iOS Git HTTP bridge
import bridge from '../../../.sillyclient-ios-git-bridge.cjs';
export const request = bridge.http.request;
export default bridge.http;
`;
    fs.writeFileSync(isoGitHttpCjs, isoHttpCjsWrapper, 'utf8');
    if (fs.existsSync(isoGitHttpEsm)) {
      fs.writeFileSync(isoGitHttpEsm, isoHttpEsmWrapper, 'utf8');
    }

    const simpleGitCjs = path.join(simpleGitDir, 'dist', 'cjs', 'index.js');
    const simpleGitEsm = path.join(simpleGitDir, 'dist', 'esm', 'index.js');
    const simpleGitPromise = path.join(simpleGitDir, 'promise.js');
    if (fs.existsSync(simpleGitCjs)) {
      fs.writeFileSync(simpleGitCjs, `'use strict';
// SillyClient iOS simple-git bridge
module.exports = require('../../../.sillyclient-ios-git-bridge.cjs');
`, 'utf8');
    }
    if (fs.existsSync(simpleGitEsm)) {
      fs.writeFileSync(simpleGitEsm, `// SillyClient iOS simple-git bridge
import bridge from '../../../.sillyclient-ios-git-bridge.cjs';
export const simpleGit = bridge.simpleGit;
export const gitP = bridge.simpleGit;
export const CheckRepoActions = bridge.CheckRepoActions;
export const ResetMode = bridge.ResetMode;
export const CleanOptions = bridge.CleanOptions;
export default bridge.simpleGit;
`, 'utf8');
    }
    if (fs.existsSync(simpleGitPromise)) {
      fs.writeFileSync(simpleGitPromise, `'use strict';
// SillyClient iOS simple-git bridge
module.exports = require('../.sillyclient-ios-git-bridge.cjs');
`, 'utf8');
    }
    console.log(`[patch-sillytavern] [7c/8] Successfully installed iOS pure-JS Git bridge (simple-git + isomorphic-git/http/node): ${bridgeCjsPath}`);
  }
}

// 8. 深度递归扫描并防御性替换 node_modules 中的任意 \p{Cc}, \p{L}, \p{N} 与 fatal: true 遗留
function deepScanAndPatch(dir) {
  if (!fs.existsSync(dir)) return;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== '.git' && entry.name !== 'build') {
          deepScanAndPatch(fullPath);
        }
      } else if (entry.isFile() && (entry.name.endsWith('.js') || entry.name.endsWith('.mjs') || entry.name.endsWith('.cjs'))) {
        try {
          let code = fs.readFileSync(fullPath, 'utf8');
          let modified = false;

          if (code.includes(origPatStr)) {
            code = code.replaceAll(origPatStr, safePatStr);
            modified = true;
          }

          if (code.includes('\\p{Cc}') || code.includes('\\p{Cf}')) {
            code = code.replace(
              /\/\^\\p\{Cc\}\|\\p\{Cf\}\|\\p\{Co\}\|\\p\{Cs\}\$\/u/g,
              '/^[\\u0000-\\u001F\\u007F-\\u009F\\uD800-\\uDFFF\\uE000-\\uF8FF]$/'
            );
            code = code.replace(
              /\\p\{Cc\}\|\\p\{Cf\}\|\\p\{Co\}\|\\p\{Cs\}/g,
              '[\\u0000-\\u001F\\u007F-\\u009F\\uD800-\\uDFFF\\uE000-\\uF8FF]'
            );
            modified = true;
          }

          if (code.includes('\\p{L}') || code.includes('\\p{N}') || code.includes('\\p{Lu}') || code.includes('\\p{Ll}')) {
            code = code.replace(/\\p\{L\}/g, 'a-zA-Z\\u0080-\\uFFFF');
            code = code.replace(/\\p\{N\}/g, '0-9');
            code = code.replace(/\\p\{Lu\}|\\p\{Uppercase_Letter\}/g, 'A-Z\\u0080-\\uFFFF');
            code = code.replace(/\\p\{Ll\}|\\p\{Lowercase_Letter\}/g, 'a-z');
            code = code.replace(/\\p\{Alpha\}/g, 'a-zA-Z\\u0080-\\uFFFF');
            code = code.replace(/\\p\{XID_Start\}/g, 'a-zA-Z\\u0080-\\uFFFF');
            code = code.replace(/\\p\{XID_Continue\}/g, 'a-zA-Z0-9\\u0080-\\uFFFF');
            modified = true;
          }

          if (code.includes('fatal: true') && (code.includes('TextDecoder') || fullPath.includes('@jsquash') || fullPath.includes('squoosh') || fullPath.includes('isomorphic-git'))) {
            code = code.replace(/ignoreBOM:\s*true,\s*fatal:\s*true/g, 'ignoreBOM: true');
            code = code.replace(/fatal:\s*true/g, 'fatal: false');
            modified = true;
          }

          if (modified) {
            fs.writeFileSync(fullPath, code, 'utf8');
            console.log(`[patch-sillytavern] [7/7] Deep patched: ${fullPath}`);
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
}

const nodeModulesDir = path.join(targetDir, 'node_modules');
if (fs.existsSync(nodeModulesDir)) {
  console.log(`[patch-sillytavern] [7/7] Scanning node_modules for remaining ICU regexes & TextDecoder fatal options...`);
  deepScanAndPatch(nodeModulesDir);
}

console.log('[patch-sillytavern] All SillyTavern iOS patches executed successfully!');
