const checks = [
  ['href', 'location.href'],
  ['guard', 'window.__tvPaywallGuardInstalled'],
  ['watch', 'window.__tvTrialWatchInstalled'],
  ['auth', 'window.is_authenticated'],
  ['user', 'window.user && window.user.username'],
  ['toggle', 'window.TradingView && window.TradingView.isFeatureEnabled && window.TradingView.isFeatureEnabled("tvd_paid_only_access")'],
  ['marker', 'window.localStorage.getItem("__tv_paywall_guard")'],
  ['modal', 'document.body.innerText.includes("custom intervals") || document.body.innerText.includes("Analyze markets")'],
];

(async () => {
  const res = await fetch('http://127.0.0.1:9222/json');
  const targets = await res.json();
  const page = targets.find(t => t.type === 'page' && t.url.startsWith('https://www.tradingview.com/chart'));
  if (!page) {
    console.log('NO_CHART_TARGET');
    for (const t of targets) console.log(t.type, t.url);
    process.exit(1);
  }
  console.log('TARGET', page.url);
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const evalExpr = (expr) => new Promise((resolve, reject) => {
    const myId = ++id;
    const onMsg = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === myId) { ws.removeEventListener('message', onMsg); resolve(m); }
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify({ id: myId, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } }));
    setTimeout(() => reject(new Error('timeout ' + expr)), 12000);
  });
  for (const [name, expr] of checks) {
    try {
      const r = await evalExpr(expr);
      if (r.result && r.result.exceptionDetails) console.log(name, 'EXC', JSON.stringify(r.result.exceptionDetails));
      else console.log(name, JSON.stringify(r.result && r.result.result ? r.result.result.value : null));
    } catch (e) { console.log(name, 'ERR', e.message); }
  }
  try {
    await evalExpr('(()=>{window.TradingViewApi.activeChart().setResolution("2");return "set2"})()');
    await new Promise(r => setTimeout(r, 4000));
    for (const [name, expr] of [
      ['res', 'window.TradingViewApi.activeChart().resolution()'],
      ['modal2', 'document.body.innerText.includes("custom intervals") || document.body.innerText.includes("Analyze markets")'],
    ]) {
      const r = await evalExpr(expr);
      console.log(name, JSON.stringify(r.result && r.result.result ? r.result.result.value : null));
    }
  } catch (e) { console.log('test2m ERR', e.message); }
  ws.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
