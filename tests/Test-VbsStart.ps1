#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CscriptPath = ''
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = Split-Path -Parent $PSScriptRoot
$sourceVbs = Join-Path $sourceDirectory 'Start-Endfield.vbs'
if (-not $CscriptPath) { $CscriptPath = Join-Path $env:WINDIR 'System32\cscript.exe' }
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testLeaf = 'Endfield-VbsStart-' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ($testLeaf + ' 中文')
$testStartedUtc = [DateTime]::UtcNow
$childProcess = $null
$childIdentity = $null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Cscript([string]$ScriptPath, [string[]]$ScriptArguments = @()) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:CscriptPath
    $startInfo.Arguments = '//B //NoLogo "' + $ScriptPath + '"'
    if ($ScriptArguments.Count -gt 0) { $startInfo.Arguments += ' ' + ($ScriptArguments -join ' ') }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start cscript.exe.' }
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'cscript.exe did not exit within 15 seconds.'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }
    finally { $process.Dispose() }
}

function Get-ProcessIfPresent([int]$Id) {
    try { return [Diagnostics.Process]::GetProcessById($Id) }
    catch [ArgumentException] { return $null }
}

try {
    Assert ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'VBS entry checks require Windows.'
    Assert ([Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) 'VBS entry checks require 64-bit Windows PowerShell.'
    Assert (Test-Path -LiteralPath $cscriptPath -PathType Leaf) 'VBScript engine is unavailable: cscript.exe was not found.'
    Assert (Test-Path -LiteralPath $sourceVbs -PathType Leaf) "VBS entry was not found: $sourceVbs"

    $vbsBytes = [IO.File]::ReadAllBytes($sourceVbs)
    Assert (@($vbsBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'Start-Endfield.vbs must contain ASCII only.'
    $testRoot = [IO.Path]::GetFullPath($testRoot)
    [void](New-Item -ItemType Directory -Path $testRoot)

    $entryDirectory = Join-Path $testRoot '有效 路径'
    [void](New-Item -ItemType Directory -Path $entryDirectory)
    $testVbs = Join-Path $entryDirectory 'Start-Endfield.vbs'
    $vbsText = [IO.File]::ReadAllText($sourceVbs, [Text.Encoding]::ASCII)
    Assert ([regex]::Matches($vbsText, [regex]::Escape('"runas", 0')).Count -eq 1) 'Expected exactly one UAC runas ShellExecute call.'
    [IO.File]::WriteAllText($testVbs, $vbsText.Replace('"runas", 0', '"open", 0'), [Text.Encoding]::ASCII)

    $childScript = Join-Path $entryDirectory 'SleepChild.ps1'
    [IO.File]::WriteAllText($childScript, @'
Start-Sleep -Seconds 90
'@, [Text.Encoding]::ASCII)
    $mockRunner = Join-Path $entryDirectory 'Start-Endfield.ps1'
    [IO.File]::WriteAllText($mockRunner, @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition "using System; using System.Runtime.InteropServices; public static class VbsConsoleCheck { [DllImport(`"kernel32.dll`")] public static extern IntPtr GetConsoleWindow(); [DllImport(`"user32.dll`")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowVisible(IntPtr handle); }"
$childScript = Join-Path $PSScriptRoot 'SleepChild.ps1'
$childArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $childScript + '"'
$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $childArguments -WindowStyle Hidden -WorkingDirectory ([IO.Path]::GetTempPath()) -PassThru
$childStartTimeTicks = $child.StartTime.ToUniversalTime().Ticks
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'child.pid'), (ConvertTo-Json ([ordered]@{ ProcessId = $child.Id; StartTimeTicks = $childStartTimeTicks })), [Text.Encoding]::UTF8)
$handle = [VbsConsoleCheck]::GetConsoleWindow()
$visible = $handle -ne [IntPtr]::Zero -and [VbsConsoleCheck]::IsWindowVisible($handle)
$evidence = [ordered]@{
    ProcessId = $PID
    StartTimeTicks = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    Is64Bit = [Environment]::Is64BitProcess
    CurrentDirectory = [Environment]::CurrentDirectory
    ConsoleVisible = [bool]$visible
    ChildProcessId = $child.Id
    ChildStartTimeTicks = $childStartTimeTicks
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launch-evidence.json'), (ConvertTo-Json $evidence), [Text.Encoding]::UTF8)
exit 0
'@, [Text.Encoding]::ASCII)

    $launchWatch = [Diagnostics.Stopwatch]::StartNew()
    $launch = Invoke-Cscript $testVbs
    Assert ($launch.ExitCode -eq 0) ("VBS launch returned {0}: {1}{2}" -f $launch.ExitCode, $launch.StdOut, $launch.StdErr)
    Assert ([string]::IsNullOrEmpty($launch.StdOut) -and [string]::IsNullOrEmpty($launch.StdErr)) 'The VBS entry wrote console output.'

    $evidencePath = Join-Path $entryDirectory 'launch-evidence.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert (Test-Path -LiteralPath $evidencePath -PathType Leaf) 'The hidden PowerShell runner did not execute.'
    $evidence = [IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json
    Assert ([bool]$evidence.Is64Bit) 'The VBS entry did not launch 64-bit PowerShell.'
    Assert (-not [bool]$evidence.ConsoleVisible) 'The PowerShell console window is visible.'
    Assert ([string]::Equals([IO.Path]::GetFullPath([string]$evidence.CurrentDirectory), [IO.Path]::GetFullPath($entryDirectory), [StringComparison]::OrdinalIgnoreCase)) 'The VBS entry did not set the tool directory as the working directory.'

    $runnerExited = $false
    $runnerDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $runnerProcess = Get-ProcessIfPresent ([int]$evidence.ProcessId)
        if (-not $runnerProcess) { $runnerExited = $true; break }
        $runnerExited = $runnerProcess.HasExited -or
            $runnerProcess.StartTime.ToUniversalTime().Ticks -ne [long]$evidence.StartTimeTicks
        $runnerProcess.Dispose()
        if ($runnerExited) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $runnerDeadline)
    Assert ($runnerExited) 'The mock PowerShell runner did not exit promptly.'
    Assert ($launchWatch.Elapsed.TotalSeconds -lt 15) 'The VBS entry waited for the long-lived mock game process.'

    $childPidPath = Join-Path $entryDirectory 'child.pid'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $childPidPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert (Test-Path -LiteralPath $childPidPath -PathType Leaf) 'The long-lived mock child did not start.'
    $childIdentity = [IO.File]::ReadAllText($childPidPath) | ConvertFrom-Json
    Assert ([int]$childIdentity.ProcessId -eq [int]$evidence.ChildProcessId) 'The mock child identity did not match launch evidence.'
    Assert ([long]$childIdentity.StartTimeTicks -eq [long]$evidence.ChildStartTimeTicks) 'The mock child start time did not match launch evidence.'
    $childProcess = [Diagnostics.Process]::GetProcessById([int]$childIdentity.ProcessId)
    $null = $childProcess.Handle
    Assert (-not $childProcess.HasExited) 'The mock child exited before the VBS entry.'
    Assert ($childProcess.StartTime.ToUniversalTime().Ticks -eq [long]$childIdentity.StartTimeTicks) 'Refusing to stop a process with a different start time.'
    Assert ([string]::Equals([IO.Path]::GetFullPath($childProcess.MainModule.FileName), [IO.Path]::GetFullPath($powershellPath), [StringComparison]::OrdinalIgnoreCase)) 'Refusing to stop a process outside this test identity.'

    $actualFiles = @(Get-ChildItem -LiteralPath $entryDirectory -Force -File | ForEach-Object Name | Sort-Object)
    $expectedFiles = @('Start-Endfield.vbs', 'SleepChild.ps1', 'Start-Endfield.ps1', 'child.pid', 'launch-evidence.json') | Sort-Object
    Assert (([string]::Join('|', $actualFiles)) -ceq ([string]::Join('|', $expectedFiles))) ('Unexpected files appeared in the tool directory: ' + ($actualFiles -join ', '))

    $missingDirectory = Join-Path $testRoot 'missing runner'
    [void](New-Item -ItemType Directory -Path $missingDirectory)
    $missingVbs = Join-Path $missingDirectory 'Start-Endfield.vbs'
    [IO.File]::Copy($testVbs, $missingVbs, $false)
    $missingResult = Invoke-Cscript $missingVbs
    Assert ($missingResult.ExitCode -eq 1) "Missing runner returned exit code $($missingResult.ExitCode), expected 1."
    Assert ([string]::IsNullOrEmpty($missingResult.StdOut) -and [string]::IsNullOrEmpty($missingResult.StdErr)) 'The missing-runner path wrote console output.'

    $argumentResult = Invoke-Cscript $missingVbs @('unexpected')
    Assert ($argumentResult.ExitCode -eq 2) "Unsupported arguments returned exit code $($argumentResult.ExitCode), expected 2."
    Assert ([string]::IsNullOrEmpty($argumentResult.StdOut) -and [string]::IsNullOrEmpty($argumentResult.StdErr)) 'The unsupported-argument path wrote console output.'

    $missingFiles = @(Get-ChildItem -LiteralPath $missingDirectory -Force -File | ForEach-Object Name)
    Assert ($missingFiles.Count -eq 1 -and $missingFiles[0] -ceq 'Start-Endfield.vbs') 'Failure paths created unexpected files.'
    Write-Output 'VBS entry checks passed: hidden 64-bit launch, working directory, fast exit, no wrapper state files, missing-runner and argument exit codes.'
}
finally {
    if (-not $childProcess) {
        $orphanPidPath = Join-Path (Join-Path $testRoot '有效 路径') 'child.pid'
        if (Test-Path -LiteralPath $orphanPidPath -PathType Leaf) {
            $childIdentity = [IO.File]::ReadAllText($orphanPidPath) | ConvertFrom-Json
            $childProcess = Get-ProcessIfPresent ([int]$childIdentity.ProcessId)
            if ($childProcess -and $childProcess.StartTime.ToUniversalTime().Ticks -ne [long]$childIdentity.StartTimeTicks) {
                $childProcess.Dispose()
                $childProcess = $null
            }
        }
    }
    if ($childProcess) {
        if (-not $childProcess.HasExited) {
            if (-not $childIdentity -or $childProcess.StartTime.ToUniversalTime().Ticks -ne [long]$childIdentity.StartTimeTicks -or
                -not [string]::Equals([IO.Path]::GetFullPath($childProcess.MainModule.FileName), [IO.Path]::GetFullPath($powershellPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing to stop a process outside this test identity.'
            }
            $childProcess.Kill()
            $childProcess.WaitForExit()
        }
        $childProcess.Dispose()
    }

    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.Path]::GetFileName($resolvedRoot).StartsWith($testLeaf, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a directory outside this test's temporary location: $resolvedRoot"
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
