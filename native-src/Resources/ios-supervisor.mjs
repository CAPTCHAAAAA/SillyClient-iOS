import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { Worker } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';

const directory = process.env.SILLYCLIENT_CONTROL_DIR;
if (!directory) throw new Error('SILLYCLIENT_CONTROL_DIR is required');
fs.mkdirSync(directory, { recursive: true });
const requestDirectory = path.join(directory, 'requests');
const responseDirectory = path.join(directory, 'responses');
fs.mkdirSync(requestDirectory, { recursive: true });
fs.mkdirSync(responseDirectory, { recursive: true });
let active = null;
let scanning = false;
let rescan = false;
let scheduled = false;
const cancelledOperations = new Map();

function operationKey(request) {
    return request.instanceId && request.operationId ? `${request.instanceId}:${request.operationId}` : null;
}

function rememberCancellation(request) {
    const key = operationKey(request);
    if (!key) return;
    cancelledOperations.set(key, Date.now());
    for (const [key, created] of cancelledOperations) {
        if (Date.now() - created > 5 * 60_000 || cancelledOperations.size > 512) cancelledOperations.delete(key);
    }
}

function write(name, value) {
    const target = path.join(directory, name);
    const temporary = `${target}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(value));
    fs.renameSync(temporary, target);
}

function publish(state, session = active, error) {
    write('status.json', {
        state, instanceId: session?.instanceId, operationId: session?.operationId,
        port: session?.port, url: session ? `http://${session.host === '::1' ? '[::1]' : session.host}:${session.port}/` : '',
        error: error ? String(error.message || error).slice(0, 1000) : undefined,
    });
}

function answer(request, value) {
    write(path.join('responses', `${request.requestId}.json`), value);
}

function checkIdentity(request, session) {
    return (!request.instanceId || request.instanceId === session?.instanceId)
        && (!request.operationId || request.operationId === session?.operationId);
}

async function stop(request) {
    if (!active) { rememberCancellation(request); return { success: true }; }
    if (!checkIdentity(request, active)) throw new Error('The requested session is no longer current');
    rememberCancellation(request);
    const previous = active;
    previous.ending = true;
    if (previous.pending) {
        answer(previous.pending, { success: false, error: 'Operation cancelled' });
        previous.pending = null;
    }
    clearTimeout(previous.timeout);
    await previous.worker.terminate();
    if (await listenerOpen(previous.port, previous.host)) throw new Error('The listener did not close after worker termination');
    if (active === previous) active = null;
    publish('stopped', previous);
    return { success: true };
}

function listenerOpen(port, host = '127.0.0.1') {
    return new Promise(resolve => {
        const socket = net.createConnection({ host, port });
        let finished = false;
        const finish = value => {
            if (finished) return;
            finished = true;
            socket.destroy();
            resolve(value);
        };
        socket.once('connect', () => finish(true));
        socket.once('error', () => finish(false));
        socket.setTimeout(1500, () => finish(true));
    });
}

function probe(port, host) {
    return new Promise(resolve => {
        const request = http.get({
            hostname: host, port, path: '/', timeout: 2000,
        }, response => {
            response.resume();
            resolve(response.statusCode === 200);
        });
        request.on('timeout', () => request.destroy());
        request.on('error', () => resolve(false));
    });
}

