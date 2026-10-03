import fs from 'node:fs';
import http from 'node:http';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const { Worker, isMainThread, parentPort } = await import('node:worker_threads');
if (!isMainThread) {
    const server = http.createServer((_, response) => response.end('node-mobile-worker'));
    server.listen(0, '127.0.0.1', () => parentPort.postMessage({ port: server.address().port }));
} else {
    const report = process.env.SILLYCLIENT_PROBE_REPORT;
    const result = { success: false, nodeVersion: process.version, cycles: [] };
    const watchdog = setTimeout(() => {
        result.error = 'Capability probe timed out';
        fs.writeFileSync(report, JSON.stringify(result));
    }, 30000);
    const request = port => new Promise((resolve, reject) => {
        const req = http.get(`http://127.0.0.1:${port}/`, response => {
            let body = '';
            response.setEncoding('utf8');
            response.on('data', data => body += data);
            response.on('end', () => resolve({ status: response.statusCode, body }));
        });
        req.once('error', reject);
        req.setTimeout(1500, () => req.destroy(new Error('HTTP probe timed out')));
    });
    let worker;
    try {
        for (let cycle = 0; cycle < 2; cycle++) {
            worker = new Worker(fileURLToPath(import.meta.url));
            const [{ port }] = await once(worker, 'message');
            const response = await request(port);
            if (response.status !== 200 || response.body !== 'node-mobile-worker') throw new Error('Worker HTTP response did not match');
            await worker.terminate();
            worker = null;
            let closed = false;
            try { await request(port); } catch { closed = true; }
            if (!closed) throw new Error('Worker termination left its listener active');
            result.cycles.push({ cycle, port, httpStatus: response.status, portClosedAfterTermination: closed });
        }
        result.success = true;
        result.workerThreads = true;
    } catch (error) {
        result.error = String(error?.message || error);
    } finally {
        if (worker) await worker.terminate();
        clearTimeout(watchdog);
        fs.writeFileSync(report, JSON.stringify(result, null, 2));
    }
}
