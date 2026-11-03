#Requires -Version 5.1
<#
.SYNOPSIS
  Remove the TradingView desktop free-tier paywalls on Windows by patching a
  portable copy of the installed MSIX package.

.DESCRIPTION
  The Microsoft Store / MSIX build lives in C:\Program Files\WindowsApps, which
  is owned by SYSTEM/TrustedInstaller and is read-only for users. This script
  copies the package to a writable folder (default:
  %LOCALAPPDATA%\TradingView-Patched), patches its app.asar, and leaves the
  Store app untouched. No admin is required for the app patch. Editing the
  hosts file for the ad sinkhole does require elevation.

  The portable copy has its own app folder but shares %APPDATA%\TradingView
  with other unpackaged TradingView builds, so you sign in once.

.PARAMETER Dest
  Destination for the patched copy. Default: %LOCALAPPDATA%\TradingView-Patched

.PARAMETER NoAds
  Skip the /etc/hosts ad sinkhole.

.PARAMETER NoShortcut
  Do not create the desktop shortcut.

.PARAMETER Force
  Stop running TradingView processes before copying/patching.

.PARAMETER Launch
  Start the patched copy when done.

.PARAMETER Revert
  Remove the patched copy, shortcut, and hosts block. The Store app is untouched.

.EXAMPLE
  .\tv-free.ps1
  .\tv-free.ps1 -NoAds -Dest "$env:LOCALAPPDATA\TradingView-Test"
  .\tv-free.ps1 -Revert
#>
[CmdletBinding()]
param(
  [string]$Dest = (Join-Path $env:LOCALAPPDATA 'TradingView-Patched'),
  [switch]$NoAds,
  [switch]$NoShortcut,
  [switch]$Force,
  [switch]$Launch,
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$markerStart = '# >>> tradingview-free sinkhole'
$markerEnd = '# <<< tradingview-free sinkhole'
$shortcutName = 'TradingView (patched).lnk'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HostsPath {
  return (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
}

function Remove-HostsBlock {
  $hosts = Get-HostsPath
  $lines = Get-Content -Path $hosts -ErrorAction Stop
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in $lines) {
    if ($line.Trim() -eq $markerStart) { $skip = $true; continue }
    if ($line.Trim() -eq $markerEnd) { $skip = $false; continue }
    if (-not $skip) { $out.Add($line) }
  }
  Set-Content -Path $hosts -Value $out -Encoding ASCII
}

function Add-HostsBlock {
  $hosts = Get-HostsPath
  $text = Get-Content -Path $hosts -Raw -ErrorAction Stop
  if ($text -match [regex]::Escape($markerStart)) {
    Write-Host '    hosts block already present'
    return
  }
  Copy-Item -Path $hosts -Destination ("$hosts.bak." + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $block = @"

$markerStart
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
$markerEnd
"@
  Add-Content -Path $hosts -Value $block -Encoding ASCII
  & ipconfig /flushdns | Out-Null
}

function Get-TradingViewPackage {
  $pkg = Get-AppxPackage -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*TradingView*' } |
    Select-Object -First 1
  if (-not $pkg) {
    throw 'TradingView MSIX package not found. Install the Store/MSIX app first.'
  }
  return $pkg
}

if ($Revert) {
  $running = Get-Process TradingView -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase) }
  if ($running) { $running | Stop-Process -Force; Start-Sleep -Seconds 3 }
  if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
  Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName) -Force -ErrorAction SilentlyContinue
  if (Test-Admin) {
    Remove-HostsBlock
    Write-Host 'Removed hosts block.'
  } else {
    Write-Warning 'Not elevated: hosts block left in place. Re-run -Revert as administrator to remove it.'
  }
  Write-Host 'Reverted. The Store app was not modified.'
  return
}

Write-Host "[1/7] finding installed TradingView MSIX package"
$pkg = Get-TradingViewPackage
$src = $pkg.InstallLocation
Write-Host "    $($pkg.PackageFullName)"
if (-not (Test-Path (Join-Path $src 'resources\app.asar'))) {
  throw "Unexpected package layout: no resources\app.asar under $src"
}

Write-Host "[2/7] checking running processes"
$running = Get-Process TradingView -ErrorAction SilentlyContinue
if ($running) {
  if (-not $Force) {
    throw 'TradingView is running. Close it first, or rerun with -Force.'
  }
  $running | Stop-Process -Force
  Start-Sleep -Seconds 3
}

Write-Host "[3/7] copying package to $Dest"
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$null = robocopy $src $Dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

