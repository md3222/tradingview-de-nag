// Minimal CDP driver: node cdp.js <wsUrl> <expr> [...]
const wsUrl = process.argv[2];
const exprs = process.argv.slice(3);

function connect(url) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(url);
    ws.onopen = () => res(ws);
    ws.onerror = (e) => rej(new Error('ws error: ' + (e.message || e.type)));
  });
}

function send(ws, id, method, params) {
  return new Promise((res, rej) => {
    const to = setTimeout(() => rej(new Error('timeout ' + method)), 20000);
    const onMsg = (ev) => {
      let m;
      try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id === id) {
        clearTimeout(to);
        ws.removeEventListener('message', onMsg);
        m.error ? rej(new Error(method + ': ' + JSON.stringify(m.error))) : res(m.result);
      }
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

(async () => {
  const ws = await connect(wsUrl);
  let id = 0;
  for (const expr of exprs) {
    try {
      const r = await send(ws, ++id, 'Runtime.evaluate', {
        expression: expr,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true,
      });
      if (r.exceptionDetails) {
        console.log('EXC:', JSON.stringify(r.exceptionDetails.exception?.description || r.exceptionDetails.text));
      } else {
        console.log(JSON.stringify(r.result.value));
      }
    } catch (e) {
      console.log('ERR:', e.message);
    }
  }
  ws.close();
})();
