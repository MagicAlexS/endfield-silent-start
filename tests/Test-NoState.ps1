#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceDirectory = Split-Path -Parent $PSScriptRoot
$runnerSource = Join-Path $sourceDirectory 'Start-Endfield.ps1'
$nativeSource = Join-Path $sourceDirectory 'HiddenDesktopNative.cs'
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SilentStartNoState-' + [Guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $testRoot 'tool'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-DirectoryInventory([string]$Path) {
    $prefix = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    return @(
        Get-ChildItem -LiteralPath $Path -Force -Recurse | ForEach-Object {
            $relativePath = $_.FullName.Substring($prefix.Length)
            if ($_.PSIsContainer) { $relativePath + '|directory' }
            else { $relativePath + '|file|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        } | Sort-Object
    )
}

try {
    Assert ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'No-state checks require Windows PowerShell.'
    Assert ([Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) 'No-state checks require 64-bit Windows PowerShell.'
    Assert (Test-Path -LiteralPath $runnerSource -PathType Leaf) "Main script not found: $runnerSource"
    Assert (Test-Path -LiteralPath $nativeSource -PathType Leaf) "Native helper source not found: $nativeSource"

    $sourceLines = [System.IO.File]::ReadAllLines($runnerSource)
    $legacyStatePattern = '(?i)Save-RunState|Save-CleanupState|Get-RecordedState|Test-RecordedProcessLive|Invoke-StopLastRun|StopLastRun|StatePointerPath|RunStatePath|last-run\.txt|run-[^''\s]+\.json'
    $legacyStateLines = @(
        for ($index = 0; $index -lt $sourceLines.Length; $index++) {
            if ($sourceLines[$index] -match $legacyStatePattern) { '{0}: {1}' -f ($index + 1), $sourceLines[$index].Trim() }
        }
    )
    Assert ($legacyStateLines.Count -eq 0) ('Persistent run state references remain in Start-Endfield.ps1: ' + ($legacyStateLines -join '; '))

    $currentFunction = ''
    $mutationErrors = New-Object 'System.Collections.Generic.List[string]'
    $writePattern = '(?i)\[System\.IO\.File\]::(?:WriteAllText|WriteAllBytes|WriteAllLines|AppendAllText|AppendAllLines|CreateText|OpenWrite|Move|Delete|Replace)\b'
    $directoryPattern = '(?i)\[System\.IO\.Directory\]::(?:CreateDirectory|Delete|Move)\b'
    $commandPattern = '(?i)^\s*(?:New-Item|Set-Content|Add-Content|Out-File|Remove-Item|Copy-Item|Move-Item|Rename-Item|Clear-Content)\b'
    for ($index = 0; $index -lt $sourceLines.Length; $index++) {
        $line = $sourceLines[$index]
        if ($line -match '^\s*function\s+([\w-]+)\b') { $currentFunction = $Matches[1] }

        if ($line -match $writePattern) {
            if ($currentFunction -ne 'Compile-MockWindow') { $mutationErrors.Add(('{0}: file write is outside Compile-MockWindow' -f ($index + 1))) }
        }
        if ($line -match $directoryPattern) {
            if ($currentFunction -ne 'Invoke-SelfTest') { $mutationErrors.Add(('{0}: directory mutation is outside Invoke-SelfTest' -f ($index + 1))) }
        }
        if ($line -match $commandPattern) {
            if ($currentFunction -ne 'Invoke-SelfTest') { $mutationErrors.Add(('{0}: filesystem command is outside Invoke-SelfTest' -f ($index + 1))) }
        }
        if ($line -match '(?i)-RedirectStandard(?:Output|Error|Input)\b' -and $currentFunction -ne 'Invoke-SelfTest') {
            $mutationErrors.Add(('{0}: redirected process output is outside Invoke-SelfTest' -f ($index + 1)))
        }
    }
    Assert ($mutationErrors.Count -eq 0) ('Runtime filesystem writes were found: ' + ($mutationErrors -join '; '))

    [void](New-Item -ItemType Directory -Path $toolDirectory)
    Copy-Item -LiteralPath $runnerSource -Destination (Join-Path $toolDirectory 'Start-Endfield.ps1')
    Copy-Item -LiteralPath $nativeSource -Destination (Join-Path $toolDirectory 'HiddenDesktopNative.cs')
    $before = @(Get-DirectoryInventory $toolDirectory)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $toolDirectory 'Start-Endfield.ps1') -SelfTest 2>&1 |
            ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }

    Assert ($exitCode -eq 0) ("SelfTest failed with exit code ${exitCode}:`n" + ($output -join [Environment]::NewLine))
    $after = @(Get-DirectoryInventory $toolDirectory)
    Assert (([string]::Join([Environment]::NewLine, $before)) -ceq ([string]::Join([Environment]::NewLine, $after))) (
        "SelfTest changed the tool directory contents.`nBefore: $($before -join ', ')`nAfter: $($after -join ', ')"
    )

    Write-Output 'No-state checks passed: startup/cleanup self-test left the tool directory unchanged, and filesystem writes are confined to self-test helpers.'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempRootPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $testRootLeaf = [System.IO.Path]::GetFileName($resolvedTestRoot)
        if (-not $resolvedTestRoot.StartsWith($tempRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $testRootLeaf.StartsWith('SilentStartNoState-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove the test directory outside its validated temporary location: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
