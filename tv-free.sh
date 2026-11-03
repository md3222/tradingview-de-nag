#!/usr/bin/env bash
# tv-free.sh — TradingView desktop free-tier de-nag (Linux, deb install)
#
# Removes the stuff that fights the free tier:
#   1. the unclosable "Analyze markets in TradingView Desktop" paywall
#   2. the "custom intervals" upsell on 2m/7m/30s/tick timeframes
#   3. the Google ad toast (optional /etc/hosts sinkhole)
#   4. a passive watcher that notifies if the server ever offers a trial
#
# It does NOT unlock paid data or features. 2m still falls back; entitlements
# stay whatever the server says.
#
# Usage:
#   ./tv-free.sh                 # patch app + hosts sinkhole
#   ./tv-free.sh --no-ads        # app patch only
#   ./tv-free.sh --app=/path/to/app.asar
#   SUDO=sudo-gui ./tv-free.sh   # use a GUI askpass helper
#
# Requires: bash, node, a tradingview deb install. No network needed.
# Re-run after an app update (app.asar is replaced by the package).
set -euo pipefail

APP=/opt/TradingView/resources/app.asar
DO_ADS=1
for a in "$@"; do
  case "$a" in
    --no-ads) DO_ADS=0 ;;
    --app=*) APP="${a#*=}" ;;
    -y|--yes) : ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

