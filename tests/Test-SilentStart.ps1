#requires -Version 5.1
# Isolated launcher regression test. It compiles an asInvoker copy into a fresh temp folder
# and runs only a mock PowerShell script; it never starts the game or requests UAC.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceDirectory = Split-Path -Parent $PSScriptRoot
$cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('EndfieldSilentStart-' + [Guid]::NewGuid().ToString('N'))
$savedCode = $env:ENDFIELD_SILENT_START_TEST_CODE
$savedRecord = $env:ENDFIELD_SILENT_START_TEST_RECORD
$createdDirectory = $false
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-TestRunner([string]$Path) {
    $runner = @'
param([switch]$StopLastRun)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct HiddenStartStartupInfo {
    public UInt32 cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle;
    public UInt32 dwX; public UInt32 dwY; public UInt32 dwXSize; public UInt32 dwYSize;
    public UInt32 dwXCountChars; public UInt32 dwYCountChars; public UInt32 dwFillAttribute;
    public UInt32 dwFlags; public UInt16 wShowWindow; public UInt16 cbReserved2;
    public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
}
public static class HiddenStartNative {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern void GetStartupInfo(ref HiddenStartStartupInfo info);
}
"@
$startup = New-Object HiddenStartStartupInfo
$startup.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][HiddenStartStartupInfo])
[HiddenStartNative]::GetStartupInfo([ref]$startup)
$childArguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $childArguments -WindowStyle Hidden -PassThru
try {
    $null = $child.Handle
    $record = [ordered]@{
        ConsoleWindow = [long][HiddenStartNative]::GetConsoleWindow()
        StartupFlags = $startup.dwFlags
        ShowWindow = $startup.wShowWindow
        ChildPid = $child.Id
        ChildStartTimeUtcTicks = $child.StartTime.ToUniversalTime().Ticks
        ChildPath = $child.MainModule.FileName
        StopLastRun = [bool]$StopLastRun
    }
    [IO.File]::WriteAllText($env:ENDFIELD_SILENT_START_TEST_RECORD, (ConvertTo-Json $record -Compress))
}
finally { $child.Dispose() }
exit ([int]$env:ENDFIELD_SILENT_START_TEST_CODE)
'@
    [IO.File]::WriteAllText($Path, $runner)
}

