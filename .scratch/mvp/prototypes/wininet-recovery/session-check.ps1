[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('before-restart', 'after-restart', 'prepare', 'before', 'after', 'restore')]
    [string]$Phase,
    [string]$Data = 'C:\Users\DT-056\kuro-session-experiment\run1'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$endpoint = '127.0.0.1:48967'
$package = $PSScriptRoot
if (!(Test-Path -LiteralPath (Join-Path $package 'bin\probe.exe'))) {
    $package = Join-Path $package 'out\session-package'
}
$package = [IO.Path]::GetFullPath($package)
$probe = Join-Path $package 'bin\probe.exe'
$carrierExe = Join-Path $package 'runtime\electron.exe'
$helperExe = Join-Path $package 'bin\session.exe'
$coreExe = Join-Path $package 'bin\mihomo.exe'
$packageExes = @($probe, $carrierExe, $helperExe, $coreExe, (Join-Path $package 'bin\session-fake.exe'))

# Reject junctions as well as lexical repo paths before creating any evidence files.
if ($Data -notmatch '^[A-Za-z]:\\' -or $Data.Contains('"')) { throw 'Data must be an absolute local path without quotes.' }
$Data = [IO.Path]::GetFullPath($Data).TrimEnd('\')
if ($Data -eq [IO.Path]::GetPathRoot($Data).TrimEnd('\')) { throw 'Data must be a dedicated run directory.' }
for ($dir = $Data; $dir; $dir = [IO.Path]::GetDirectoryName($dir)) {
    if (Test-Path -LiteralPath $dir) {
        if ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Data has a junction/symlink ancestor: $dir"
        }
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { throw 'Data must be outside any repository.' }
    }
}
if ($Data -eq $package -or $Data.StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Data must be outside the package.'
}
$backup = Join-Path $Data 'lan-ras.bin'

function Save-Json($Path, $Value) {
    $Value | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Read-Json($Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing evidence: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Boot-Time {
    (Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime.ToUniversalTime().ToString('o')
}
function Known-RunOnce {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
        try {
            $key = $hive.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\RunOnce', $false)
            if ($null -eq $key) { continue }
            try {
                foreach ($name in $key.GetValueNames()) {
                    if ($name.TrimStart([char[]]'!*') -in @('ClashKuroSysProxyCleanup', 'ClashKuroResidentCleanup')) {
                        [pscustomobject]@{ view = "$view"; name = $name; command = $key.GetValue($name, $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                    }
                }
            } finally { $key.Dispose() }
        } finally { $hive.Dispose() }
    }
}
function Process-Rows {
    @(Get-CimInstance Win32_Process -Property ProcessId, Name, ExecutablePath, CreationDate, CommandLine | ForEach-Object {
        [pscustomobject]@{ pid = [int]$_.ProcessId; name = $_.Name; path = $_.ExecutablePath
            created = $(if ($null -ne $_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null })
            command = $_.CommandLine }
    })
}
function Is-Writer($Row) {
    $Row.path -in $packageExes -or $Row.name -in @('Clash Kuro.exe', 'kuro-sysproxy.exe',
        'clash-verge.exe', 'verge-mihomo.exe', 'mihomo.exe', 'Fiddler.exe', 'Fiddler Everywhere.exe')
}
function Inventory {
    $rows = @(Process-Rows)
    [pscustomobject]@{ at = [DateTime]::UtcNow.ToString('o'); boot = Boot-Time
        user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        computer = [Environment]::MachineName; package = $package; data = $Data
        runOnce = @(Known-RunOnce); writers = @($rows | Where-Object { Is-Writer $_ })
        services = @($rows | Where-Object name -eq 'clash-verge-service.exe')
        listeners = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 48967 |
            Select-Object LocalAddress, LocalPort, OwningProcess) }
}
function Assert-Quiet($State) {
    if (@($State.runOnce).Count) { throw 'Known Kuro RunOnce remains. Inspect and manually retire only the exact known value, then Restart.' }
    if (@($State.writers).Count) { throw ('Writer/other proxy app still running (or unclassified): ' + ($State.writers | ConvertTo-Json -Depth 4 -Compress)) }
    if (@($State.listeners).Count) { throw 'Port 48967 is still listening; stop and identify its owner.' }
}
function Assert-Run($State) {
    $prepared = Read-Json (Join-Path $Data 'prepared.json')
    foreach ($field in @('user', 'computer', 'package', 'data')) {
        if ($prepared.$field -ne $State.$field) { throw "Run identity mismatch: $field" }
    }
    if (!(Test-Path -LiteralPath $backup -PathType Leaf) -or
        (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $prepared.backupSha256) {
        throw 'Backup missing or changed; preserve all evidence and stop.'
    }
}
function Invoke-Probe([string[]]$Arguments, [string]$Attempt = '') {
    if (!(Test-Path -LiteralPath $probe -PathType Leaf)) { throw "Missing package probe: $probe" }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $probe
    # Arguments here contain only fixed verbs, the validated Data path and endpoint.
    $process.StartInfo.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $record = @{ at = [DateTime]::UtcNow.ToString('o'); boot = Boot-Time; exited = $false; pid = $null; created = $null; path = $probe }
    if ($Attempt) { Save-Json $Attempt $record }
    $started = $false
    try {
        if (!$process.Start()) { throw 'Could not start package probe.' }
        $started = $true
        $record.pid = $process.Id
        $record.created = $process.StartTime.ToUniversalTime().ToString('o')
        if ($Attempt) { Save-Json $Attempt $record }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(10000)) { throw 'Probe exceeded 10000 ms; result uncertain.' }
        $text = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Probe refused/failed ($($process.ExitCode)): $text $errors" }
        $text | ConvertFrom-Json
    } finally {
        if ($started) {
            # Keep the exact child handle. Never kill a PID looked up after a timeout.
            if (!$process.HasExited) {
                try { $process.Kill() } catch { Write-Warning "Own probe termination failed: $_" }
            }
            if (!$process.WaitForExit(5000)) {
                $process.Dispose()
                throw 'Own probe exit unconfirmed. NO further restore: retain evidence and manually Restart.'
            }
            $record.exited = $true
            $record.exitCode = $process.ExitCode
            if ($Attempt) { Save-Json $Attempt $record }
        }
        $process.Dispose()
    }
}

switch ($Phase) {
    'before-restart' {
        $folder = $Data + '-before-restart'
        if (Test-Path -LiteralPath $folder) { throw "Keep existing evidence; choose a new -Data: $folder" }
        New-Item -ItemType Directory -Path $folder | Out-Null
        $state = Inventory
        Save-Json (Join-Path $folder 'inventory.json') $state
        & reg.exe export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' (Join-Path $folder 'internet-settings.reg') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Registry export failed. Stop before any experiment.' }
        $state | ConvertTo-Json -Depth 10
        Write-Output "Read-only registry capture saved in $folder. Exit known apps, inspect exact RunOnce values, then manually Restart Windows."
    }
    'after-restart' {
        $old = Read-Json ($Data + '-before-restart\inventory.json')
        $state = Inventory
        $state | ConvertTo-Json -Depth 10
        if ($old.user -ne $state.user -or $old.computer -ne $state.computer -or [DateTime]$state.boot -le [DateTime]$old.boot) {
            throw 'Expected the same user/machine after a full Restart.'
        }
        Assert-Quiet $state
        Write-Output 'Restart/read checks passed. No proxy writes or session operations performed.'
    }
    'prepare' {
        $old = Read-Json ($Data + '-before-restart\inventory.json')
        $state = Inventory
        if ($old.user -ne $state.user -or $old.computer -ne $state.computer -or [DateTime]$state.boot -le [DateTime]$old.boot) {
            throw 'Perform the documented full Restart before prepare.'
        }
        Assert-Quiet $state
        if (Test-Path -LiteralPath $Data) { throw 'Prepare requires a NEW Data directory; preserve old backups.' }
        foreach ($file in @('bin\probe.exe', 'bin\session.exe', 'bin\mihomo.exe', 'runtime\electron.exe', 'session-main.cjs')) {
            if (!(Test-Path -LiteralPath (Join-Path $package $file) -PathType Leaf)) { throw "Incomplete package: $file" }
        }
        New-Item -ItemType Directory -Path (Join-Path $Data 'core') | Out-Null
        Invoke-Probe -Arguments @('snapshot', $backup) | ConvertTo-Json -Depth 10 | Out-Host
        Invoke-Probe -Arguments @('verify', $backup) | ConvertTo-Json -Depth 10 | Out-Host
        @'
mixed-port: 48967
bind-address: 127.0.0.1
allow-lan: false
ipv6: false
mode: rule
log-level: info
rules:
  - MATCH,DIRECT
'@ | Set-Content -LiteralPath (Join-Path $Data 'core\runtime.yaml') -Encoding ASCII
        $state | Add-Member -NotePropertyName backupSha256 -NotePropertyValue (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
        Save-Json (Join-Path $Data 'prepared.json') $state
        Write-Output "Prepared only. Manual launcher (this WILL arm real WinINet):"
        Write-Output "& `"$carrierExe`" `"$(Join-Path $package 'session-main.cjs')`" `"--session-dir=$Data`""
    }
    'before' {
        $state = Inventory
        Assert-Run $state
        # Retain OS creation times even when readiness validation below fails.
        $file = Join-Path $Data 'before.json'
        if (Test-Path -LiteralPath $file) { throw 'before.json already exists; do not reuse an experiment run.' }
        Save-Json $file $state
        if (@($state.runOnce).Count) { throw 'Unexpected known RunOnce; stop.' }
        $attempt = Read-Json (Join-Path $Data 'attempt.json')
        $carrier = Read-Json (Join-Path $Data 'carrier.json')
        if ($attempt.fixture -ne $false -or $carrier.fixture -ne $false) { throw 'Fixture marker: never a manual real-session pass.' }
        if ($attempt.pid -ne $carrier.pid -or $carrier.ready -ne $true -or !$carrier.startedAt -or !$carrier.helperStartedAt -or
            !@($carrier.events | Where-Object event -eq 'native:ready').Count -or $carrier.PSObject.Properties['helperExit']) {
            throw 'Native ready evidence missing, attempt/PID mismatch, or helper already exited.'
        }
        foreach ($pair in @(@($carrier.pid, $carrierExe), @($carrier.helperPid, $helperExe))) {
            $match = @($state.writers | Where-Object { $_.pid -eq $pair[0] -and $_.path -eq $pair[1] -and $_.created })
            if ($match.Count -ne 1) { throw 'Carrier/helper PID, full path or OS creation time not confirmed.' }
        }
        $cores = @($state.writers | Where-Object path -eq $coreExe)
        if ($cores.Count -ne 1 -or !$cores[0].created) { throw 'Expected one real packaged Core with OS creation evidence.' }
        $native = Read-Json (Join-Path $Data 'helper-report.json')
        if ($native.fakeProxy -ne $false -or ($native.PSObject.Properties['fixture'] -and $native.fixture -ne $false)) {
            throw 'Native fake/fixture report: never a manual real-session pass.'
        }
        if ($native.phase -ne 'armed' -or $native.setVerified -ne $true -or
            $native.pid -ne $carrier.helperPid -or $native.corePid -ne $cores[0].pid) {
            throw 'Native armed/set verification or helper/Core identity does not match the live processes.'
        }
        foreach ($row in $state.writers) {
            if ($row.path -notin @($carrierExe, $helperExe, $coreExe) -or !$row.created -or
                ($row.path -eq $helperExe -and $row.pid -ne $carrier.helperPid)) { throw 'Other/unknown writer present; stop.' }
        }
        if (!@($state.listeners).Count -or @($state.listeners | Where-Object { $_.LocalAddress -ne '127.0.0.1' -or $_.OwningProcess -ne $cores[0].pid }).Count) {
            throw 'Expected port 48967 bound only to IPv4 loopback by the packaged Core.'
        }
        $settings = Invoke-Probe -Arguments @('get')
        $settings | ConvertTo-Json -Depth 10
        if ($settings.ok -ne $true -or !@($settings.connections).Count) { throw 'Incomplete WinINet query.' }
        foreach ($connection in $settings.connections) {
            if ($connection.flags -ne 3 -or $connection.proxyServer -ne $endpoint -or $connection.bypass -ne 'localhost;127.0.0.1;[::1]') {
                throw 'Every LAN/RAS connection must have flags=3, the fixed endpoint and fixture bypass before logoff.'
            }
        }
        $carrier | ConvertTo-Json -Depth 10
        $native | ConvertTo-Json -Depth 10
        Write-Output 'Ready checks passed. Save output outside repo; manually Sign out Windows, then sign back in. Do not quit the carrier first.'
    }
    'after' {
        $state = Inventory
        Assert-Run $state
        $state | ConvertTo-Json -Depth 10
        Write-Output '== session timing (read-only; same anchor as hitl-logoff-check.ps1)'
        Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Output ('explorerStartUtc=' + $_.StartTime.ToUniversalTime().ToString('o'))
        }
        try {
            $prepared = Read-Json (Join-Path $Data 'prepared.json')
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Winlogon';
                Id = 7001, 7002; StartTime = ([DateTime]$prepared.at).ToLocalTime() } -ErrorAction Stop |
                Sort-Object TimeCreated | ForEach-Object {
                    '{0} winlogon {1}' -f $_.TimeCreated.ToUniversalTime().ToString('o'), $(if ($_.Id -eq 7002) { 'logoff' } else { 'logon' })
                }
        } catch { Write-Output ('Session anchor unavailable; retain uncertainty: ' + $_.Exception.Message) }
        $fixture = $false
        foreach ($name in @('before.json', 'attempt.json', 'carrier.json', 'helper-report.json')) {
            Write-Output "== $name"
            $path = Join-Path $Data $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Get-Content -LiteralPath $path -Raw
                $report = Read-Json $path
                if ($report.PSObject.Properties['fixture'] -and $report.fixture -ne $false) { $fixture = $true }
                if ($report.PSObject.Properties['fakeProxy'] -and $report.fakeProxy -ne $false) { $fixture = $true }
            }
            else { Write-Output 'MISSING: uncertain evidence; not success.' }
        }
        Invoke-Probe -Arguments @('get') | ConvertTo-Json -Depth 10
        if ($fixture) { throw 'Fixture/fakeProxy marker present: manual session pass is disallowed, regardless of flags/reports.' }
        Write-Output 'Collection only: no files/settings changed. Inspect native session evidence and flags before any restoration.'
    }
    'restore' {
        if (!(Test-Path -LiteralPath $Data -PathType Container)) { throw 'Missing run directory.' }
        $lock = [IO.File]::Open((Join-Path $Data 'restore.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $state = Inventory
            Assert-Run $state
            Assert-Quiet $state
            foreach ($attempt in Get-ChildItem -LiteralPath $Data -Filter 'restore-attempt-*.json') {
                $previous = Read-Json $attempt.FullName
                if ($previous.exited -ne $true -and [DateTime]$state.boot -le [DateTime]$previous.at) {
                    throw 'Previous restore exit is unknown. No retry: manually Restart, collect read checks, then retry.'
                }
            }
            $beforeFile = Join-Path $Data 'before.json'
            if (Test-Path -LiteralPath $beforeFile) {
                $before = Read-Json $beforeFile
                if ([DateTime]$state.boot -le [DateTime]$before.boot) {
                    $rows = @(Process-Rows)
                    foreach ($record in $before.writers) {
                        if (!$record.path -or !$record.created) { throw 'Recorded writer identity incomplete; stop or manually Restart.' }
                        $current = @($rows | Where-Object pid -eq $record.pid)
                        if ($current.Count -and (!$current[0].path -or !$current[0].created -or
                            ($current[0].path -eq $record.path -and $current[0].created -eq $record.created))) {
                            throw 'Recorded PID still belongs to the writer, or PID reuse cannot be classified. Stop.'
                        }
                    }
                }
            }
            Assert-Quiet (Inventory)
            # The native probe performs per-connection preflight; never use reg import.
            $attemptFile = Join-Path $Data ('restore-attempt-' + [Guid]::NewGuid().ToString('N') + '.json')
            Invoke-Probe -Arguments @('restore', $backup, $endpoint) -Attempt $attemptFile | ConvertTo-Json -Depth 10
            Invoke-Probe -Arguments @('verify', $backup) | ConvertTo-Json -Depth 10
            Write-Output 'Original LAN/RAS fields verified. Keep all snapshots and reports; RunOnce was not changed.'
        } finally { $lock.Dispose() }
    }
}
