param([Parameter(Mandatory=$true)][string]$Helper, [long]$CheckpointRecord = 0)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Read only. Missing native uptime, machine identity, System log or CIM evidence denies comparison.
function Event-Evidence($Event, [bool]$IncludeFields = $false) {
  [xml]$xml = $Event.ToXml()
  $fields = @{}
  if ($IncludeFields) {
    foreach ($entry in $xml.Event.EventData.Data) { $fields[[string]$entry.Name] = [string]$entry.InnerText }
  }
  $hash = [Security.Cryptography.SHA256]::Create()
  try { $digest = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Event.ToXml())))).Replace('-', '').ToLowerInvariant() }
  finally { $hash.Dispose() }
  return @{ record = $Event.RecordId; digest = $digest; fields = $fields }
}
try {
  $machineKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
  try {
    $identityKey = $machineKey.OpenSubKey('SOFTWARE\Microsoft\Cryptography', $false)
    if ($null -eq $identityKey) { throw 'Machine identity unavailable' }
    try { $machineGuid = $identityKey.GetValue('MachineGuid', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $identityKey.Dispose() }
  } finally { $machineKey.Dispose() }
  $guid = [Guid]::Empty
  if ($machineGuid -isnot [string] -or ![Guid]::TryParseExact($machineGuid, 'D', [ref]$guid) -or $guid -eq [Guid]::Empty) {
    throw 'Invalid machine identity'
  }
  # Stable local-installation binding only: MachineGuid and its hash are not clone/tamper-proof.
  $hash = [Security.Cryptography.SHA256]::Create()
  try { $machineDigest = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($guid.ToString('D').ToLowerInvariant())))).Replace('-', '').ToLowerInvariant() }
  finally { $hash.Dispose() }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $newest = Get-WinEvent -LogName System -MaxEvents 1
  $kernel = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12} -MaxEvents 1
  $boot = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Boot';Id=27} -MaxEvents 1
  $checkpoint = $null
  if ($CheckpointRecord -gt 0) {
    $old = Get-WinEvent -LogName System -FilterXPath "*[System[EventRecordID=$CheckpointRecord]]" -MaxEvents 1
    $checkpoint = Event-Evidence $old
  }
  $os = Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime
  $legacyKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  $legacy = $null; $native = $null
  if (Test-Path -LiteralPath $legacyKey) {
    $values = (Get-ItemProperty -LiteralPath $legacyKey).PSObject.Properties
    $entry = $values['ClashKuroSysProxyCleanup']
    if ($null -ne $entry) { $legacy = [string]$entry.Value }
    $entry = $values['ClashKuroResidentCleanup']
    if ($null -ne $entry) { $native = [string]$entry.Value }
  }
  # Include every 64-hex name conservatively; false positives are intentional, absence is not ownership proof.
  $writers = @(Get-Process | Where-Object { $_.ProcessName -in @('Clash Kuro', 'kuro-sysproxy', 'mihomo', 'clash-verge', 'Fiddler', 'Fiddler Everywhere') -or $_.ProcessName -match '^[a-f0-9]{64}$' } |
    ForEach-Object { @{ pid = $_.Id; name = $_.ProcessName } })
  # Use the already verified helper; do not compile a C# assembly for every collection.
  # The pipeline also makes Windows PowerShell wait for this GUI-subsystem executable.
  $clockOutput = & $Helper 'boot-clock' | Out-String
  if ($LASTEXITCODE -ne 0) { throw 'Native uptime command failed' }
  $clock = $clockOutput | ConvertFrom-Json
  if ($clock.command -isnot [string] -or $clock.command -ne 'boot-clock' -or $clock.ok -isnot [bool] -or $clock.ok -ne $true -or $clock.uptimeMs -isnot [string] -or $clock.uptimeMs -notmatch '^\d+$') {
    throw 'Native uptime evidence unavailable'
  }
  $uptime = $clock.uptimeMs
  @{
    version = 2; userSid = $sid; machineGuidSha256 = $machineDigest; uptimeMs = $uptime
    collectedAt = [DateTime]::UtcNow.ToString('o')
    lastBootUpTime = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    newest = Event-Evidence $newest; kernel = Event-Evidence $kernel $true; boot = Event-Evidence $boot $true
    checkpoint = $checkpoint
    legacyRunOnce = $legacy; nativeRunOnce = $native; knownWriters = $writers
  } | ConvertTo-Json -Depth 5 -Compress
} catch {
  [Console]::Error.WriteLine("Migration evidence unavailable; do not enable resident: $_")
  exit 2
}
