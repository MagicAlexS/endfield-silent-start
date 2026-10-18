#requires -Version 5.1
# Wrapper regression test only: does not launch the game or request elevation.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceDirectory = Split-Path -Parent $PSScriptRoot
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('EndfieldSilentStartConsole-' + [Guid]::NewGuid().ToString('N'))
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$savedRunner = $env:ENDFIELD_SILENT_START_RUNNER
$savedArguments = $env:ENDFIELD_SILENT_START_ARGS
$savedExitCode = $env:ENDFIELD_SILENT_START_CONSOLE_EXIT
$testProcess = $null
$descendant = $null
[void](New-Item -ItemType Directory -Path $testDirectory)
try {
    Copy-Item -LiteralPath (Join-Path $sourceDirectory 'Start-Endfield-Elevated.ps1') -Destination $testDirectory
    $fakeMain = @'
param()
$ErrorActionPreference = 'Stop'
$argsText = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'SleepChild.ps1') + '"'
$mock = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argsText -WindowStyle Hidden -PassThru
try {
    $null = $mock.Handle
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'descendant.pid'), [string]$mock.Id)
}
finally { $mock.Dispose() }
exit ([int]$env:ENDFIELD_SILENT_START_CONSOLE_EXIT)
'@
    [IO.File]::WriteAllText((Join-Path $testDirectory 'Start-Endfield.ps1'), $fakeMain)
    [IO.File]::WriteAllText((Join-Path $testDirectory 'SleepChild.ps1'), 'Start-Sleep -Seconds 30')

    # Exercise the actual CMD PowerShell payload, replacing only its UAC verb.
    $commandLine = @(Get-Content -LiteralPath (Join-Path $sourceDirectory 'Start-Endfield.cmd') |
        Where-Object { $_ -match '^powershell\.exe .* -Command "(.*)"$' })
    if ($commandLine.Count -ne 1) { throw 'Expected one PowerShell command in the CMD wrapper.' }
    $null = $commandLine[0] -match '^powershell\.exe .* -Command "(.*)"$'
    $payload = $Matches[1]
    if ($payload -notlike '*-Verb RunAs*') { throw 'Expected the CMD elevation verb.' }
    [IO.File]::WriteAllText((Join-Path $testDirectory 'Outer-NoUac.ps1'), $payload.Replace('-Verb RunAs', '-WindowStyle Hidden'))
    $env:ENDFIELD_SILENT_START_RUNNER = Join-Path $testDirectory 'Start-Endfield-Elevated.ps1'
    $env:ENDFIELD_SILENT_START_ARGS = ''

    foreach ($entry in @('Start-Endfield-Elevated.ps1', 'Outer-NoUac.ps1')) {
        foreach ($expectedCode in @(0, 37)) {
            $pidFile = Join-Path $testDirectory 'descendant.pid'
            if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile }
            $env:ENDFIELD_SILENT_START_CONSOLE_EXIT = [string]$expectedCode
            $testStartedUtc = [DateTime]::UtcNow
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $entryArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $testDirectory $entry) + '"'
                $testProcess = Start-Process -FilePath $powershellPath -ArgumentList $entryArguments -WindowStyle Hidden -PassThru
                $null = $testProcess.Handle
                if (-not $testProcess.WaitForExit(8000)) { throw "$entry waited for the long-lived descendant." }
                if ($testProcess.ExitCode -ne $expectedCode) { throw "$entry returned $($testProcess.ExitCode), expected $expectedCode." }
                $descendant = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile))
                $null = $descendant.Handle
                if ($descendant.HasExited) { throw 'The simulated game exited before the wrapper; the test is inconclusive.' }
                Write-Host ("PASS: {0} exited with {1} in {2}ms while simulated game PID={3} remained running." -f $entry, $expectedCode, $watch.ElapsedMilliseconds, $descendant.Id)
            }
            finally {
                if (-not $descendant -and (Test-Path -LiteralPath $pidFile)) {
                    try { $descendant = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile)) } catch { }
                }
                if ($descendant) {
                    if (-not $descendant.HasExited) {
                        if ($descendant.StartTime.ToUniversalTime() -lt $testStartedUtc -or
                            -not [string]::Equals($descendant.MainModule.FileName, $powershellPath, [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'Refusing to stop a process outside this test identity.'
                        }
                        $descendant.Kill()
                        $descendant.WaitForExit()
                    }
                    $descendant.Dispose()
                    $descendant = $null
                }
                if ($testProcess) {
                    if (-not $testProcess.WaitForExit(2000)) { $testProcess.Kill(); $testProcess.WaitForExit() }
                    $testProcess.Dispose()
                    $testProcess = $null
                }
            }
        }
    }
}
finally {
    $env:ENDFIELD_SILENT_START_RUNNER = $savedRunner
    $env:ENDFIELD_SILENT_START_ARGS = $savedArguments
    $env:ENDFIELD_SILENT_START_CONSOLE_EXIT = $savedExitCode
    foreach ($name in @('Start-Endfield-Elevated.ps1', 'Start-Endfield.ps1', 'SleepChild.ps1', 'Outer-NoUac.ps1', 'descendant.pid')) {
        $path = Join-Path $testDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $testDirectory
}
