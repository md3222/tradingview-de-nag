# tradingview-de-nag

Remove the free-tier nagware from the **TradingView Linux desktop app**:

- the unclosable **"Analyze markets in TradingView Desktop"** paywall (120 s after chart start, no close button, blocks the data connection while open)
- the **"custom intervals"** upsell on 2m / 7m / 30s / tick and other non-standard timeframes
- the **Google Ad Manager** toast in the chart
- *optional:* a passive watcher that notifies if the server ever offers a trial

Tested on `tradingview 3.5.0-1` (deb), Electron 41.7.1, Chromium 146.0.7680.216.

It does **not** unlock paid data or features. A 2m chart still falls back to 3m; entitlements remain whatever the server grants.

| Before | After |
|---|---|
| ![Unclosable paywall](docs/unclosable-paywall.png) | ![No paywall](docs/after-fix.png) |

## Quick start

```bash
git clone https://github.com/md3222/tradingview-de-nag.git
cd tradingview-de-nag
chmod +x tv-free.sh

./tv-free.sh                 # patch app.asar + /etc/hosts ad sinkhole
./tv-free.sh --no-ads        # patch the app only
SUDO=sudo-gui ./tv-free.sh   # optional askpass helper
```

Restart TradingView. Re-run the script after every app update, because the package replaces `app.asar`.

## Requirements

- Linux, TradingView desktop installed from the deb (default `/opt/TradingView/resources/app.asar`). For another path: `--app=/path/to/app.asar`.
- `node` (any recent version).
- `sudo` (or `SUDO=...`), because `app.asar` and `/etc/hosts` are root-owned.
- No network: `tv-free.sh` embeds a minimal ASAR reader/writer.

## What it changes

| Path | Change |
|---|---|
| `resources/app.asar` → `preload/platform-preload.js` | appends a page-world bootstrap: disables `tvd_paid_only_access`, registers the paywall wall interceptor, starts the trial watcher |
| `resources/app.asar` → `index.js` | appends a `tvd:set-notification` handler that shows a native Electron notification for the trial watcher |
| `/etc/hosts` (optional) | sinkhole for 8 Google ad domains, IPv4 and IPv6 |

The script backs up the old asar as `app.asar.bak.<timestamp>`, verifies the native `.node` files stay unpacked, installs atomically, and is idempotent.

## How it works

See [HOW-IT-WORKS.md](HOW-IT-WORKS.md) for the full chain and code excerpts. Short version:

- **Ads** — DNS sinkhole: no GAM address → no request → no toast.
- **Desktop paywall** — the web app's own override: `localStorage["forcefeaturetoggle.tvd_paid_only_access"] = "false"`, set at page load.
- **Timeframe paywall** — the app's `wallInterceptor("paywall")` consumes `customIntervals` / `customSecondIntervals` / `secondsIntervals` / `tickIntervals` before the modal renders.
- **Trial watcher** — reads `/api/v1/offers/` every 5 minutes; shows a native notification when `trial` appears. Read-only; no spoofing.

## Verify

Guard installed (epoch-ms marker written to Local Storage):

```bash
strings -a ~/.config/TradingView/Local\ Storage/leveldb/*.log |
  grep -A1 __tv_paywall_guard
```

Functional test with a temporary debug port (optional; requires `jq`):

```bash
/opt/TradingView/tradingview --remote-debugging-port=9222 --remote-allow-origins='*' &
WS=$(curl -s http://127.0.0.1:9222/json |
  jq -r '.[] | select(.url|startswith("https://www.tradingview.com/chart")) | .webSocketDebuggerUrl' |
  head -1)

node tools/cdp.js "$WS" 'window.__tvPaywallGuardInstalled'                       # true
node tools/cdp.js "$WS" 'window.TradingView.isFeatureEnabled("tvd_paid_only_access")'  # false

node tools/cdp.js "$WS" '(()=>{window.TradingViewApi.activeChart().setResolution("2");return 1})()'
sleep 4
node tools/cdp.js "$WS" 'window.TradingViewApi.activeChart().resolution()'       # "3"
node tools/cdp.js "$WS" 'document.body.innerText.includes("custom intervals")'   # false
```

Expected: fallback to an allowed interval, no modal, and no paywall after 120 s.

## Revert

The script prints the backup path. Restore it:

```bash
sudo install -o root -g root -m 644 \
  /opt/TradingView/resources/app.asar.bak.<timestamp> \
  /opt/TradingView/resources/app.asar
```

or `sudo apt reinstall tradingview`.

Remove the hosts block between `# >>> tradingview-free sinkhole` and `# <<< tradingview-free sinkhole`.

## Limitations

- Server-side entitlements are untouched. Non-standard intervals still fall back; this only removes the modal.
- If the app layout or version changes, the script fails before installing (it checks for `preload/platform-preload.js` and `index.js`).
- The tested build has ASAR integrity fuses disabled (`EnableEmbeddedAsarIntegrityValidation: Disabled`). If a future build enables them, the patched asar will not load — restore the backup.
- `app.asar` becomes a modified package file; `dpkg -V tradingview` will list it.
- Not affiliated with TradingView. Use on your own installation and check the terms that apply to you.

## License

MIT — see [LICENSE](LICENSE).