async function start(request) {
    if (!Number.isInteger(request.port) || request.port < 1 || request.port > 65535) {
        throw new Error('Invalid server port');
    }
    if (!/^[a-zA-Z0-9_-]{1,128}$/.test(request.instanceId || '')
        || !/^[a-zA-Z0-9_-]{1,128}$/.test(request.operationId || '')) {
        throw new Error('Invalid operation identity');
    }
    if (cancelledOperations.has(operationKey(request))) throw new Error('Operation cancelled before startup');
    if (active) {
        if (checkIdentity(request, active) && active.port === request.port && active.ready && !active.ending) {
            answer(request, { success: true, ready: true });
            return;
        }
        throw new Error('Stop the current session before starting another instance');
    }
    const serverDirectory = fs.realpathSync(request.serverDirectory);
    const managedRoot = process.env.SILLYCLIENT_INSTANCES_ROOT;
    if (managedRoot) {
        const root = fs.realpathSync(managedRoot);
        const relative = path.relative(root, serverDirectory);
        if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
            throw new Error('The runtime is outside managed instance storage');
        }
        for (const raw of [request.serverDirectory, request.dataDirectory, request.configPath]) {
            if (typeof raw !== 'string') throw new Error('The runtime path is missing');
            const relative = path.relative(root, raw);
            if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Unsafe runtime path');
            let component = root;
            for (const segment of relative.split(path.sep)) {
                component = path.join(component, segment);
                if (fs.lstatSync(component).isSymbolicLink()) throw new Error('Runtime paths cannot contain links');
            }
        }
    }
    const loader = path.join(serverDirectory, 'ios-loader.mjs');
    if (!fs.statSync(path.join(serverDirectory, 'server.js')).isFile()
        || !fs.statSync(loader).isFile()) throw new Error('The prepared iOS runtime is incomplete');
    process.chdir(serverDirectory);
    const session = {
        instanceId: request.instanceId, operationId: request.operationId,
        port: request.port, host: request.ipv4 === false ? '::1' : '127.0.0.1', ready: false, pending: request,
    };
    if (await listenerOpen(session.port, session.host)) throw new Error('The requested port is already occupied');
    const worker = new Worker(pathToFileURL(loader), {
        execArgv: process.execArgv.filter(argument => argument !== '--expose-gc'),
        env: {
            ...process.env, TARVEN_SERVER_DIR: serverDirectory,
            DATA_DIR: request.dataDirectory, PORT: String(request.port),
            SILLYCLIENT_OPERATION_ID: request.operationId,
            SILLYCLIENT_WORKER: '1',
        },
        workerData: {
            arguments: [
                loader, `--port=${request.port}`, `--dataRoot=${request.dataDirectory}`,
                ...(request.configPath ? [`--configPath=${request.configPath}`] : ['--listen=false']),
                '--browserLaunchEnabled=false',
            ],
        },
    });
    session.worker = worker;
    active = session;
    publish('starting', session);
    const fail = async error => {
        if (active !== session || session.ending) return;
        session.ending = true;
        clearTimeout(session.timeout);
        await worker.terminate();
        if (active === session) active = null;
        publish('failed', session, error);
        if (session.pending) {
            answer(session.pending, { success: false, error: String(error.message || error).slice(0, 1000) });
            session.pending = null;
        }
    };
    worker.on('message', async message => {
        if (active !== session || session.ending) return;
        if (message.type === 'failure') {
            await fail(new Error(message.message));
        } else if (message.type === 'ready' && !session.ready && !session.probing) {
            session.probing = true;
            if (!await probe(session.port, session.host) || active !== session || session.ending) {
                if (active === session) await fail(new Error('The ready worker did not return HTTP 200'));
                return;
            }
            clearTimeout(session.timeout);
            session.ready = true;
            publish('ready', session);
            if (session.pending) {
                answer(session.pending, { success: true, ready: true });
                session.pending = null;
            }
        }
    });
    worker.on('error', fail);
    worker.on('exit', code => {
        if (active === session && !session.ending) void fail(new Error(`The server worker exited (${code})`));
    });
    const timeout = Math.max(1000, Math.min(90000, Number(process.env.SILLYCLIENT_STARTUP_TIMEOUT) || 90000));
    session.timeout = setTimeout(() => void fail(new Error('Server startup timed out')), timeout);
}

async function consume(name) {
    if (!/^[a-zA-Z0-9_-]+\.json$/.test(name)) return;
    const file = path.join(requestDirectory, name);
    let bytes;
    try {
        const before = fs.lstatSync(file);
        if (!before.isFile() || before.isSymbolicLink() || before.size > 65536) {
            fs.unlinkSync(file);
            return;
        }
        const descriptor = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
        try {
            const opened = fs.fstatSync(descriptor);
            if (opened.ino !== before.ino || (before.dev !== 0 && opened.dev !== before.dev) || opened.size !== before.size) {
                throw new Error('Mailbox identity changed before opening');
            }
            bytes = Buffer.alloc(before.size);
            const length = fs.readSync(descriptor, bytes, 0, bytes.length, 0);
            if (length !== bytes.length || fs.fstatSync(descriptor).size !== before.size) {
                throw new Error('Mailbox size changed during reading');
            }
        } finally { fs.closeSync(descriptor); }
        fs.unlinkSync(file);
    } catch (error) {
        console.error('[iOS supervisor] Mailbox read rejected:', error.code || error.message);
        return;
    }
    let request;
    try {
        request = JSON.parse(bytes);
        if (request.requestId !== name.slice(0, -5)) throw new Error('Invalid request identity');
        if (request.action === 'start') {
            await start(request);
        } else if (request.action === 'stop') {
            answer(request, await stop(request));
        } else if (request.action === 'gc') {
            if (typeof globalThis.gc !== 'function') throw new Error('Runtime GC is unavailable');
            globalThis.gc();
            active?.worker.postMessage({ type: 'gc' });
            answer(request, { success: true, scope: 'host', workerRequested: !!active });
        } else {
            throw new Error('Unsupported runtime command');
        }
    } catch (error) {
        if (request?.requestId === name.slice(0, -5)) {
            answer(request, { success: false, error: String(error.message || error).slice(0, 1000) });
        }
    }
}

function scan() {
    if (scanning) { rescan = true; return; }
    if (scheduled) return;
    scheduled = true;
    setImmediate(async () => {
        scheduled = false;
        scanning = true;
        try {
            do {
                rescan = false;
                const names = [];
                const directory = fs.opendirSync(requestDirectory);
                try {
                    let entry;
                    while ((entry = directory.readSync()) && names.length < 256) {
                        if (entry.name.endsWith('.json')) names.push(entry.name);
                    }
                } finally { directory.closeSync(); }
                for (const name of names.sort()) await consume(name);
                if (names.length === 256) rescan = true;
            } while (rescan);
        } catch (error) { console.error('[iOS supervisor]', error.message); }
        finally { scanning = false; }
    });
}

publish('idle');
fs.watch(requestDirectory, scan);
scan();
