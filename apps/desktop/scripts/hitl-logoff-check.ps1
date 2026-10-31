# HITL check for the Windows logoff cleanup test (issue 08). Read-only: never changes proxy settings.
#
#   pwsh -File apps/desktop/scripts/hitl-logoff-check.ps1 -Phase before   # right before logging off
#   pwsh -File apps/desktop/scripts/hitl-logoff-check.ps1 -Phase after    # after logging on, BEFORE starting Clash Kuro
#
# before: refuses (exit 1, "DO NOT LOG OFF") unless proxy-changing apps are closed, Clash Kuro is running,
#         the helper reads LAN flags=3 and the RunOnce cleanup entry (with --log) is in place.
#         Saves a snapshot to %TEMP%\kuro-hitl-logoff-before.json for the after phase.
# after:  prints exit.log, runonce.log, helper get, the RunOnce entry, registry key last-write times,
#         the DefaultConnectionSettings counter/flags, Shell-Core RunOnce events (9705-9708) and
#         clash-verge session-ending lines since the before snapshot. Paste the whole output back.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
  [Parameter(Mandatory = $true)][ValidateSet('before', 'after')][string]$Phase,
  # kuro-sysproxy.exe; default: from the RunOnce entry, the running Clash Kuro, or the before snapshot.
  [string]$Helper
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$DataDir = Join-Path $env:APPDATA 'Clash Kuro\data'
$ExitLog = Join-Path $DataDir 'exit.log'
$RunOnceLog = Join-Path $DataDir 'runonce.log'
$StateFile = Join-Path $env:TEMP 'kuro-hitl-logoff-before.json'
$InetKey = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ConnKey = "$InetKey\Connections"
$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceValue = 'ClashKuroSysProxyCleanup'
# GUI apps known to rewrite the per-user WinINet proxy (on start, exit or session end).
$ProxyApps = @('Fiddler', 'Fiddler Everywhere', 'clash-verge', 'verge-mihomo', 'Clash Verge', 'clash-party', 'mihomo-party',
  'Clash for Windows', 'v2rayN', 'nekoray', 'NekoBox', 'Hiddify', 'Charles', 'mitmproxy', 'mitmdump', 'Proxifier')

if (-not ('KuroHitlReg' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KuroHitlReg {
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
  static extern int RegOpenKeyExW(IntPtr key, string subKey, int options, int sam, out IntPtr result);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
  static extern int RegQueryInfoKeyW(IntPtr key, IntPtr cls, IntPtr clsLen, IntPtr reserved, IntPtr subKeys, IntPtr maxSubKey,
    IntPtr maxClass, IntPtr values, IntPtr maxValueName, IntPtr maxValue, IntPtr security, out long lastWrite);
  [DllImport("advapi32.dll")]
  static extern int RegCloseKey(IntPtr key);
  // Last write time (UTC) of a key under HKEY_CURRENT_USER.
  public static DateTime LastWriteUtc(string subKey) {
    IntPtr key;
    int r = RegOpenKeyExW(new IntPtr(unchecked((int)0x80000001)), subKey, 0, 0x20019, out key);
    if (r != 0) throw new System.ComponentModel.Win32Exception(r);
    try {
      long fileTime;
      r = RegQueryInfoKeyW(key, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out fileTime);
      if (r != 0) throw new System.ComponentModel.Win32Exception(r);
      return DateTime.FromFileTimeUtc(fileTime);
    } finally { RegCloseKey(key); }
  }
}
'@
}

function Section([string]$name) { Write-Output ''; Write-Output "== $name" }
function Stamp([datetime]$utc) { '{0:yyyy-MM-dd HH:mm:ss.fff} local / {1:HH:mm:ss.fff}Z' -f $utc.ToLocalTime(), $utc }

function Get-RunOnceEntry {
  $item = Get-ItemProperty -Path $RunOnceKey -ErrorAction SilentlyContinue
  if ($item -and ($item.PSObject.Properties.Name -contains $RunOnceValue)) { return [string]$item.$RunOnceValue }
  return $null
}

function Resolve-Helper([string]$entry, $state) {
  if ($Helper) { return $Helper }
  if ($entry -and $entry -match '^"([^"]+)"') { return $Matches[1] }
  $kuro = Get-Process -Name 'Clash Kuro' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($kuro -and $kuro.Path) { return Join-Path (Split-Path $kuro.Path) 'resources\bin\kuro-sysproxy.exe' }
  if ($state -and $state.helper) { return [string]$state.helper }
  throw 'Cannot find kuro-sysproxy.exe; pass -Helper <path>'
}

# Runs the helper with stdout redirected and waits for it (PowerShell does not wait for GUI-subsystem exes otherwise).
function Invoke-HelperGet([string]$path) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $path
  $psi.Arguments = 'get'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'helper get timed out' }
  $json = $null
  try { $json = $out | ConvertFrom-Json } catch { }
  $lan = $null
  if ($json) { $lan = $json.connections | Where-Object { $null -eq $_.name } | Select-Object -First 1 }
  [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Trim(); Lan = $lan }
}