[ -f "$APP" ] || { echo "not found: $APP" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="${SUDO-sudo}"; fi
as_root() { if [ -n "$SUDO" ]; then "$SUDO" bash -c "$1"; else bash -c "$1"; fi; }

WORK="$(mktemp -d /tmp/tv-free.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/paywall-guard-page.js" <<'TV_PAGE_EOF'
(function () {
  // guard-version: 4
  try { localStorage.setItem("forcefeaturetoggle.tvd_paid_only_access", "false"); } catch (e) {}

  /* ---------------- paywall wall interceptor ---------------- */
  var SUPPRESS = {
    customIntervals: 1,
    customSecondIntervals: 1,
    secondsIntervals: 1,
    tickIntervals: 1,
    desktopPaidOnlyAccess: 1
  };

  function installGuard() {
    if (window.__tvPaywallGuardInstalled) return true;
    var cg = self.webpackChunktradingview;
    if (!cg || typeof cg.push !== "function") return false;
    var req = null;
    try {
      cg.push([["__tv_paywall_guard_" + Math.random().toString(36).slice(2)], {}, function (r) { req = r; }]);
    } catch (e) { return false; }
    if (!req) return false;

    var mod = null;
    if (req.c) {
      for (var k in req.c) {
        try {
          var e = req.c[k] && req.c[k].exports;
          if (e && typeof e.wallInterceptor === "function" && typeof e.openWall === "function" && typeof e.registerWallKind === "function") {
            mod = e; break;
          }
        } catch (err) {}
      }
    }
    if (!mod && req.m) {
      for (var j in req.m) {
        try {
          var src = String(req.m[j]);
          if (src.indexOf("wallInterceptor") !== -1 && src.indexOf("registerWallKind") !== -1) {
            mod = req(j); break;
          }
        } catch (err) {}
      }
    }
    if (!mod) return false;

    try {
      var walls = mod.wallInterceptor("paywall");
      walls.hide("customIntervals");
      walls.hide("customSecondIntervals");
      walls.hide("secondsIntervals");
      walls.hide("tickIntervals");
      walls.hide("desktopPaidOnlyAccess");
      walls.intercept(function (feature) { return SUPPRESS[feature] === 1; });
      window.__tvPaywallGuardInstalled = true;
      try { localStorage.setItem("__tv_paywall_guard", String(Date.now())); } catch (e) {}
      return true;
    } catch (e) { return false; }
  }

  if (!window.__tvPaywallGuardInstalled) {
    if (!installGuard()) {
      var guardTries = 0;
      var guardTimer = setInterval(function () {
        guardTries++;
        if (installGuard() || guardTries > 600) clearInterval(guardTimer);
      }, 200);
    }
  }

  /* ---------------- trial offer watcher ---------------- */
  if (window.__tvTrialWatchInstalled) return;
  window.__tvTrialWatchInstalled = true;

  var LAST_KEY = "__tv_trial_watch_last";
  var REFRESH_MS = 5 * 60 * 1000;
  var lastFetch = 0;

  function wlog(msg) {
    try { if (window.TVD && typeof window.TVD.log === "function") window.TVD.log("[trial-watch] " + msg); } catch (e) {}
    try { console.log("[trial-watch] " + msg); } catch (e) {}
  }

  function offerNow() {
    try {
      var u = window.user;
      return (u && u.available_offers && u.available_offers.trial) || null;
    } catch (e) { return null; }
  }

  function notify(offer) {
    var sig;
    try { sig = JSON.stringify(offer); } catch (e) { sig = String(offer); }
    var last = null;
    try { last = localStorage.getItem(LAST_KEY); } catch (e) {}
    if (last === sig) return false;
    try { localStorage.setItem(LAST_KEY, sig); } catch (e) {}
    wlog("trial offer detected: " + sig.slice(0, 300));
    // Native notification via the app's own IPC. The main-process handler
    // (patched into index.js) keys off __tvTrialNotify and shows an Electron
    // Notification. HTML5 Notification is denied in this app, so it is only a
    // fallback for builds where permission is granted.
    try {
      if (window.TVD && typeof window.TVD.setNotification === "function") {
        window.TVD.setNotification({
          id: "trial-offer-" + Date.now(),
          desktopNotificationTitle: "TradingView: trial offer available",
          description: "The free trial is now offered on this account. Pricing -> Try free.",
          __tvTrialNotify: true
        });
      }
    } catch (e) {}
    try {
      if (typeof Notification === "function" && Notification.permission === "granted") {
        new Notification("TradingView: trial offer available", { body: "The free trial is now offered on this account. Pricing -> Try free." });
      }
    } catch (e) {}
    return true;
  }

  function check() {
    var o = offerNow();
    if (o) notify(o);
    return !!o;
  }

  function refresh() {
    lastFetch = Date.now();
    return fetch("/api/v1/offers/", { method: "GET", credentials: "include", cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) {
        if (!j || typeof j !== "object") return;
        var offers = {};
        Object.keys(j).forEach(function (k) { if (j[k]) offers[k] = j[k]; });
        try { window.user.available_offers = offers; } catch (e) {}
        check();
      })
      .catch(function () {});
  }

  window.__tvTrialWatch = { check: check, refresh: refresh, offer: offerNow, lastFetch: function () { return lastFetch; } };

  check();
  setTimeout(refresh, 5000);
  setInterval(function () {
    if (document.visibilityState === "visible") refresh();
  }, REFRESH_MS);
  window.addEventListener("focus", function () {
    if (Date.now() - lastFetch > 60000) refresh();
  });
})();
TV_PAGE_EOF

cat > "$WORK/asar-mini.js" <<'TV_ASAR_EOF'
#!/usr/bin/env node
// Minimal ASAR extract/pack (no dependencies). Usage:
//   node asar-mini.js extract <archive> <dir>
//   node asar-mini.js pack <dir> <archive>
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function readHeader(archive) {
  const fd = fs.openSync(archive, 'r');
  const h = Buffer.alloc(8);
  fs.readSync(fd, h, 0, 8, 0);
  const blockSize = h.readUInt32LE(4);
  const block = Buffer.alloc(blockSize);
  fs.readSync(fd, block, 0, blockSize, 8);
  const jsonLen = block.readUInt32LE(4);
  const json = block.slice(8, 8 + jsonLen).toString('utf8');
  return { header: JSON.parse(json), dataStart: 8 + blockSize, fd };
}

function extract(archive, outDir) {
  const { header, dataStart, fd } = readHeader(archive);
  const unpackedRoot = archive + '.unpacked';
  const walk = (node, rel) => {
    if (node.files) {
      fs.mkdirSync(path.join(outDir, rel), { recursive: true });
      for (const name of Object.keys(node.files)) walk(node.files[name], path.join(rel, name));
      return;
    }
    if (node.link) {
      fs.mkdirSync(path.dirname(path.join(outDir, rel)), { recursive: true });
      try { fs.symlinkSync(node.link, path.join(outDir, rel)); } catch (e) {}
      return;
    }
    fs.mkdirSync(path.dirname(path.join(outDir, rel)), { recursive: true });
    let data;
    if (node.unpacked) {
      data = fs.readFileSync(path.join(unpackedRoot, rel));
    } else {
      data = Buffer.alloc(node.size);
      fs.readSync(fd, data, 0, node.size, dataStart + Number(node.offset));
    }
    fs.writeFileSync(path.join(outDir, rel), data, { mode: node.executable ? 0o755 : 0o644 });
  };
  walk(header, '');
  fs.closeSync(fd);
}

function pack(dir, archive) {
  const unpackedRoot = archive + '.unpacked';
  fs.rmSync(unpackedRoot, { recursive: true, force: true });
  const dataFiles = [];
  const tree = { files: {} };

  const walk = (abs, rel, parent) => {
    const st = fs.lstatSync(abs);
    const name = path.basename(abs);
    if (st.isDirectory()) {
      const node = { files: {} };
      parent.files[name] = node;
      for (const child of fs.readdirSync(abs).sort()) walk(path.join(abs, child), path.join(rel, child), node);
      return;
    }
    if (st.isSymbolicLink()) {
      parent.files[name] = { link: fs.readlinkSync(abs) };
      return;
    }
    const size = st.size;
    const data = fs.readFileSync(abs);
    const hash = crypto.createHash('sha256').update(data).digest('hex');
    const blocks = [];
    for (let i = 0; i < data.length; i += 4194304) {
      blocks.push(crypto.createHash('sha256').update(data.subarray(i, i + 4194304)).digest('hex'));
    }
    const integ = { algorithm: 'SHA256', hash, blockSize: 4194304, blocks };
    if (name.endsWith('.node')) {
      const dest = path.join(unpackedRoot, rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(abs, dest);
      parent.files[name] = { size, unpacked: true, integrity: integ };
      return;
    }
    parent.files[name] = { size, offset: '0', integrity: integ };
    dataFiles.push({ abs, node: parent.files[name] });
  };

  for (const name of fs.readdirSync(dir).sort()) walk(path.join(dir, name), name, tree);

  let offset = 0;
  for (const f of dataFiles) {
    f.node.offset = String(offset);
    offset += f.node.size;
  }

  const json = Buffer.from(JSON.stringify(tree), 'utf8');
  const inner = 4 + json.length;
  const paddedLen = (inner + 3) & ~3;
  const blockSize = 4 + paddedLen;
  const head = Buffer.alloc(8 + blockSize);
  head.writeUInt32LE(4, 0);
  head.writeUInt32LE(blockSize, 4);
  head.writeUInt32LE(paddedLen, 8);
  head.writeUInt32LE(json.length, 12);
  json.copy(head, 16);

  const fd = fs.openSync(archive, 'w');
  fs.writeSync(fd, head, 0, head.length);
  for (const f of dataFiles) {
    const data = fs.readFileSync(f.abs);
    fs.writeSync(fd, data, 0, data.length);
  }
  fs.closeSync(fd);
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'extract' && a && b) extract(a, b);
else if (cmd === 'pack' && a && b) pack(a, b);
else {
  console.error('usage: asar-mini.js extract <archive> <dir> | pack <dir> <archive>');
  process.exit(2);
}
TV_ASAR_EOF

echo "[1/7] extracting $APP"
node "$WORK/asar-mini.js" extract "$APP" "$WORK/app"

PRE="$WORK/app/preload/platform-preload.js"
MAIN="$WORK/app/index.js"
[ -f "$PRE" ] || { echo "unexpected app layout: missing $PRE" >&2; exit 1; }
[ -f "$MAIN" ] || { echo "unexpected app layout: missing $MAIN" >&2; exit 1; }

ALREADY=0
if grep -q "__tvPaywallGuardInstalled" "$PRE" && grep -q "__tvTrialNotify" "$MAIN"; then
  echo "    app already patched; skipping to the hosts step"
  ALREADY=1
fi

# Native modules live in app.asar.unpacked. When extracting a backup archive,
# the extractor cannot find them; copy from the real sidecar.
UNPACKED="${APP}.unpacked"
[ -d "$UNPACKED" ] || UNPACKED="/opt/TradingView/resources/app.asar.unpacked"
for f in native/tvdbridge.node keytar.node build/Release/classic_level.node; do
  if [ ! -s "$WORK/app/$f" ] || [ "$(stat -c%s "$WORK/app/$f")" -lt 1000 ]; then
    echo "    restoring $f from $UNPACKED"
    mkdir -p "$WORK/app/$(dirname "$f")"
    cp -f "$UNPACKED/$f" "$WORK/app/$f"
  fi
done

if [ "$ALREADY" -eq 0 ]; then
echo "[2/7] appending page guard/watcher to preload"
node - "$WORK/paywall-guard-page.js" "$PRE" <<'NODE'
const fs = require('fs');
const [guardPath, preloadPath] = process.argv.slice(2);
const src = fs.readFileSync(preloadPath, 'utf8');
if (!src.includes('__tvTrialWatchInstalled')) {
  const boot = fs.readFileSync(guardPath, 'utf8');
  const snippet = '\n;(()=>{try{const {webFrame:__wf}=require("electron");__wf.executeJavaScript(' + JSON.stringify(boot) + ',true).catch(()=>{});}catch(e){}})();\n';
  fs.appendFileSync(preloadPath, snippet);
  console.log('    preload patched');
}
NODE

echo "[3/7] adding native notification handler to main bundle"
node - "$MAIN" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
const src = fs.readFileSync(p, 'utf8');
if (!src.includes('__tvTrialNotify')) {
  const code = '\n;(()=>{try{const {ipcMain:__ipc,Notification:__N}=require("electron");__ipc.on("tvd:set-notification",(_e,n)=>{try{if(n&&n.__tvTrialNotify){const x=new __N({title:String(n.desktopNotificationTitle||"TradingView"),body:String(n.description||"")});x.show();}}catch(err){}});}catch(e){}})();\n';
  fs.appendFileSync(p, code);
  console.log('    main patched');
}
NODE

echo "[4/7] packing asar"
node "$WORK/asar-mini.js" pack "$WORK/app" "$WORK/app.asar"

echo "[5/7] verifying native modules are unpacked"
for n in keytar.node tvdbridge.node classic_level.node; do
  grep -aq "\"$n\":{[^}]*\"unpacked\":true" "$WORK/app.asar" || {
    echo "ERROR: $n is not marked unpacked; aborting" >&2
    exit 1
  }
done

echo "[6/7] installing app.asar (root)"
BAK="$APP.bak.$(date +%Y%m%d-%H%M%S)"
as_root "set -e; cp -a '$APP' '$BAK'; cp '$WORK/app.asar' '$APP.tmp'; chmod 644 '$APP.tmp'; if [ \"\$(id -u)\" -eq 0 ]; then chown root:root '$APP.tmp'; fi; mv -f '$APP.tmp' '$APP'"
echo "    backup: $BAK"
fi

if [ "$DO_ADS" -eq 1 ]; then
  echo "[7/7] /etc/hosts ad sinkhole"
  if grep -qF "# >>> tradingview-free sinkhole" /etc/hosts; then
    echo "    already present"
  else
    cat > "$WORK/hosts.add" <<'HOSTS'
# >>> tradingview-free sinkhole
0.0.0.0 securepubads.g.doubleclick.net
0.0.0.0 pagead2.googlesyndication.com
0.0.0.0 tpc.googlesyndication.com
0.0.0.0 googleads.g.doubleclick.net
0.0.0.0 adclick.g.doubleclick.net
0.0.0.0 ad.doubleclick.net
0.0.0.0 www.googletagservices.com
0.0.0.0 partner.googleadservices.com
::1 securepubads.g.doubleclick.net
::1 pagead2.googlesyndication.com
::1 tpc.googlesyndication.com
::1 googleads.g.doubleclick.net
::1 adclick.g.doubleclick.net
::1 ad.doubleclick.net
::1 www.googletagservices.com
::1 partner.googleadservices.com
# <<< tradingview-free sinkhole
HOSTS
    as_root "set -e; cp -a /etc/hosts /etc/hosts.bak.$(date +%Y%m%d-%H%M%S); cat '$WORK/hosts.add' >> /etc/hosts"
    echo "    hosts updated"
  fi
else
  echo "[7/7] skipped hosts sinkhole (--no-ads)"
fi

echo
echo "Done. Restart TradingView for the new preload/main bundle to load."
[ "$ALREADY" -eq 0 ] && echo "Undo asar: install $BAK back over $APP (or apt reinstall tradingview)."
exit 0
