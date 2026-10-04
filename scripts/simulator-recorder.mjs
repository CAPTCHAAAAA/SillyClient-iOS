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

// Record start timestamp so test runner can calculate exact relative seconds
const startTime = Date.now();
fs.writeFileSync(path.join(outDir, 'recorder-start-time.txt'), String(startTime), 'utf8');

const videoPath = path.join(outDir, 'simulator-walkthrough.mp4');
console.log(`[Recorder] Starting screen recording to ${videoPath}...`);

// Spawn xcrun simctl io device recordVideo --codec=h264
const videoProcess = spawn('xcrun', [
    'simctl', 'io', device, 'recordVideo',
    '--codec=h264',
    videoPath
], {
    stdio: 'inherit'
});

videoProcess.on('error', err => {
    console.error(`[Recorder] Video recording process error: ${err.message}`);
});

let stopping = false;

async function stopRecording() {
    if (stopping) return;
    stopping = true;
    console.log('[Recorder] Received termination signal, gracefully finalizing video recording...');
    
    // Send SIGINT to recordVideo process to allow mp4 container finalization
    videoProcess.kill('SIGINT');
    
    // Wait for videoProcess to close cleanly
    await new Promise(resolve => {
        const timeout = setTimeout(() => {
            console.warn('[Recorder] Video process close timed out after 12s');
            resolve();
        }, 12000);
        videoProcess.on('close', (code, signal) => {
            clearTimeout(timeout);
            console.log(`[Recorder] Video recording finalized cleanly (code ${code}, signal ${signal})`);
            resolve();
        });
    });

    // Check if video file exists and report size
    if (fs.existsSync(videoPath)) {
        const stats = fs.statSync(videoPath);
        console.log(`[Recorder] Recorded MP4 video size: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
    } else {
        console.warn(`[Recorder] Warning: Video file ${videoPath} not found`);
    }

    // Now extract step frames from video using swift extract-frames.swift
    const timestampsPath = path.join(outDir, 'step-timestamps.json');
    const extractScript = path.resolve('scripts/extract-frames.swift');
    if (fs.existsSync(timestampsPath) && fs.existsSync(extractScript)) {
        console.log(`[Recorder] Extracting step screenshots using Swift AVAssetImageGenerator...`);
        try {
            execFileSync('swift', [extractScript, videoPath, timestampsPath], {
                stdio: 'inherit',
                timeout: 60000
            });
        } catch (err) {
            console.error(`[Recorder] Frame extraction failed: ${err.message}`);
        }
    } else {
        console.warn('[Recorder] Timestamps or extract script missing, skipping frame extraction');
    }

    // Capture final screen
    try {
        const finalPng = path.join(outDir, '99-simulator-final.png');
        execFileSync('xcrun', ['simctl', 'io', device, 'screenshot', finalPng], {
            timeout: 10000,
            stdio: 'ignore'
        });
        console.log(`[Recorder] Captured final screenshot: 99-simulator-final.png`);
    } catch (e) {
        console.warn(`[Recorder] Could not capture final screenshot: ${e.message}`);
    }

    process.exit(0);
}

process.on('SIGINT', () => { void stopRecording(); });
process.on('SIGTERM', () => { void stopRecording(); });