# DefaultConnectionSettings: bytes 4-7 = change counter, byte 8 = flags (same bits as the helper's flags).
function Get-ConnectionBlob {
  $item = Get-ItemProperty -Path "HKCU:\$ConnKey" -ErrorAction SilentlyContinue
  if (-not $item -or -not ($item.PSObject.Properties.Name -contains 'DefaultConnectionSettings')) { return $null }
  [byte[]]$b = $item.DefaultConnectionSettings
  [pscustomobject]@{ Counter = [BitConverter]::ToUInt32($b, 4); Flags = $b[8] }
}

function Get-ProxyApps {
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $ProxyApps -contains $_.ProcessName } |
    ForEach-Object { '{0} (pid {1})' -f $_.ProcessName, $_.Id }
}

function Tail([string]$path, [int]$count) {
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Tail $count -Encoding UTF8 } else { "(missing: $path)" }
}

# Returns the readings plus the lines to print (the caller prints .Lines, so the return value stays clean).
function Read-Common([string]$helperPath, [string]$entry) {
  $get = Invoke-HelperGet $helperPath
  $inet = [KuroHitlReg]::LastWriteUtc($InetKey)
  $conn = [KuroHitlReg]::LastWriteUtc($ConnKey)
  $blob = Get-ConnectionBlob
  $pe = (Get-ItemProperty -Path "HKCU:\$InetKey" -ErrorAction SilentlyContinue).ProxyEnable
  $lines = @(
    '', '== helper get', "helper: $helperPath", "exit=$($get.ExitCode) $($get.Stdout)",
    '', '== RunOnce entry', $(if ($entry) { "${RunOnceValue} = $entry" } else { "${RunOnceValue}: (none)" }),
    '', '== registry', "Internet Settings last write: $(Stamp $inet)", "Connections       last write: $(Stamp $conn)",
    $(if ($blob) { "DefaultConnectionSettings: counter=$($blob.Counter) flags=$($blob.Flags)" } else { 'DefaultConnectionSettings: (missing)' }),
    "ProxyEnable=$pe (informational; the helper get is authoritative)")
  [pscustomobject]@{ Get = $get; Inet = $inet; Conn = $conn; Blob = $blob; Lines = $lines }
}

Write-Output "kuro hitl-logoff-check -Phase $Phase at $(Stamp ([datetime]::UtcNow))"
$entry = Get-RunOnceEntry

