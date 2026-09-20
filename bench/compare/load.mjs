import WebSocket from 'ws';

function parseArgs(argv) {
  const option = {};
  for (let i = 2; i < argv.length; ++i) {
    const key = argv[i];
    if (!key.startsWith('--') || i + 1 >= argv.length) {
      throw new Error(`invalid argument: ${key}`);
    }
    option[key.slice(2)] = argv[++i];
  }
  return option;
}

const option = parseArgs(process.argv);
const label = option.label ?? 'server';
const host = option.host ?? '127.0.0.1';
const port = Number(option.port ?? 9002);
const mode = option.mode ?? 'echo';
const type = option.type ?? 'binary';
const bytes = Number(option.bytes ?? 64);
const clients = Number(option.clients ?? 1);
const windowSize = Number(option.window ?? 32);
const warmupSeconds = Number(option.warmup ?? 0.5);
const measureSeconds = Number(option.seconds ?? 1.5);

if (!Number.isInteger(port) || port < 1) throw new Error('invalid --port');
if (!['echo', 'application'].includes(mode)) throw new Error('invalid --mode');
if (!['binary', 'text'].includes(type)) throw new Error('invalid --type');
if (!Number.isInteger(bytes) || bytes < 1) throw new Error('invalid --bytes');
if (!Number.isInteger(clients) || clients < 1) throw new Error('invalid --clients');
if (!Number.isInteger(windowSize) || windowSize < 1) throw new Error('invalid --window');
if (!(warmupSeconds >= 0)) throw new Error('invalid --warmup');
if (!(measureSeconds > 0)) throw new Error('invalid --seconds');

const binaryPayload = Buffer.alloc(bytes, 0x78);
const textPayload = 'x'.repeat(bytes);
const applicationPrefix = '{"op":"message","room":"bench","body":"';
const applicationSuffix = '","seq":12345}';
if (mode === 'application' &&
    bytes < applicationPrefix.length + applicationSuffix.length) {
  throw new Error('application payload is too small');
}
const applicationPayload = applicationPrefix
  + 'x'.repeat(Math.max(0, bytes - applicationPrefix.length - applicationSuffix.length))
  + applicationSuffix;
const applicationAck = '{"ok":true}';
const payload = mode === 'application'
  ? applicationPayload
  : (type === 'binary' ? binaryPayload : textPayload);
const sockets = [];

let opened = 0;
let count = 0;
let measuring = false;
let stopped = false;
let startNs = 0n;
let finished = false;
let setupTimer;

function fail(message) {
  if (finished) return;
  finished = true;
  stopped = true;
  for (const ws of sockets) {
    try { ws.terminate(); } catch {}
  }
  console.error(message);
  process.exitCode = 1;
}

function sendOne(ws) {
  if (stopped) return;
  ws.send(payload, {
    binary: mode === 'application' ? false : type === 'binary',
    compress: false,
  });
}

function finish() {
  if (finished) return;
  finished = true;
  stopped = true;

  const endNs = process.hrtime.bigint();
  const elapsed = Number(endNs - startNs) / 1e9;
  const rate = count / elapsed;
  const mib = rate * bytes / (1024 * 1024);

  for (const ws of sockets) {
    try { ws.terminate(); } catch {}
  }

  console.log([
    label,
    mode === 'application' ? 'application' : type,
    bytes,
    clients,
    windowSize,
    count,
    elapsed.toFixed(6),
    rate.toFixed(0),
    mib.toFixed(2),
  ].join(','));
}

function allOpened() {
  for (const ws of sockets) {
    for (let i = 0; i < windowSize; ++i) sendOne(ws);
  }

  setTimeout(() => {
    count = 0;
    measuring = true;
    startNs = process.hrtime.bigint();
    setTimeout(finish, measureSeconds * 1000);
  }, warmupSeconds * 1000);
}

for (let i = 0; i < clients; ++i) {
  const path = mode === 'application'
    ? '/application'
    : `/benchmark?type=${type}`;
  const ws = new WebSocket(`ws://${host}:${port}${path}`, {
    perMessageDeflate: false,
    maxPayload: 32 * 1024 * 1024,
  });
  sockets.push(ws);

  ws.on('open', () => {
    ++opened;
    if (opened === clients) {
      clearTimeout(setupTimer);
      allOpened();
    }
  });

  ws.on('message', (data, isBinary) => {
    if (stopped) return;

    if (mode === 'application') {
      if (isBinary || data.toString() !== applicationAck) {
        fail('application acknowledgement mismatch');
        return;
      }
    } else {
      const expectedBinary = type === 'binary';
      if (isBinary !== expectedBinary) {
        fail(`message type mismatch: expected ${type}`);
        return;
      }

      if (data.length !== bytes) {
        fail(`message size mismatch: expected ${bytes}, got ${data.length}`);
        return;
      }
    }

    if (measuring) ++count;
    sendOne(ws);
  });

  ws.on('error', error => {
    fail(`WebSocket load-generator error: ${error.message}`);
  });

  ws.on('close', () => {
    if (!stopped) fail('server closed a benchmark connection early');
  });
}

setupTimer = setTimeout(() => {
  if (!finished && opened !== clients) {
    fail(`connection setup timed out: opened ${opened}/${clients}`);
  }
}, 10_000);
