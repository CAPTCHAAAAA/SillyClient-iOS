import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const [device, evidenceDir = 'evidence'] = process.argv.slice(2);
if (!device) {
    console.error('Usage: node scripts/simulator-recorder.mjs <deviceUuid> [evidenceDir]');
    process.exit(1);
}

const outDir = path.resolve(evidenceDir);
fs.mkdirSync(outDir, { recursive: true });

function sanitizeFilename(text) {
    return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);
}

function captureScreenshot(name) {
    const filename = path.join(outDir, `${name}.png`);
    try {
        execFileSync('xcrun', ['simctl', 'io', device, 'screenshot', filename], {
            timeout: 15000,
            stdio: 'ignore',
        });
        console.log(`[Recorder] Captured screenshot: ${name}.png`);
    } catch (error) {
        console.warn(`[Recorder] Failed to capture ${name}: ${error.message}`);
    }
}

// 1. Initial screenshot
captureScreenshot('00-simulator-boot');

// 2. Start video recording in background
const videoPath = path.join(outDir, 'simulator-walkthrough.mp4');
console.log(`[Recorder] Starting screen recording to ${videoPath}...`);
const videoProcess = spawn('xcrun', ['simctl', 'io', device, 'recordVideo', videoPath], {
    stdio: 'ignore',
});

videoProcess.on('error', err => {
    console.warn(`[Recorder] Video recording process error: ${err.message}`);
});

// 3. Monitor simulator-results.json for step completions
const resultsFile = path.join(outDir, 'simulator-results.json');
let capturedSteps = 0;

const pollInterval = setInterval(() => {
    try {
        if (!fs.existsSync(resultsFile)) return;
        const data = JSON.parse(fs.readFileSync(resultsFile, 'utf8'));
        const results = Array.isArray(data?.results) ? data.results : [];
        while (capturedSteps < results.length) {
            const step = results[capturedSteps];
            capturedSteps++;
            const num = String(capturedSteps).padStart(2, '0');
            const slug = sanitizeFilename(step.name || `step-${capturedSteps}`);
            captureScreenshot(`${num}-${slug}`);
        }
    } catch {}
}, 300);

// 4. Graceful shutdown handler
function stopRecording() {
    clearInterval(pollInterval);
    captureScreenshot('99-simulator-final');
    if (videoProcess && !videoProcess.killed) {
        console.log('[Recorder] Stopping video recording cleanly...');
        videoProcess.kill('SIGINT');
    }
    setTimeout(() => {
        process.exit(0);
    }, 2000);
}

process.on('SIGINT', stopRecording);
process.on('SIGTERM', stopRecording);