if ($Phase -eq 'before') {
  $problems = New-Object System.Collections.Generic.List[string]
  Section 'proxy-changing apps'
  $apps = @(Get-ProxyApps)
  if ($apps.Count) { $apps | ForEach-Object { Write-Output "running: $_" }; $problems.Add("quit these apps first (tray icon > Quit): $($apps -join ', ')") }
  else { Write-Output 'none running' }
  $svc = Get-Service -Name 'clash_verge_service' -ErrorAction SilentlyContinue
  if ($svc) { Write-Output "service clash_verge_service: $($svc.Status) (a service; it does not set the per-user proxy by itself)" }
  $kuro = @(Get-Process -Name 'Clash Kuro' -ErrorAction SilentlyContinue)
  if ($kuro.Count) { Write-Output "Clash Kuro running (pid $($kuro[0].Id), started $($kuro[0].StartTime))" }
  else { $problems.Add('Clash Kuro is not running: start it, turn System Proxy on, close the main window (Tray Mode)') }

  $helperPath = Resolve-Helper $entry $null
  $s = Read-Common $helperPath $entry
  $s.Lines
  $lan = $s.Get.Lan
  if (-not $lan) { $problems.Add('helper get returned no LAN connection') }
  elseif ($lan.flags -ne 3) { $problems.Add("LAN flags=$($lan.flags), expected 3 (manual proxy on, PAC/auto-detect off): turn System Proxy on in Clash Kuro") }
  if ($lan -and $lan.proxyServer -notmatch '^127\.0\.0\.1:\d+$') { $problems.Add("LAN proxyServer=$($lan.proxyServer) is not 127.0.0.1:<port>") }
  if (-not $entry) { $problems.Add('RunOnce entry missing: toggle System Proxy off and on in Clash Kuro') }
  else {
    if ($lan -and $entry -notlike "* clear --expected-server $($lan.proxyServer)*") { $problems.Add("RunOnce entry does not clear $($lan.proxyServer)") }
    if ($entry -notmatch ' --log "') { $problems.Add('RunOnce entry has no --log: this build is too old for the test') }
    if ($entry -match '^"([^"]+)"' -and -not (Test-Path -LiteralPath $Matches[1])) { $problems.Add("RunOnce helper path does not exist: $($Matches[1])") }
  }
  Section 'exit.log (last 3)'
  Tail $ExitLog 3
  Section 'runonce.log (last 2)'
  Tail $RunOnceLog 2

  @{ timeUtc = [datetime]::UtcNow.ToString('o'); helper = $helperPath; entry = $entry; lan = $lan
     inetUtc = $s.Inet.ToString('o'); connUtc = $s.Conn.ToString('o')
     counter = $(if ($s.Blob) { $s.Blob.Counter } else { $null })
     exitLogLines = $(if (Test-Path $ExitLog) { @(Get-Content $ExitLog).Count } else { 0 })
     runOnceLogLines = $(if (Test-Path $RunOnceLog) { @(Get-Content $RunOnceLog).Count } else { 0 }) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8

  Section 'verdict'
  if ($problems.Count) {
    $problems | ForEach-Object { Write-Output "FAIL: $_" }
    Write-Output '>>> DO NOT LOG OFF. Fix the items above and run -Phase before again.'
    exit 1
  }
  Write-Output ">>> OK to log off now. Snapshot saved to $StateFile"
  Write-Output '>>> After logging on, run -Phase after BEFORE starting Clash Kuro.'
  exit 0
}

# ---- after ----
$state = $null
if (Test-Path -LiteralPath $StateFile) { $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
$since = if ($state) { ([datetime]$state.timeUtc).ToUniversalTime() } else { [datetime]::UtcNow.AddHours(-1) }
Section 'before snapshot'
if ($state) {
  Write-Output "taken: $(Stamp $since)"
  Write-Output "LAN then: flags=$($state.lan.flags) proxyServer=$($state.lan.proxyServer)"
  Write-Output "Connections last write then: $(Stamp ([datetime]$state.connUtc).ToUniversalTime()) counter=$($state.counter)"
} else { Write-Output "(no $StateFile; using the last hour)" }

Section 'session'
$explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
if ($explorer) { Write-Output "explorer started (logon): $(Stamp $explorer.StartTime.ToUniversalTime())" }
try {
  Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Winlogon'; Id = 7001, 7002; StartTime = $since.ToLocalTime() } -ErrorAction Stop |
    Sort-Object TimeCreated | ForEach-Object { '{0} winlogon {1}' -f (Stamp $_.TimeCreated.ToUniversalTime()), $(if ($_.Id -eq 7002) { 'logoff' } else { 'logon' }) }
} catch { Write-Output "(no Winlogon 7001/7002 events: $($_.Exception.Message))" }
$kuro = @(Get-Process -Name 'Clash Kuro' -ErrorAction SilentlyContinue)
if ($kuro.Count) { Write-Output "WARNING: Clash Kuro is running (started $($kuro[0].StartTime)); its startup cleanup may already have changed the proxy" }
$apps = @(Get-ProxyApps)
if ($apps.Count) { Write-Output "proxy-changing apps running now: $($apps -join ', ')" }

$helperPath = Resolve-Helper $entry $state
$s = Read-Common $helperPath $entry
$s.Lines

Section 'exit.log (new lines)'
if (Test-Path -LiteralPath $ExitLog) {
  $lines = @(Get-Content -LiteralPath $ExitLog -Encoding UTF8)
  $from = if ($state) { [int]$state.exitLogLines } else { [Math]::Max(0, $lines.Count - 10) }
  if ($lines.Count -gt $from) { $lines[$from..($lines.Count - 1)] } else { '(no new lines)' }
} else { "(missing: $ExitLog)" }

Section 'runonce.log (new lines)'
if (Test-Path -LiteralPath $RunOnceLog) {
  $lines = @(Get-Content -LiteralPath $RunOnceLog -Encoding UTF8)
  $from = if ($state) { [int]$state.runOnceLogLines } else { [Math]::Max(0, $lines.Count - 4) }
  if ($lines.Count -gt $from) { $lines[$from..($lines.Count - 1)] } else { '(no new lines)' }
} else { "(missing: $RunOnceLog)" }

Section 'Shell-Core RunOnce events (9705-9708)'
$ran = $false
try {
  Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Shell-Core/Operational'; Id = 9705, 9706, 9707, 9708; StartTime = $since.ToLocalTime() } -ErrorAction Stop |
    Sort-Object TimeCreated | ForEach-Object {
      $text = ($_.Properties | ForEach-Object { $_.Value }) -join ' | '
      if ($text -match 'RunOnce|kuro-sysproxy') {
        if ($_.Id -eq 9707 -and $text -match 'kuro-sysproxy') { $script:ran = $true }
        '{0} {1} {2}' -f (Stamp $_.TimeCreated.ToUniversalTime()), $_.Id, $text
      }
    }
} catch { Write-Output "(no events: $($_.Exception.Message))" }

Section 'clash-verge session-ending lines'
$vergeLogs = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\logs'
if (Test-Path -LiteralPath $vergeLogs) {
  $hits = Get-ChildItem -LiteralPath $vergeLogs -Filter '*.log' | Where-Object { $_.LastWriteTimeUtc -ge $since } |
    Select-String -Pattern 'session-ending|Application exited|sysproxy' | ForEach-Object { $_.Line }
  if ($hits) { $hits } else { '(none since the before snapshot)' }
} else { '(clash-verge not installed for this user)' }

Section 'verdict'
$lan = $s.Get.Lan
if ($lan) { Write-Output "LAN now: flags=$($lan.flags) manualProxy=$([bool]($lan.flags -band 2)) proxyServer=$($lan.proxyServer)" }
if ($entry -and -not $ran) { Write-Output 'RunOnce entry still present and no 9707 event: RunOnce has not run yet. Wait a minute and run -Phase after again.' }
if ($state) {
  $connBefore = ([datetime]$state.connUtc).ToUniversalTime()
  if ($s.Conn -gt $connBefore) { Write-Output "Connections key was written after the snapshot, at $(Stamp $s.Conn); compare with the logoff time, the runonce.log clear line and clash-verge lines." }
  else { Write-Output 'Connections key not written since the snapshot.' }
}
Write-Output '>>> Paste everything from "kuro hitl-logoff-check" down.'
