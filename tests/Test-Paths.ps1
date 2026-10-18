#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceDirectory = Split-Path -Parent $PSScriptRoot
$sourceRunner = Join-Path $sourceDirectory 'Start-Endfield.ps1'
$sourceNative = Join-Path $sourceDirectory 'HiddenDesktopNative.cs'
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SilentStartPathChecks-' + [Guid]::NewGuid().ToString('N'))
$testCount = 0

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-ToolDirectory([string]$Path) {
    [void](New-Item -ItemType Directory -Path $Path -Force)
    Copy-Item -LiteralPath $sourceRunner -Destination (Join-Path $Path 'Start-Endfield.ps1')
    Copy-Item -LiteralPath $sourceNative -Destination (Join-Path $Path 'HiddenDesktopNative.cs')
}

function New-InstallRoot([string]$Path, [string[]]$GamesLocations) {
    [void](New-Item -ItemType Directory -Path $Path -Force)
    [void](New-Item -ItemType File -Path (Join-Path $Path 'Launcher.exe') -Force)
    $defaultGameDirectory = Join-Path $Path 'games\Endfield Game'
    [void](New-Item -ItemType Directory -Path $defaultGameDirectory -Force)
    [void](New-Item -ItemType File -Path (Join-Path $defaultGameDirectory 'Endfield.exe') -Force)
    foreach ($location in $GamesLocations) {
        $gamesPath = Join-Path $Path $location
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $gamesPath) -Force)
        [void](New-Item -ItemType File -Path $gamesPath -Force)
    }
}

function Invoke-PathCheck([string]$ToolDirectory, [string[]]$ExtraArguments = @()) {
    $runner = Join-Path $ToolDirectory 'Start-Endfield.ps1'
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-CheckOnly') + $ExtraArguments
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $powershellPath @arguments 2>&1 | ForEach-Object { [string]$_ }) }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Text = ($output -join [Environment]::NewLine)
        ToolDirectory = $ToolDirectory
    }
}

