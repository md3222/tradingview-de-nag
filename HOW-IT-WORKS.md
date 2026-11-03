# TradingView desktop — how the free-tier de-nag works

Target: `/opt/TradingView`, deb `tradingview 3.5.0-1`, Electron 41.7.1, Chromium 146.0.7680.216.
Tested 2026-11-03.

## 0. Two different codebases

```
Electron shell (local)                    Remote web app (network)
/opt/TradingView/resources/app.asar  ->  www.tradingview.com/chart/...
  index.js, preload/*, app chrome          chart bundles, feature toggles, paywalls
```

- Ads are a **network** problem in the remote renderer.
- The paywalls are **JavaScript in the remote app**. The remote bundles are not patched (they change hash every build). A page script is injected from the local preload and uses the remote app's own extension points.

---

## 1. Ads — DNS sinkhole

### How the ad loads

The chart page loads `toast-ad.<hash>.js`, which creates a Google Ad Manager slot:

```html
<div id="charting-ad">
  <div id="div-gpt-ad-toast-ad-1"> ... </div>
</div>
```

and requests:

```
https://securepubads.g.doubleclick.net/gampad/ads?...&iu=/21803441042/native_ad_unit/native_ad_unit_dark
```

The response renders the toast.

### Block

```
0.0.0.0 securepubads.g.doubleclick.net
0.0.0.0 pagead2.googlesyndication.com
0.0.0.0 tpc.googlesyndication.com
0.0.0.0 googleads.g.doubleclick.net
0.0.0.0 adclick.g.doubleclick.net
0.0.0.0 ad.doubleclick.net
0.0.0.0 www.googletagservices.com
0.0.0.0 partner.googleadservices.com
::1     (same eight)
```

Why both families: Chromium resolves via `getaddrinfo`, which can return AAAA even when A is sinkholed. `0.0.0.0` kills IPv4, `::1` makes the IPv6 attempt hit loopback and fail.

Why it works: no address -> no TCP/TLS -> the GAM request fails -> the slot never fills. An already-rendered toast stays until its next ~3-minute rotation, then goes away.

Caveats: DoH configured in the app/OS bypasses `/etc/hosts`; a VPN/proxy that resolves remotely also bypasses it; IP-literal requests are unaffected. Do **not** block `static.tradingview.com` — the app's own bundles come from there.

```bash
sudo cp -a /etc/hosts /etc/hosts.bak.$(date +%Y%m%d-%H%M%S)
sudo tee -a /etc/hosts >/dev/null <<'EOF'
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
EOF
```

Verify:

```bash
getent ahosts securepubads.g.doubleclick.net   # 0.0.0.0 and ::1
curl -m 3 -o /dev/null -w '%{http_code}\n' https://securepubads.g.doubleclick.net/  # 000
```

---

## 2. Desktop paywall — feature toggle

### Trigger (`main_chart.<hash>.js`)

```js
window.is_authenticated || Cn
  ? isDesktopApp()
      && isFeatureEnabled("tvd_paid_only_access")
      && Pt()                       // authenticated && !is_pro
      && window.setTimeout(() => {
           /* ... */
           window.WSBackendConnection.forbidConnection();
           await openPaywall(PAYWALL_DESKTOP_PAID_ONLY_ACCESS, {
             goproSource: "desktop_paid_only_access",
             registerCloseHandle: t => { e = t; }
           });
         }, 12e4)                    // 120 s
  : /* registration dialog */
```

The paywall config hard-codes `closable: !1`, so there is no close path; the WS is forbidden while it is open.

### Toggle

The web app's own override API:

```js
window.TradingView.FeatureToggle.disableFeature("tvd_paid_only_access");
// localStorage["forcefeaturetoggle.tvd_paid_only_access"] = "false"
```

`isFeatureEnabled` evaluates roughly:

```
(server state exists) &&
(  explicit "true"  ||  ( !explicit "false" && server state )  )
```

So an explicit `"false"` beats the server-pushed state (unless there is also an explicit `"true"`). It is stored in:

```
~/.config/TradingView/Local Storage/leveldb
  origin key: _https://www.tradingview.com
  forcefeaturetoggle.tvd_paid_only_access = "false"
```

In the patch, the page bootstrap does this on every load:

```js
try { localStorage.setItem("forcefeaturetoggle.tvd_paid_only_access", "false"); } catch (e) {}
```

No DevTools or CDP required on the target machine.

---

## 3. Timeframe paywall — wall interceptor

### Trigger (live module `649873`)

```js
t.dataEvents().customIntervalNotPermitted().subscribe(null, i => {
  t.setSymbolParams({ interval: getApplicableDefaultResolution(defaults, i) });
  r.muteSessionErrors || reloginOrGoPro(PAYWALL_CUSTOM_INTERVALS);
});
```

`reloginOrGoPro` -> `openPaywall` -> `openWall("paywall", { feature: "customIntervals" })`.

### Extension point (module `153041`)

```js
openWall: (kind, wall, opts = {}) =>
  c(kind).tryIntercept(wall.feature)
    ? Promise.resolve({ shown: false })
    : opener.open(kind, wall, opts)
```

`tryIntercept` returns true if the feature was added with `hide(feature)`, or if any registered handler returns true. A `true` means "consume it, show nothing."

### Finding the module without a hard-coded id

Webpack's chunk array exposes `__webpack_require__` if you push a dummy chunk:

```js
let req = null;
self.webpackChunktradingview.push([["probe_" + Math.random()], {}, r => { req = r; }]);

let mod = null;
for (const id in req.m) {
  const src = String(req.m[id]);          // factory source
  if (src.includes("wallInterceptor") && src.includes("registerWallKind")) {
    mod = req(id);
    break;
  }
}

mod.wallInterceptor("paywall").intercept(f =>
  f === "customIntervals" ||
  f === "customSecondIntervals" ||
  f === "secondsIntervals" ||
  f === "tickIntervals" ||
  f === "desktopPaidOnlyAccess"
);
```

Why source search: module ids and bundle hashes change per build; the two strings are stable.

### Injection

`preload/platform-preload.js` runs before the page with `contextIsolation`. It can execute page-world code:

```js
require("electron").webFrame.executeJavaScript(bootstrapCode, true);
```

The bootstrap polls until `self.webpackChunktradingview` and the wall module exist (up to ~2 minutes), then registers once. Marker: `window.__tvPaywallGuardInstalled`.

Result: the datafeed still rejects 2m and the chart falls back to 3m; only the modal is suppressed. The same interceptor also catches `desktopPaidOnlyAccess`, so the paywall stays gone even if the toggle is reset.

---

## 4. Packaging the local patch

`app.asar` contains the shell, not the chart bundles. Two files are modified:

| File | Change |
|---|---|
| `preload/platform-preload.js` | append the page bootstrap (`webFrame.executeJavaScript(...)`) |
| `index.js` | append a `tvd:set-notification` -> native `Notification` handler for the trial watcher |

### ASAR format essentials

```
[u32 4][u32 blockSize][u32 paddedLen][u32 jsonLen][JSON][padding][file data...]
```

- File offsets are relative to the data start.
- Files with `"unpacked": true` live in `app.asar.unpacked/<path>`.
- Native `.node` files **must** be unpacked: `dlopen` can't load from inside the archive.
- If a repack loses the `unpacked` flags, the app dies with `No native build was found ... loaded from ... app.asar`.

### Manual implementation

```bash
APP=/opt/TradingView/resources/app.asar
sudo cp -a "$APP" "$APP.bak.$(date +%Y%m%d-%H%M%S)"

rm -rf /tmp/tv-app
npx --yes @electron/asar extract "$APP" /tmp/tv-app

# 1. append the page bootstrap to /tmp/tv-app/preload/platform-preload.js
# 2. append the notification handler to /tmp/tv-app/index.js

npx --yes @electron/asar pack /tmp/tv-app /tmp/tv-app.asar --unpack "**/*.node"

# must print a match for all three .node files
grep -ao '"keytar.node":{[^}]*"unpacked":true' /tmp/tv-app.asar

sudo install -o root -g root -m 644 /tmp/tv-app.asar "$APP"
```

Then restart TradingView. The install is atomic; a running process keeps the old inode until restart.

### Or run the installer

```bash
./tv-free.sh                # asar + hosts
./tv-free.sh --no-ads       # asar only
```

It does the same steps with a bundled ASAR reader/writer (no npm/network), verifies the unpacked flags, backs up the old asar, and is idempotent.

---

## 5. Verification

```bash
/opt/TradingView/tradingview --remote-debugging-port=9222 --remote-allow-origins='*' &
WS=$(curl -s http://127.0.0.1:9222/json |
  jq -r '.[] | select(.url|startswith("https://www.tradingview.com/chart")) | .webSocketDebuggerUrl' | head -1)

node tools/cdp.js "$WS" 'window.__tvPaywallGuardInstalled'                        # true
node tools/cdp.js "$WS" 'window.TradingView.isFeatureEnabled("tvd_paid_only_access")'  # false

node tools/cdp.js "$WS" '(()=>{window.TradingViewApi.activeChart().setResolution("2");return 1})()'
sleep 4
node tools/cdp.js "$WS" 'window.TradingViewApi.activeChart().resolution()'        # "3"
node tools/cdp.js "$WS" 'document.body.innerText.includes("custom intervals")'    # false
```

Expected: fallback to an allowed interval, no modal, no paywall after 120 s.

---

## 6. Re-apply / undo

- An app update replaces `app.asar` -> rerun `tv-free.sh`.
- Undo the asar:

```bash
sudo install -o root -g root -m 644 \
  app.asar.bak.<timestamp> \
  /opt/TradingView/resources/app.asar
```

or `sudo apt reinstall tradingview`.

- Undo the hosts block: delete the lines between `# >>> tradingview-free sinkhole` and `# <<< tradingview-free sinkhole`.

---

## 7. What this does not do

- It does not grant entitlements. 2m still isn't permitted server-side; the chart still falls back.
- It does not alter `available_offers`, the rollout bucket, or checkout.
- The trial watcher only reads `/api/v1/offers/` and notifies if the server ever returns a `trial` offer.

---

## 8. Windows (MSIX) packaging

The Windows app is an MSIX package under `C:\Program Files\WindowsApps`, owned by SYSTEM/TrustedInstaller and read-only for users. The same page bootstrap and wall interceptor apply, but the packaging step is different:

- Copy the installed package to `%LOCALAPPDATA%\TradingView-Patched` with `robocopy`.
- Patch that copy's `resources\app.asar`; leave the Store package untouched.
- Run the patch helper with the copied `TradingView.exe` and `ELECTRON_RUN_AS_NODE=1` (no Node install needed; the `RunAsNode` fuse is enabled).
- The tested builds have `EnableEmbeddedAsarIntegrityValidation: Disabled`, so the patched asar loads.

**Gotcha:** Electron patches `fs` to treat every `*.asar` path as an archive. When `TradingView.exe` runs as Node, `fs.openSync("...\\app.asar")` is intercepted and fails with `ENOENT`. The helper sets `process.noAsar = true` before reading or writing the archive.

Details, usage, verification and caveats: [WINDOWS.md](WINDOWS.md).
