# Windows (MSIX / Microsoft Store build)

Tested 2026-11-03 against `TradingView.Desktop_3.5.0.8375_x64__n534cwy3pjxzj` on Windows 11.

## Why the Linux method doesn't apply

The Windows desktop app is an **MSIX** package:

```
C:\Program Files\WindowsApps\TradingView.Desktop_3.5.0.8375_x64__n534cwy3pjxzj\
  TradingView.exe
  resources\app.asar
  resources\app.asar.unpacked\
```

- The folder is owned by `NT AUTHORITY\SYSTEM` / `TrustedInstaller`.
- `BUILTIN\Users` has read/execute only; there is no write ACE for Administrators.
- Editing files there needs `takeown`/`icacls` and is unsupported; Store updates repair the package.
- The official Windows download is also an MSIX (`tvd-packages.tradingview.com/stable/latest/win32/TradingView.msix`), so there is no standalone `.exe` installer to patch instead.

The good news: the Electron fuses on this build are:

```
EnableEmbeddedAsarIntegrityValidation: Disabled
OnlyLoadAppFromAsar: Disabled
RunAsNode: Enabled
```

So a patched `app.asar` **will** load, and the app's own `TradingView.exe` can run Node scripts (`ELECTRON_RUN_AS_NODE=1`), which means no separate Node install is needed.

## Approach: patched portable copy

`tv-free.ps1` does not touch WindowsApps. It:

1. Finds the installed package with `Get-AppxPackage`.
2. `robocopy`s it to `%LOCALAPPDATA%\TradingView-Patched`.
3. Patches the copy's `resources\app.asar` with the same page bootstrap used on Linux:
   - `forcefeaturetoggle.tvd_paid_only_access=false`
   - `wallInterceptor("paywall")` for `customIntervals` / `customSecondIntervals` / `secondsIntervals` / `tickIntervals` / `desktopPaidOnlyAccess`
   - trial watcher
   - `index.js` native-notification handler
4. Creates a desktop shortcut (unless `-NoShortcut`).
5. Optionally adds the `/etc/hosts` ad sinkhole (requires elevation).

The Store app and its files are untouched.

**One gotcha:** when `TradingView.exe` runs as Node, Electron's ASAR FS wrapper intercepts every path ending in `.asar`, so `fs.openSync("...\app.asar")` tries to open a file *inside* the archive and fails with `ENOENT`. The bundled patch helper sets `process.noAsar = true` before touching the archive; without it the script fails at `readHeader`.

## Usage

```powershell
# normal: app patch + hosts sinkhole (hosts needs an elevated shell)
.\tv-free.ps1

# app patch only
.\tv-free.ps1 -NoAds

# custom destination
.\tv-free.ps1 -Dest "$env:LOCALAPPDATA\TradingView-Test"

# close running TradingView automatically
.\tv-free.ps1 -Force

# start it when done
.\tv-free.ps1 -Launch

# undo
.\tv-free.ps1 -Revert
```

## Requirements

- Windows 10/11 with Windows PowerShell 5.1.
- TradingView installed from the Store or the official MSIX.
- No admin for the app patch. Admin only for the hosts sinkhole.
- No Node install; the script uses the copied `TradingView.exe` as Node.

## Sign-in

The portable copy uses `%APPDATA%\TradingView` for its profile. The Store app uses the packaged `LocalCache` path, so the two sessions are separate. Sign in once in the patched copy; the session persists across re-runs of the script (the app folder is replaced, not the profile).

## Verify

Start the patched copy with a temporary debug port:

```powershell
& "$env:LOCALAPPDATA\TradingView-Patched\TradingView.exe" `
  --remote-debugging-port=9222 --remote-allow-origins=*
```

Then run the checker from the repo, using the same exe as Node:

```powershell
$env:ELECTRON_RUN_AS_NODE=1
& "$env:LOCALAPPDATA\TradingView-Patched\TradingView.exe" .\tools\tvcheck.js
```

Expected:

```
guard true
watch true
auth true
user "<your account>"
toggle false
modal false
res "3"        # after asking for 2m
modal2 false
```

The local-storage marker also proves the preload ran:

```powershell
Select-String -Path "$env:APPDATA\TradingView\Local Storage\leveldb\*.log" -Pattern __tv_paywall_guard
```

## Updates

A Store/MSIX update creates a new package version in WindowsApps. Re-run the script; it copies the new package and re-patches it. `-Force` closes the old copy first.

## Revert

```powershell
.\tv-free.ps1 -Revert
```

That removes the patched folder, shortcut, and (if elevated) the hosts block. The Store app was never modified, so it keeps working.

## Limitations

- The portable copy is a snapshot; it does not auto-update with the Store app. Re-run the script after updates.
- It has no MSIX package identity. Native notifications from the trial watcher may not show in the unpackaged copy; the paywall/timeframe patch is unaffected.
- Server-side entitlements are untouched. 2m still falls back to 3m; only the modal is removed.
- If a future build enables `EnableEmbeddedAsarIntegrityValidation`, the patched asar will not load. Check with `npx @electron/fuses read --app <TradingView.exe>` before assuming it works.