function Assert-PathOutput($Result, [string]$Launcher, [string]$Games, [string]$Game) {
    Assert ($Result.ExitCode -eq 0) "Path check failed with exit code $($Result.ExitCode):`n$($Result.Text)"
    foreach ($expected in @("Launcher=$Launcher", "Games=$Games", "Game=$Game")) {
        Assert ($Result.Text.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Expected '$expected' in path-check output:`n$($Result.Text)"
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $Result.ToolDirectory 'last-run.txt'))) 'Path check unexpectedly created last-run.txt.'
    Assert (@(Get-ChildItem -LiteralPath $Result.ToolDirectory -Filter 'run-*.json' -ErrorAction SilentlyContinue).Count -eq 0) 'Path check unexpectedly created run state JSON.'
}

try {
    Assert ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'Path checks require Windows PowerShell.'
    Assert ([Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) 'Path checks require 64-bit Windows PowerShell.'
    Assert (Test-Path -LiteralPath $sourceRunner -PathType Leaf) "Main script not found: $sourceRunner"
    Assert (Test-Path -LiteralPath $sourceNative -PathType Leaf) "Native helper not found: $sourceNative"
    [void](New-Item -ItemType Directory -Path $testRoot)

    # The recommended layout puts the entire tool directory directly under the game install root.
    $defaultLayout = Join-Path $testRoot 'default-layout'
    $defaultInstall = Join-Path $defaultLayout 'Install'
    New-InstallRoot $defaultInstall @('2.1.0\Games.exe')
    $defaultTool = Join-Path $defaultInstall 'SilentStart'
    New-ToolDirectory $defaultTool
    $result = Invoke-PathCheck $defaultTool
    Assert-PathOutput $result (Join-Path $defaultInstall 'Launcher.exe') (Join-Path $defaultInstall '2.1.0\Games.exe') (Join-Path $defaultInstall 'games\Endfield Game\Endfield.exe')
    $testCount++

    # The tool can also be placed directly in the install root.
    $sameDirectoryTool = Join-Path $testRoot 'same-directory-install'
    New-InstallRoot $sameDirectoryTool @('4.5.6\Games.exe')
    New-ToolDirectory $sameDirectoryTool
    $result = Invoke-PathCheck $sameDirectoryTool
    Assert-PathOutput $result (Join-Path $sameDirectoryTool 'Launcher.exe') (Join-Path $sameDirectoryTool '4.5.6\Games.exe') (Join-Path $sameDirectoryTool 'games\Endfield Game\Endfield.exe')
    $testCount++

    # A separate tool directory can point to a sibling install root with config.json.
    $configLayout = Join-Path $testRoot 'config-layout'
    $configTool = Join-Path $configLayout 'Tool'
    $configInstall = Join-Path $configLayout 'ExternalInstall'
    New-ToolDirectory $configTool
    New-InstallRoot $configInstall @('1.2.3\Games.exe')
    $customGameDirectory = Join-Path $configInstall 'custom'
    [void](New-Item -ItemType Directory -Path $customGameDirectory -Force)
    [void](New-Item -ItemType File -Path (Join-Path $customGameDirectory 'Endfield.exe') -Force)
    $config = [ordered]@{ InstallRoot = '..\ExternalInstall'; GamePath = 'custom\Endfield.exe'; GamesPath = '1.2.3\Games.exe' }
    [System.IO.File]::WriteAllText((Join-Path $configTool 'config.json'), (ConvertTo-Json $config), [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-PathCheck $configTool
    Assert-PathOutput $result (Join-Path $configInstall 'Launcher.exe') (Join-Path $configInstall '1.2.3\Games.exe') (Join-Path $configInstall 'custom\Endfield.exe')
    $testCount++

    # Command-line paths take precedence over config.json.
    $cliInstall = Join-Path $testRoot 'cli-install'
    New-InstallRoot $cliInstall @('3.4.5\Games.exe')
    $cliGameDirectory = Join-Path $cliInstall 'alternate'
    [void](New-Item -ItemType Directory -Path $cliGameDirectory -Force)
    [void](New-Item -ItemType File -Path (Join-Path $cliGameDirectory 'Endfield.exe') -Force)
    $result = Invoke-PathCheck $configTool @('-InstallRoot', $cliInstall, '-GamePath', 'alternate\Endfield.exe', '-GamesPath', '3.4.5\Games.exe')
    Assert-PathOutput $result (Join-Path $cliInstall 'Launcher.exe') (Join-Path $cliInstall '3.4.5\Games.exe') (Join-Path $cliInstall 'alternate\Endfield.exe')
    $testCount++

    # Multiple discovered candidates fail safely; an explicit allowed candidate resolves the choice.
    $multiLayout = Join-Path $testRoot 'multiple-games'
    $multiInstall = Join-Path $multiLayout 'Install'
    New-InstallRoot $multiInstall @('Games.exe', '7.8.9\Games.exe')
    $multiTool = Join-Path $multiInstall 'SilentStart'
    New-ToolDirectory $multiTool
    $result = Invoke-PathCheck $multiTool
    Assert ($result.ExitCode -ne 0) 'Multiple Games.exe candidates unexpectedly passed without selection.'
    Assert ($result.Text.Contains('Multiple Games.exe')) "Multiple-candidate error was unclear:`n$($result.Text)"
    $result = Invoke-PathCheck $multiTool @('-GamesPath', '7.8.9\Games.exe')
    Assert-PathOutput $result (Join-Path $multiInstall 'Launcher.exe') (Join-Path $multiInstall '7.8.9\Games.exe') (Join-Path $multiInstall 'games\Endfield Game\Endfield.exe')
    $testCount++

    # Explicit GamesPath remains confined to the root or one-level numeric version directories.
    $outsideGames = Join-Path $testRoot 'outside\Games.exe'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $outsideGames) -Force)
    [void](New-Item -ItemType File -Path $outsideGames -Force)
    $result = Invoke-PathCheck $multiTool @('-GamesPath', $outsideGames)
    Assert ($result.ExitCode -ne 0) 'GamesPath outside the allowed install-root candidates unexpectedly passed.'
    Assert ($result.Text.Contains('GamesPath must be Root')) "Invalid GamesPath error was unclear:`n$($result.Text)"
    $testCount++

    Write-Output "Path checks passed: $testCount cases."
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempRootPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $testRootLeaf = [System.IO.Path]::GetFileName($resolvedTestRoot)
        if (-not $resolvedTestRoot.StartsWith($tempRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $testRootLeaf.StartsWith('SilentStartPathChecks-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove the test directory outside its validated temporary location: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
