import { WebSocketServer } from 'ws';

const port = Number(process.env.PORT ?? 9103);

const wss = new WebSocketServer({
  host: '127.0.0.1',
  port,
  perMessageDeflate: false,
  maxPayload: 32 * 1024 * 1024,
});

const applicationPrefix = Buffer.from('{"op":');
const applicationAck = '{"ok":true}';

wss.on('connection', (ws, request) => {
  const application = request.url?.startsWith('/application');

  ws.on('message', (data, isBinary) => {
    if (application) {
      if (isBinary || data.length < applicationPrefix.length ||
          !data.subarray(0, applicationPrefix.length).equals(applicationPrefix)) {
        ws.terminate();
        return;
      }

      ws.send(applicationAck, {
        binary: false,
        compress: false,
      });
      return;
    }

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
