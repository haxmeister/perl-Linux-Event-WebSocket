import { WebSocketServer } from 'ws';

const port = Number(process.env.PORT ?? 9103);

const wss = new WebSocketServer({
  host: '127.0.0.1',
  port,
  perMessageDeflate: false,
  maxPayload: 32 * 1024 * 1024,
});

wss.on('connection', ws => {
  ws.on('message', (data, isBinary) => {
    ws.send(data, {
      binary: isBinary,
      compress: false,
    });
  });
});

wss.on('listening', () => {
  console.log(`READY 127.0.0.1:${port}`);
});

wss.on('error', error => {
  console.error(error);
  process.exitCode = 1;
});
