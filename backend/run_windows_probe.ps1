[CmdletBinding()]
param(
    [ValidateSet('doctor', 'device', 'services', 'trace', 'afc-canary', 'atc-listen', 'atc-handshake', 'atc-sync-check', 'airlift-canary')]
    [string]$Command = 'doctor',
    [switch]$Setup,
    [string]$Udid,
    [string[]]$DllDir = @(),
    [ValidateRange(1, 30)][int]$Seconds = 15,
    [string]$Report,
    [string]$AppleRuntime
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $projectRoot '.tmp/windows-prototype-py312'
$runtime = Join-Path $venv 'Scripts/python.exe'
if ($Setup) {
    if (-not (Test-Path -LiteralPath $runtime)) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            & uv venv $venv --python 3.12
        } elseif (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3.12 -m venv $venv
        } else {
            throw 'Install Python 3.12 with the py launcher, or uv, then rerun -Setup.'
        }
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the prototype environment.' }
    }
    $requirements = Join-Path $PSScriptRoot 'requirements-windows-prototype.txt'
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        & uv pip install --python $runtime -r $requirements
    } else {
        & $runtime -m pip install -r $requirements
    }
    if ($LASTEXITCODE -ne 0) { throw 'Prototype dependency installation failed.' }
}
if (-not (Test-Path -LiteralPath $runtime)) {
    throw 'Prototype environment is missing. Run .\backend\run_windows_probe.ps1 -Setup from the project root first.'
}
$probeArgs = @((Join-Path $PSScriptRoot 'windows_probe.py'), $Command, '--seconds', "$Seconds")
if ($Udid) { $probeArgs += @('--udid', $Udid) }
if ($Report) { $probeArgs += @('--report', $Report) }
if ($AppleRuntime) { $probeArgs += @('--apple-runtime', $AppleRuntime) }
foreach ($directory in $DllDir) { $probeArgs += @('--dll-dir', $directory) }
& $runtime @probeArgs
exit $LASTEXITCODE
