#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
if ($args.Count -gt 0) { exit 2 }
$runnerScript = Join-Path $PSScriptRoot 'Start-Endfield.ps1'
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $runnerScript + '"'
$exitCode = 1
$child = $null
try {
    # Wait for the runner process; its game process continues independently.
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -PassThru -NoNewWindow
    $null = $child.Handle
    $child.WaitForExit()
    $exitCode = [int]$child.ExitCode
    Write-Host "`nThe launcher process finished with exit code $exitCode."
}
catch {
    Write-Error $_ -ErrorAction Continue
    $exitCode = 1
}
finally {
    if ($child) { $child.Dispose() }
}
exit $exitCode
