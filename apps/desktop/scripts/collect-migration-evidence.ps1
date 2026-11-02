param([long]$CheckpointRecord = 0)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Read only. Failure to access the System log or CIM is not evidence of a restart.
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
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $newest = Get-WinEvent -LogName System -MaxEvents 1
  $kernel = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12} -MaxEvents 1
  $boot = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Boot';Id=27} -MaxEvents 1
  $checkpoint = $null
  if ($CheckpointRecord -gt 0) {
    $old = Get-WinEvent -LogName System -FilterXPath "*[System[EventRecordID=$CheckpointRecord]]" -MaxEvents 1
    $checkpoint = Event-Evidence $old
  }
  $os = Get-CimInstance Win32_OperatingSystem
  $legacyKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  $legacy = $null
  if (Test-Path -LiteralPath $legacyKey) {
    $entry = (Get-ItemProperty -LiteralPath $legacyKey).PSObject.Properties['ClashKuroSysProxyCleanup']
    if ($null -ne $entry) { $legacy = [string]$entry.Value }
  }
  # Names are a conservative known-writer screen, not proof against renamed or unknown programs.
  $writers = @(Get-Process | Where-Object { $_.ProcessName -in @('Clash Kuro', 'kuro-sysproxy', 'mihomo', 'clash-verge', 'Fiddler', 'Fiddler Everywhere') } |
    ForEach-Object { @{ pid = $_.Id; name = $_.ProcessName } })
  @{
    version = 1; userSid = $sid; collectedAt = [DateTime]::UtcNow.ToString('o')
    lastBootUpTime = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    newest = Event-Evidence $newest; kernel = Event-Evidence $kernel $true; boot = Event-Evidence $boot $true
    checkpoint = $checkpoint
    legacyRunOnce = $legacy; knownWriters = $writers
  } | ConvertTo-Json -Depth 5 -Compress
} catch {
  [Console]::Error.WriteLine("Migration evidence unavailable; do not enable resident: $_")
  exit 2
}