function Invoke-LauncherCase([string]$Name, [string[]]$Arguments, [int]$ExpectedExitCode, [bool]$ExpectRunner) {
    $recordPath = Join-Path $testDirectory ($Name + '.json')
    $env:ENDFIELD_SILENT_START_TEST_CODE = [string]$ExpectedExitCode
    $env:ENDFIELD_SILENT_START_TEST_RECORD = $recordPath
    $launcherPath = Join-Path $testDirectory 'EndfieldSilentStart.exe'
    $argumentsText = [string]::Join(' ', $Arguments)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $startParameters = @{
        FilePath = $launcherPath
        WorkingDirectory = $testDirectory
        PassThru = $true
        WindowStyle = 'Hidden'
    }
    if ($Arguments.Count -gt 0) { $startParameters.ArgumentList = $argumentsText }
    $launcher = Start-Process @startParameters
    $descendant = $null
    try {
        $null = $launcher.Handle
        if (-not $launcher.WaitForExit(8000)) { throw "${Name}: native launcher waited for its long-running descendant." }
        Assert ($launcher.ExitCode -eq $ExpectedExitCode) "${Name}: expected exit code $ExpectedExitCode, got $($launcher.ExitCode)."
        Assert (-not (Test-Path -LiteralPath (Join-Path $testDirectory 'EndfieldSilentStart.log'))) "${Name}: native launcher unexpectedly wrote a log file."
        if ($ExpectRunner) {
            Assert (Test-Path -LiteralPath $recordPath -PathType Leaf) "${Name}: mock runner did not write its record."
            $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
            $descendant = [Diagnostics.Process]::GetProcessById([int]$record.ChildPid)
            $null = $descendant.Handle
            Assert (-not $descendant.HasExited) "${Name}: the simulated game descendant exited before the launcher."
            Assert ([string]::Equals($descendant.MainModule.FileName, (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), [StringComparison]::OrdinalIgnoreCase)) "${Name}: descendant image did not match Windows PowerShell."
            $recordedStartTicks = [long]$record.ChildStartTimeUtcTicks
            Assert ([Math]::Abs(($descendant.StartTime.ToUniversalTime().Ticks - $recordedStartTicks) / 10000.0) -lt 1000) "${Name}: descendant start time did not match the mock record."
            Assert ($record.ConsoleWindow -eq 0) "${Name}: mock PowerShell has a console window handle ($($record.ConsoleWindow))."
            if ($Arguments.Count -gt 0) { Assert ($record.StopLastRun) "${Name}: -StopLastRun was not forwarded." }
            Assert ($watch.ElapsedMilliseconds -lt 8000) "${Name}: launcher did not finish promptly."
            Write-Host ("PASS: {0} returned {1} in {2} ms; mock PowerShell has no console and child PID {3} remains alive." -f $Name, $ExpectedExitCode, $watch.ElapsedMilliseconds, $record.ChildPid)
        }
        else {
            Assert (-not (Test-Path -LiteralPath $recordPath)) "${Name}: invalid arguments unexpectedly launched PowerShell."
            Write-Host ("PASS: {0} rejected arguments with exit code {1}." -f $Name, $ExpectedExitCode)
        }
    }
    finally {
        if ($descendant) {
            try {
                if (-not $descendant.HasExited) {
                    $expectedStartTicks = [long](ConvertFrom-Json (Get-Content -LiteralPath $recordPath -Raw)).ChildStartTimeUtcTicks
                    $actualStartTicks = $descendant.StartTime.ToUniversalTime().Ticks
                    $actualPath = $descendant.MainModule.FileName
                    if ([Math]::Abs(($actualStartTicks - $expectedStartTicks) / 10000.0) -ge 1000 -or
                        -not [string]::Equals($actualPath, (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to stop PID $($descendant.Id): recorded start ticks $expectedStartTicks and expected PowerShell path; observed $actualStartTicks and '$actualPath'."
                    }
                    $descendant.Kill()
                    $descendant.WaitForExit()
                }
            }
            finally { $descendant.Dispose() }
        }
        elseif (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            try {
                $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
                $descendant = [Diagnostics.Process]::GetProcessById([int]$record.ChildPid)
                $null = $descendant.Handle
                if (-not $descendant.HasExited) {
                    $expectedStartTicks = [long]$record.ChildStartTimeUtcTicks
                    if ([Math]::Abs(($descendant.StartTime.ToUniversalTime().Ticks - $expectedStartTicks) / 10000.0) -ge 1000 -or
                        -not [string]::Equals($descendant.MainModule.FileName, (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Refusing to stop a process whose start time or image does not match the test record.'
                    }
                    $descendant.Kill()
                    $descendant.WaitForExit()
                }
            }
            catch [ArgumentException] { }
            finally { if ($descendant) { $descendant.Dispose() } }
        }
        if (-not $launcher.HasExited) {
            try {
                if ([string]::Equals($launcher.MainModule.FileName, $launcherPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $launcher.Kill()
                    $launcher.WaitForExit()
                }
                else { throw 'Refusing to stop a process whose image does not match the native launcher.' }
            }
            finally { $launcher.Dispose() }
        }
        else { $launcher.Dispose() }
    }
}

try {
    Assert (Test-Path -LiteralPath $cscPath -PathType Leaf) '64-bit .NET Framework csc.exe was not found.'
    Assert (-not (Test-Path -LiteralPath $testDirectory)) 'The randomly named test directory already exists.'
    [void](New-Item -ItemType Directory -Path $testDirectory)
    $createdDirectory = $true

    Copy-Item -LiteralPath (Join-Path $sourceDirectory 'SilentStart.cs') -Destination $testDirectory
    Write-TestRunner (Join-Path $testDirectory 'Start-Endfield.ps1')
    $testManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" name="EndfieldSilentStart.Test" processorArchitecture="amd64" type="win32" />
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false" /></requestedPrivileges></security></trustInfo>
</assembly>
'@
    [IO.File]::WriteAllText((Join-Path $testDirectory 'test.manifest'), $testManifest)
    $testExecutable = Join-Path $testDirectory 'EndfieldSilentStart.exe'
    & $cscPath /nologo /target:winexe /platform:x64 (('/win32manifest:' + (Join-Path $testDirectory 'test.manifest'))) (('/out:' + $testExecutable)) (Join-Path $testDirectory 'SilentStart.cs')
    if ($LASTEXITCODE -ne 0) { throw "Test launcher compilation failed with exit code $LASTEXITCODE." }

    Invoke-LauncherCase 'default-zero' @() 0 $true
    Invoke-LauncherCase 'default-nonzero' @() 37 $true
    Invoke-LauncherCase 'stop-last-run' @('-stoplastrun') 0 $true
    Invoke-LauncherCase 'unsupported-option' @('-SelfTest') 2 $false
}
finally {
    $env:ENDFIELD_SILENT_START_TEST_CODE = $savedCode
    $env:ENDFIELD_SILENT_START_TEST_RECORD = $savedRecord
    if ($createdDirectory -and (Test-Path -LiteralPath $testDirectory -PathType Container)) {
        $allowedNames = @(
            'SilentStart.cs', 'Start-Endfield.ps1', 'test.manifest',
            'EndfieldSilentStart.exe', 'EndfieldSilentStart.log',
            'default-zero.json', 'default-nonzero.json', 'stop-last-run.json', 'unsupported-option.json'
        )
        foreach ($item in @(Get-ChildItem -LiteralPath $testDirectory -Force)) {
            if ($item.PSIsContainer -or $allowedNames -notcontains $item.Name) {
                $cleanupErrors.Add("Unrecognized test artifact left in $($item.FullName)")
                continue
            }
            try { Remove-Item -LiteralPath $item.FullName -Force }
            catch { $cleanupErrors.Add("Could not remove test artifact $($item.FullName): $($_.Exception.Message)") }
        }
        if (Test-Path -LiteralPath (Join-Path $testDirectory 'EndfieldSilentStart.log')) {
            $cleanupErrors.Add('The native test launcher unexpectedly created EndfieldSilentStart.log.')
        }
        if ($cleanupErrors.Count -eq 0) {
            try { Remove-Item -LiteralPath $testDirectory -Force }
            catch { $cleanupErrors.Add("Could not remove empty test directory ${testDirectory}: $($_.Exception.Message)") }
        }
    }
    if ($cleanupErrors.Count -ne 0) {
        foreach ($cleanupError in $cleanupErrors) { Write-Warning $cleanupError }
    }
}

if ($cleanupErrors.Count -ne 0) { throw 'Test artifacts were not fully cleaned; review the warnings above.' }