Write-Host "[4/7] writing patch helper"
$temp = Join-Path $env:TEMP ('tv-free-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$patchJs = @'
#!/usr/bin/env node
// Minimal ASAR extract/pack (no dependencies). Usage:
//   node asar-mini.js extract <archive> <dir>
//   node asar-mini.js pack <dir> <archive>
'use strict';
process.noAsar = true;
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');

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


const [asarPath, guardPath] = process.argv.slice(2);
if (!asarPath || !guardPath) { console.error("usage: tv-patch.js <app.asar> <guard.js>"); process.exit(2); }
const work = fs.mkdtempSync(path.join(os.tmpdir(), "tv-patch-"));
try {
  extract(asarPath, work);
  const pre = path.join(work, "preload", "platform-preload.js");
  const main = path.join(work, "index.js");
  if (!fs.existsSync(pre) || !fs.existsSync(main)) throw new Error("unexpected app.asar layout");
  if (!fs.readFileSync(pre, "utf8").includes("__tvTrialWatchInstalled")) {
    const boot = fs.readFileSync(guardPath, "utf8");
    const snippet = "\n;(()=>{try{const {webFrame:__wf}=require(\"electron\");__wf.executeJavaScript(" + JSON.stringify(boot) + ",true).catch(()=>{});}catch(e){}})();\n";
    fs.appendFileSync(pre, snippet);
  }
  if (!fs.readFileSync(main, "utf8").includes("__tvTrialNotify")) {
    const code = "\n;(()=>{try{const {ipcMain:__ipc,Notification:__N}=require(\"electron\");__ipc.on(\"tvd:set-notification\",(_e,n)=>{try{if(n&&n.__tvTrialNotify){const x=new __N({title:String(n.desktopNotificationTitle||\"TradingView\"),body:String(n.description||\"\")});x.show();}}catch(err){}});}catch(e){}})();\n";
    fs.appendFileSync(main, code);
  }
  const out = asarPath + ".new";
  pack(work, out);
  const buf = fs.readFileSync(out, "latin1");
  for (const n of ["keytar.node", "tvdbridge.node", "classic_level.node"]) {
    const re = new RegExp("\"" + n.replace(/\./g, "\\.") + "\":\\{[^}]*\"unpacked\":true");
    if (!re.test(buf)) throw new Error(n + " not unpacked");
  }
  fs.copyFileSync(out, asarPath);
  fs.rmSync(out, { force: true });
  fs.rmSync(out + ".unpacked", { recursive: true, force: true });
  console.log("OK " + asarPath);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
'@
$guardJs = @'
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
'@
[IO.File]::WriteAllText((Join-Path $temp 'tv-patch.js'), $patchJs, $utf8)
[IO.File]::WriteAllText((Join-Path $temp 'paywall-guard-page.js'), $guardJs, $utf8)

Write-Host "[5/7] patching app.asar (TradingView.exe as Node)"
$env:ELECTRON_RUN_AS_NODE = '1'
$patchScript = Join-Path $temp 'tv-patch.js'
$guardScript = Join-Path $temp 'paywall-guard-page.js'
$asarPath = Join-Path $Dest 'resources\app.asar'
$argLine = '"{0}" "{1}" "{2}"' -f $patchScript, $asarPath, $guardScript
$outLog = Join-Path $temp 'patch.out.log'
$errLog = Join-Path $temp 'patch.err.log'
try {
  $p = Start-Process -FilePath (Join-Path $Dest 'TradingView.exe') -ArgumentList $argLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  if ($p.ExitCode -ne 0) {
    Write-Host '--- patch stdout ---'
    if (Test-Path $outLog) { Get-Content $outLog }
    Write-Host '--- patch stderr ---'
    if (Test-Path $errLog) { Get-Content $errLog }
    throw "asar patch failed with exit code $($p.ExitCode)"
  }
} finally {
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoShortcut) {
  Write-Host "[6/7] creating desktop shortcut"
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = Join-Path $Dest 'TradingView.exe'
  $sc.WorkingDirectory = $Dest
  $sc.IconLocation = (Join-Path $Dest 'TradingView.exe') + ',0'
  $sc.Save()
} else {
  Write-Host '[6/7] shortcut skipped'
}

if ($NoAds) {
  Write-Host '[7/7] hosts sinkhole skipped (-NoAds)'
} elseif (-not (Test-Admin)) {
  Write-Warning 'Not elevated: skipping hosts sinkhole. Re-run as administrator to add it.'
} else {
  Write-Host '[7/7] adding hosts sinkhole'
  Add-HostsBlock
}

Write-Host ''
Write-Host "Done: $Dest\TradingView.exe"
Write-Host 'The Store app is untouched. Sign in once in the patched copy.'
Write-Host 'Re-run this script after the Store app updates.'
if ($Launch) {
  Start-Process -FilePath (Join-Path $Dest 'TradingView.exe')
}
