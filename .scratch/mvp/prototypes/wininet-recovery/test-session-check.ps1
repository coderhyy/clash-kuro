# Parse the real script and exercise only pure guards. No CIM, registry or proxy calls.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'session-check.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Is-Writer', 'Assert-Quiet')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (!$definition) { throw "Missing tested guard: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$packageExes = @('C:\fixture\session.exe', 'C:\fixture\mihomo.exe')
if (!(Is-Writer ([pscustomobject]@{path='C:\fixture\session.exe'; name='session.exe'}))) { throw 'Own helper missed' }
if (!(Is-Writer ([pscustomobject]@{path='D:\Clash Verge\clash-verge.exe'; name='clash-verge.exe'}))) { throw 'Known app missed' }
if (Is-Writer ([pscustomobject]@{path='C:\Windows\notepad.exe'; name='notepad.exe'})) { throw 'Unrelated app blocked' }
if (Is-Writer ([pscustomobject]@{path=$null; name='clash-verge-service.exe'})) { throw 'Informational service became an unsupported blocker' }
$quiet = [pscustomobject]@{runOnce=@(); writers=@(); listeners=@()}
Assert-Quiet $quiet
foreach ($field in @('runOnce', 'writers', 'listeners')) {
    $state = [pscustomobject]@{runOnce=@(); writers=@(); listeners=@()}
    $state.$field = @([pscustomobject]@{reason='injected conflict'})
    $rejected = $false
    try { Assert-Quiet $state } catch { $rejected = $true }
    if (!$rejected) { throw "Guard ignored $field" }
}
Write-Output 'PASS PowerShell syntax, known-writer selection and three conflict guards; no system calls.'
