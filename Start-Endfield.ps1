#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$SelfTest,
    [switch]$StopLastRun,
    [string]$InstallRoot = '',
    [string]$GamePath = '',
    [string]$GamesPath = '',
    [string]$GameArguments = '',
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 60,
    [ValidateRange(5, 900)]
    [int]$GameWindowTimeoutSeconds = 300,
    [ValidateRange(0, 60)]
    [int]$InitializationDelaySeconds = 1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolDirectory = $PSScriptRoot
$script:StatePointerPath = Join-Path $script:ToolDirectory 'last-run.txt'
$script:SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$script:ProcessQueryAccess = 0x1000
$script:ProcessParentAccess = 0x00100000 -bor 0x0080 -bor 0x1000
$script:RunState = $null
$script:RunStatePath = $null
$script:LauncherReference = $null
$script:GamesReference = $null
$script:VisibleDesktopReference = $null

function Write-Status([string]$Message) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Write-RunStatus([string]$Message) {
    Write-Status $Message
}

function Save-RunState {
    if (-not $script:RunStatePath -or -not $script:RunState) { return }
    $json = ConvertTo-Json -InputObject $script:RunState -Depth 8
    [System.IO.File]::WriteAllText($script:RunStatePath, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($script:StatePointerPath, $script:RunStatePath, [System.Text.UTF8Encoding]::new($false))
}

function Get-ConfigPathValue($Config, [string]$Name) {
    if (-not $Config -or -not ($Config.PSObject.Properties.Name -contains $Name)) { return '' }
    $value = $Config.$Name
    if ($null -eq $value) { return '' }
    if ($value -isnot [string]) { throw "The config.json field '$Name' must be a string." }
    return $value.Trim()
}

function Get-SelectedPathValue($CommandLineValue, $Config, [string]$Name) {
    if (-not [string]::IsNullOrWhiteSpace([string]$CommandLineValue)) { return ([string]$CommandLineValue).Trim() }
    return (Get-ConfigPathValue $Config $Name)
}

function Resolve-ConfiguredPath([string]$Path, [string]$BaseDirectory, [string]$Description) {
    try {
        $combined = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BaseDirectory $Path }
        return [System.IO.Path]::GetFullPath($combined)
    }
    catch { throw "Invalid $Description path '$Path': $($_.Exception.Message)" }
}

function Get-InstallPaths {
    $configPath = Join-Path $script:ToolDirectory 'config.json'
    $config = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($configPath)) -ErrorAction Stop }
        catch { throw "Could not read config.json at '$configPath': $($_.Exception.Message)" }
    }

    $selectedRoot = Get-SelectedPathValue $InstallRoot $config 'InstallRoot'
    if ($selectedRoot) {
        $root = Resolve-ConfiguredPath $selectedRoot $script:ToolDirectory 'InstallRoot'
    }
    else {
        $toolRoot = [System.IO.Path]::GetFullPath($script:ToolDirectory)
        $parentRoot = [System.IO.Path]::GetFullPath((Join-Path $script:ToolDirectory '..'))
        if (Test-Path -LiteralPath (Join-Path $toolRoot 'Launcher.exe') -PathType Leaf) { $root = $toolRoot }
        elseif (Test-Path -LiteralPath (Join-Path $parentRoot 'Launcher.exe') -PathType Leaf) { $root = $parentRoot }
        else { throw "InstallRoot was not configured and Launcher.exe was not found in the tool directory or its parent. Set InstallRoot in config.json or pass -InstallRoot." }
    }

    $launcher = [System.IO.Path]::GetFullPath((Join-Path $root 'Launcher.exe'))
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Launcher.exe was not found at the selected install root: $launcher" }

    $selectedGame = Get-SelectedPathValue $GamePath $config 'GamePath'
    if (-not $selectedGame) { $selectedGame = 'games\Endfield Game\Endfield.exe' }
    $game = Resolve-ConfiguredPath $selectedGame $root 'GamePath'
    if ([System.IO.Path]::GetFileName($game) -ine 'Endfield.exe') { throw "GamePath must identify a file named Endfield.exe: $game" }
    if (-not (Test-Path -LiteralPath $game -PathType Leaf)) { throw "Endfield.exe was not found at the configured game path: $game" }

    $selectedGames = Get-SelectedPathValue $GamesPath $config 'GamesPath'
    $gamesCandidates = New-Object System.Collections.Generic.List[string]
    if ($selectedGames) {
        $explicitGames = Resolve-ConfiguredPath $selectedGames $root 'GamesPath'
        $allowedGamesPaths = New-Object System.Collections.Generic.List[string]
        $allowedGamesPaths.Add([System.IO.Path]::GetFullPath((Join-Path $root 'Games.exe')))
        foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) {
            if ($directory.Name -match '^\d+(\.\d+)*$') {
                $allowedGamesPaths.Add([System.IO.Path]::GetFullPath((Join-Path $directory.FullName 'Games.exe')))
            }
        }
        if ([System.IO.Path]::GetFileName($explicitGames) -ine 'Games.exe' -or
            -not ($allowedGamesPaths | Where-Object { [string]::Equals($_, $explicitGames, [StringComparison]::OrdinalIgnoreCase) })) {
            throw "GamesPath must be Root\Games.exe or Root\<numeric-version>\Games.exe: $explicitGames"
        }
        if (-not (Test-Path -LiteralPath $explicitGames -PathType Leaf)) { throw "Games.exe was not found at the configured GamesPath: $explicitGames" }
        $gamesCandidates.Add($explicitGames)
    }
    else {
        $directGames = Join-Path $root 'Games.exe'
        if (Test-Path -LiteralPath $directGames -PathType Leaf) {
            $gamesCandidates.Add([System.IO.Path]::GetFullPath($directGames))
        }
        foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) {
            if ($directory.Name -match '^\d+(\.\d+)*$') {
                $candidate = Join-Path $directory.FullName 'Games.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $gamesCandidates.Add([System.IO.Path]::GetFullPath($candidate))
                }
            }
        }
    }
    $uniqueGames = @($gamesCandidates | Sort-Object -Unique)
    if ($uniqueGames.Count -eq 0) { throw "No Games.exe was found at the install root or in a one-level numeric version directory under '$root'. Set GamesPath in config.json or pass -GamesPath." }
    if ($uniqueGames.Count -gt 1) { throw "Multiple Games.exe files were found under '$root': $($uniqueGames -join ', '). Set GamesPath in config.json or pass -GamesPath to select one." }
    [pscustomobject]@{ Root = $root; Launcher = $launcher; Games = $uniqueGames[0]; Game = $game }
}

function Get-SessionNamedProcesses {
    $filter = "Name='Launcher.exe' OR Name='Games.exe' OR Name='Endfield.exe'"
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop |
        Where-Object { [int]$_.SessionId -eq $script:SessionId } |
        ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                ProcessId = [uint32]$_.ProcessId
                ParentProcessId = [uint32]$_.ParentProcessId
                SessionId = [int]$_.SessionId
                ExecutablePath = [string]$_.ExecutablePath
            }
        })
    return $processes
}

function Import-NativeHelper {
    $sourcePath = Join-Path $script:ToolDirectory 'HiddenDesktopNative.cs'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Native helper source not found: $sourcePath" }
    $source = [System.IO.File]::ReadAllText($sourcePath)
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function ConvertTo-Identity($Snapshot) {
    [pscustomobject]@{
        ProcessId = [uint32]$Snapshot.ProcessId
        ParentProcessIdAtCapture = [uint32]$Snapshot.ParentProcessId
        SessionId = [uint32]$Snapshot.SessionId
        ImagePath = [string]$Snapshot.ImagePath
        CreationFileTimeUtc = [long]$Snapshot.CreationFileTimeUtc
        CreationTimeUtc = [DateTime]::FromFileTimeUtc([long]$Snapshot.CreationFileTimeUtc).ToString('o')
    }
}

function Get-RecordedState {
    if (-not (Test-Path -LiteralPath $script:StatePointerPath -PathType Leaf)) { return $null }
    $path = [System.IO.File]::ReadAllText($script:StatePointerPath).Trim()
    if (-not $path) { return $null }
    $fullPath = [System.IO.Path]::GetFullPath($path)
    $basePath = [System.IO.Path]::GetFullPath($script:ToolDirectory).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The last-run state path is outside this tool directory; refusing to use it.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }
    return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($fullPath)))
}

function Test-RecordedProcessLive($Identity) {
    if (-not $Identity -or -not $Identity.ProcessId) { return $false }
    $processRows = @(Get-SessionNamedProcesses | Where-Object { $_.ProcessId -eq [uint32]$Identity.ProcessId })
    if ($processRows.Count -eq 0) { return $false }
    $expectedPath = [string]$Identity.ImagePath
    $expectedTime = [long]$Identity.CreationFileTimeUtc
    try {
        $reference = [HiddenDesktopNative]::OpenProcessRef([uint32]$Identity.ProcessId, $script:ProcessQueryAccess -bor 0x00100000)
        try {
            $snapshot = [HiddenDesktopNative]::ReadProcess($reference)
            return ([HiddenDesktopNative]::IsRunning($reference) -and
                $snapshot.CreationFileTimeUtc -eq $expectedTime -and
                [string]::Equals([System.IO.Path]::GetFullPath($snapshot.ImagePath), [System.IO.Path]::GetFullPath($expectedPath), [StringComparison]::OrdinalIgnoreCase))
        }
        finally { $reference.Dispose() }
    }
    catch { throw "A recorded process identity is still named in this session but cannot be verified (PID $($Identity.ProcessId)); refusing to overwrite its state. $($_.Exception.Message)" }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-64BitWindows {
    if (-not [Environment]::Is64BitOperatingSystem -or [IntPtr]::Size -ne 8) {
        throw 'Run this tool from 64-bit Windows PowerShell. No process was started.'
    }
}

function Invoke-CheckOnly {
    Assert-64BitWindows
    $paths = Get-InstallPaths
    $desktopName = [HiddenDesktopNative]::GetCurrentDesktopName()
    Write-Status "CheckOnly validated the configured installation paths; no process was launched."
    Write-Status "Launcher=$($paths.Launcher)"
    Write-Status "Games=$($paths.Games)"
    Write-Status "Game=$($paths.Game)"
    Write-Status "CurrentDesktop=$desktopName; SessionId=$script:SessionId"
    $active = @(Get-SessionNamedProcesses)
    if ($active.Count -eq 0) { Write-Status 'No Launcher.exe, Games.exe, or Endfield.exe process is currently listed in this session.' }
    else {
        Write-Status 'Processes that would block an actual run:'
        foreach ($row in $active) {
            $pathText = if ($row.ExecutablePath) { $row.ExecutablePath } else { '<path unavailable>' }
            Write-Status ("  {0} PID={1} PPID={2} Path={3}" -f $row.Name, $row.ProcessId, $row.ParentProcessId, $pathText)
        }
    }
    $record = Get-RecordedState
    if ($record) { Write-Status "Latest saved run state: $($record.RunId), status=$($record.Status); CheckOnly does not change it." }
    return 0
}

function Invoke-StopLastRun {
    Assert-64BitWindows
    if (-not (Test-IsAdministrator)) { throw 'StopLastRun requires an elevated 64-bit PowerShell session. Run the .cmd file to request elevation.' }
    $paths = Get-InstallPaths
    $state = Get-RecordedState
    if (-not $state) { throw 'There is no saved run state to clean up.' }
    $allowed = @([System.IO.Path]::GetFullPath($paths.Launcher), [System.IO.Path]::GetFullPath($paths.Games))
    $identities = @()
    if ($state.PSObject.Properties.Name -contains 'GamesCandidates') { $identities += @($state.GamesCandidates) }
    $identities += @($state.Games, $state.Launcher)
    $seen = @{}
    $cleanupFailed = $false
    foreach ($identity in $identities) {
        if (-not $identity -or -not $identity.ProcessId) { continue }
        $key = '{0}:{1}' -f [uint32]$identity.ProcessId, [long]$identity.CreationFileTimeUtc
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $path = [System.IO.Path]::GetFullPath([string]$identity.ImagePath)
        if (-not ($allowed | Where-Object { [string]::Equals($_, $path, [StringComparison]::OrdinalIgnoreCase) })) {
            Write-Status "Cleanup skipped PID=$($identity.ProcessId): recorded image path is outside the exact launcher/Games whitelist."
            $cleanupFailed = $true
            continue
        }
        if ([uint32]$identity.SessionId -ne [uint32]$script:SessionId) {
            Write-Status "Cleanup skipped PID=$($identity.ProcessId): recorded session does not match this PowerShell session."
            $cleanupFailed = $true
            continue
        }
        $rows = @(Get-SessionNamedProcesses | Where-Object { $_.ProcessId -eq [uint32]$identity.ProcessId })
        if ($rows.Count -eq 0) {
            Write-Status "Cleanup complete for PID=$($identity.ProcessId): the recorded process is no longer listed in this session."
            continue
        }
        try {
            $stopped = [HiddenDesktopNative]::StopVerifiedProcess([uint32]$identity.ProcessId, $path,
                [long]$identity.CreationFileTimeUtc, [uint32]$identity.SessionId)
            if ($stopped) {
                Write-Status "Stopped the recorded official process PID=$($identity.ProcessId), image=$path."
            }
            else {
                Write-Status "Cleanup could not confirm PID=$($identity.ProcessId): path, creation time, or session no longer matches the saved identity."
                $cleanupFailed = $true
            }
        }
        catch { Write-Status "Cleanup could not verify/stop PID=$($identity.ProcessId): $($_.Exception.Message)"; $cleanupFailed = $true }
    }
    if ($cleanupFailed) {
        Write-Status 'One or more recorded Launcher.exe/Games.exe identities could not be confirmed exited; Endfield.exe was left untouched.'
        return 1
    }
    Write-Status 'Cleanup confirmed for every recorded Launcher.exe/Games.exe identity; Endfield.exe was left untouched.'
    return 0
}

function New-WindowWaitResult([string]$Status, [IntPtr]$WindowHandle, [long]$ElapsedMilliseconds, [string]$Detail = '', [string]$LastIssue = '') {
    return [pscustomobject]@{
        Status = $Status
        WindowHandle = $WindowHandle
        ElapsedMilliseconds = $ElapsedMilliseconds
        Detail = $Detail
        LastIssue = $LastIssue
    }
}

function Wait-ForStableGameWindow($ProcessReference, [uint32]$ProcessId, $Desktop, [int]$TimeoutMilliseconds,
    [scriptblock]$ScanOverride = $null, [int]$PollIntervalMilliseconds = 100, [int]$StabilityMilliseconds = 2000) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $stableHandle = [IntPtr]::Zero
    $stableSince = 0L
    $lastIssue = ''
    $lastLoggedIssue = ''

    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            if (-not [HiddenDesktopNative]::IsRunning($ProcessReference)) {
                return (New-WindowWaitResult 'Exited' ([IntPtr]::Zero) $watch.ElapsedMilliseconds 'process-handle-exited')
            }
        }
        catch {
            $issue = 'Unknown: ' + $_.Exception.Message
            $lastIssue = $issue
            if ($issue -ne $lastLoggedIssue) {
                Write-RunStatus ("Game process status query is temporarily unavailable; retrying. {0}" -f $issue)
                $lastLoggedIssue = $issue
            }
            $stableHandle = [IntPtr]::Zero
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }

        try {
            if ($ScanOverride) { $scan = & $ScanOverride $ProcessId $Desktop }
            else { $scan = [HiddenDesktopNative]::ReadGameWindowScan($ProcessId, $Desktop) }
        }
        catch {
            $issue = 'Unknown: ' + $_.Exception.Message
            $lastIssue = $issue
            if ($issue -ne $lastLoggedIssue) {
                Write-RunStatus ("Game window query is temporarily unavailable; retrying. {0}" -f $issue)
                $lastLoggedIssue = $issue
            }
            $stableHandle = [IntPtr]::Zero
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }

        $kind = $scan.Kind.ToString()
        if ($kind -eq 'FailureDialog') {
            return (New-WindowWaitResult 'FailureDialog' $scan.Handle $watch.ElapsedMilliseconds $scan.Detail)
        }
        if ($kind -eq 'Unknown') {
            $issue = 'Unknown: ' + [string]$scan.Detail
            $lastIssue = $issue
            if ($issue -ne $lastLoggedIssue) {
                Write-RunStatus ("Game window enumeration is temporarily uncertain; retrying. {0}" -f $issue)
                $lastLoggedIssue = $issue
            }
            $stableHandle = [IntPtr]::Zero
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }
        if ($kind -eq 'Multiple') {
            $issue = 'MultipleMainWindows: ' + [string]$scan.Detail
            $lastIssue = $issue
            if ($issue -ne $lastLoggedIssue) {
                Write-RunStatus ("More than one eligible Endfield window is visible; waiting for the window set to settle. {0}" -f $scan.Detail)
                $lastLoggedIssue = $issue
            }
            $stableHandle = [IntPtr]::Zero
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }

        if ($kind -eq 'MainFound') {
            if ($stableHandle -eq [IntPtr]::Zero) {
                $stableHandle = $scan.Handle
                $stableSince = $watch.ElapsedMilliseconds
                Write-RunStatus ("Found eligible Endfield main window HWND={0}; starting 2-second stability timer." -f $stableHandle.ToInt64())
            }
            elseif ($stableHandle -ne $scan.Handle) {
                $stableHandle = $scan.Handle
                $stableSince = $watch.ElapsedMilliseconds
                Write-RunStatus ("Endfield main-window HWND changed to {0}; restarting the 2-second stability timer." -f $stableHandle.ToInt64())
            }
            elseif (($watch.ElapsedMilliseconds - $stableSince) -ge $StabilityMilliseconds) {
                return (New-WindowWaitResult 'Stable' $stableHandle $watch.ElapsedMilliseconds ("same-hwnd-stable-{0}ms" -f $StabilityMilliseconds) $lastIssue)
            }
        }
        elseif ($stableHandle -ne [IntPtr]::Zero) {
            $stableHandle = [IntPtr]::Zero
            $stableSince = 0L
            Write-RunStatus 'Eligible Endfield main window disappeared; restarting the stability timer.'
        }
        if ($kind -eq 'None') { $lastLoggedIssue = '' }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    try {
        if (-not [HiddenDesktopNative]::IsRunning($ProcessReference)) {
            return (New-WindowWaitResult 'Exited' ([IntPtr]::Zero) $watch.ElapsedMilliseconds 'process-handle-exited-at-timeout')
        }
    }
    catch {
        $lastIssue = 'Unknown: ' + $_.Exception.Message
        if ($lastIssue -ne $lastLoggedIssue) {
            Write-RunStatus ("Game process query remained uncertain at the timeout: {0}" -f $lastIssue)
        }
        return (New-WindowWaitResult 'TimedOut' ([IntPtr]::Zero) $watch.ElapsedMilliseconds ('Window query budget expired. Last unresolved query state: ' + $lastIssue) $lastIssue)
    }
    $timeoutDetail = 'No unique Endfield main window stayed valid for the required stability interval before the timeout.'
    if ($lastIssue) { $timeoutDetail += ' Last unresolved query state: ' + $lastIssue }
    return (New-WindowWaitResult 'TimedOut' ([IntPtr]::Zero) $watch.ElapsedMilliseconds $timeoutDetail $lastIssue)
}

function Stop-ThisRunProcess($ProcessReference, $Identity, [string]$ExpectedPath, [string]$Label) {
    if (-not $ProcessReference -or -not $Identity -or -not $Identity.ProcessId) {
        Write-RunStatus ("Could not clean {0}: this run has no captured process identity." -f $Label)
        return $false
    }

    try {
        if (-not [HiddenDesktopNative]::IsRunning($ProcessReference)) {
            Write-RunStatus ("{0} already exited; no further action is needed." -f $Label)
            return $true
        }

        $current = [HiddenDesktopNative]::ReadProcess($ProcessReference)
        $expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedPath)
        $identityFullPath = [System.IO.Path]::GetFullPath([string]$Identity.ImagePath)
        $currentFullPath = [System.IO.Path]::GetFullPath([string]$current.ImagePath)
        if ($current.ProcessId -ne [uint32]$Identity.ProcessId -or
            $current.CreationFileTimeUtc -ne [long]$Identity.CreationFileTimeUtc -or
            $current.SessionId -ne [uint32]$Identity.SessionId -or
            $current.SessionId -ne [uint32]$script:SessionId -or
            -not [string]::Equals($identityFullPath, $expectedFullPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($currentFullPath, $expectedFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            Write-RunStatus ("Skipped {0}: live process identity does not match this run's exact path, creation time, and session." -f $Label)
            return $false
        }

        $stopped = [HiddenDesktopNative]::StopVerifiedProcess([uint32]$Identity.ProcessId,
            $expectedFullPath, [long]$Identity.CreationFileTimeUtc, [uint32]$Identity.SessionId)
        if (-not [HiddenDesktopNative]::IsRunning($ProcessReference)) {
            Write-RunStatus ("Stopped {0} PID={1}." -f $Label, $Identity.ProcessId)
            return $true
        }
        if (-not $stopped) {
            Write-RunStatus ("Could not stop {0} PID={1}: the native identity check rejected the process." -f $Label, $Identity.ProcessId)
        }
        else {
            Write-RunStatus ("Could not confirm that {0} PID={1} exited after the stop request." -f $Label, $Identity.ProcessId)
        }
        return $false
    }
    catch {
        try {
            if (-not [HiddenDesktopNative]::IsRunning($ProcessReference)) {
                Write-RunStatus ("{0} exited during cleanup." -f $Label)
                return $true
            }
        }
        catch { }
        Write-RunStatus ("Cleanup failed for {0} PID={1}: {2}" -f $Label, $Identity.ProcessId, $_.Exception.Message)
        return $false
    }
}

function Stop-RecordedRunProcess($Identity, [string]$ExpectedPath, [string]$Label) {
    if (-not $Identity -or -not $Identity.ProcessId) {
        Write-RunStatus ("No {0} process identity was recorded for this run." -f $Label)
        return $true
    }

    $expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedPath)
    $identityFullPath = [System.IO.Path]::GetFullPath([string]$Identity.ImagePath)
    if (-not [string]::Equals($identityFullPath, $expectedFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        [uint32]$Identity.SessionId -ne [uint32]$script:SessionId) {
        Write-RunStatus ("Could not clean {0} PID={1}: saved identity is outside this run's exact path/session scope." -f $Label, $Identity.ProcessId)
        return $false
    }

    $reference = $null
    try {
        $reference = [HiddenDesktopNative]::OpenProcessRef([uint32]$Identity.ProcessId, [uint32]($script:ProcessQueryAccess -bor 0x00100000))
        $current = [HiddenDesktopNative]::ReadProcess($reference)
        if ($current.CreationFileTimeUtc -ne [long]$Identity.CreationFileTimeUtc -or
            $current.SessionId -ne [uint32]$Identity.SessionId -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$current.ImagePath), $expectedFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            Write-RunStatus ("Saved {0} PID={1} identity has already exited or been replaced; the current process was left untouched." -f $Label, $Identity.ProcessId)
            return $true
        }
        return (Stop-ThisRunProcess $reference $Identity $expectedFullPath $Label)
    }
    catch {
        $queryFailed = $false
        try {
            $row = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f [uint32]$Identity.ProcessId) -ErrorAction Stop
        }
        catch { $queryFailed = $true; $row = $null }
        if (-not $queryFailed -and -not $row) {
            Write-RunStatus ("{0} PID={1} is no longer present; cleanup is complete for this identity." -f $Label, $Identity.ProcessId)
            return $true
        }
        Write-RunStatus ("Could not reopen and verify {0} PID={1}; refusing an unverified stop. {2}" -f $Label, $Identity.ProcessId, $_.Exception.Message)
        return $false
    }
    finally {
        if ($reference) { $reference.Dispose() }
    }
}

function Write-CleanupNote([string]$Message) {
    try { Write-RunStatus $Message }
    catch {
        try { $script:RunState.CleanupErrors += ('Cleanup status output failed: ' + $_.Exception.Message) } catch { }
    }
}

function Save-CleanupState {
    try { Save-RunState }
    catch {
        try { $script:RunState.CleanupErrors += ('Cleanup state write failed: ' + $_.Exception.Message) } catch { }
    }
}

function Invoke-ThisRunProcessCleanup($Paths) {
    if ($script:RunState.CleanupAttempted) { return [bool]$script:RunState.CleanupComplete }
    $script:RunState.CleanupAttempted = $true
    $script:RunState.CleanupResults = @()
    $script:RunState.CleanupErrors = @()
    Save-CleanupState
    Write-CleanupNote "Cleaning up only this run's verified Launcher.exe and Games.exe identities; Endfield.exe is left running."

    $launcherIdentity = $script:RunState.Launcher
    $launcherOk = $false
    try {
        if ($launcherIdentity) {
            if ($script:LauncherReference) {
                $launcherOk = Stop-ThisRunProcess $script:LauncherReference $launcherIdentity $Paths.Launcher 'Launcher.exe'
            }
            else {
                $launcherOk = Stop-RecordedRunProcess $launcherIdentity $Paths.Launcher 'Launcher.exe'
            }
        }
        elseif ($script:RunState.LauncherLaunchAttempted) {
            $script:RunState.CleanupErrors += 'Launcher was started or launch was attempted but its identity could not be captured; no process was stopped without verification.'
            Write-CleanupNote $script:RunState.CleanupErrors[-1]
        }
        else { $launcherOk = $true }
    }
    catch {
        $script:RunState.CleanupErrors += ('Launcher cleanup error: ' + $_.Exception.Message)
        Write-CleanupNote $script:RunState.CleanupErrors[-1]
    }
    $script:RunState.LauncherCleanupConfirmed = [bool]$launcherOk
    $script:RunState.CleanupResults += [pscustomobject]@{ Name = 'Launcher.exe'; ConfirmedExited = [bool]$launcherOk }
    Save-CleanupState

    $gameIdentities = @()
    if ($script:RunState.GamesCandidates) { $gameIdentities += @($script:RunState.GamesCandidates) }
    if ($script:RunState.Games) { $gameIdentities += @($script:RunState.Games) }
    $seen = @{}
    $gamesOk = $true
    foreach ($identity in $gameIdentities) {
        if (-not $identity -or -not $identity.ProcessId) { continue }
        $key = '{0}:{1}' -f [uint32]$identity.ProcessId, [long]$identity.CreationFileTimeUtc
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        try {
            $reference = $null
            if ($script:GamesReference -and [uint32]$identity.ProcessId -eq [uint32]$script:RunState.Games.ProcessId -and
                [long]$identity.CreationFileTimeUtc -eq [long]$script:RunState.Games.CreationFileTimeUtc) {
                $reference = $script:GamesReference
                $stopped = Stop-ThisRunProcess $reference $identity $Paths.Games ('Games.exe PID=' + $identity.ProcessId)
            }
            else { $stopped = Stop-RecordedRunProcess $identity $Paths.Games ('Games.exe PID=' + $identity.ProcessId) }
            $script:RunState.CleanupResults += [pscustomobject]@{ Name = 'Games.exe'; ProcessId = [uint32]$identity.ProcessId; ConfirmedExited = [bool]$stopped }
            if (-not $stopped) { $gamesOk = $false }
        }
        catch {
            $gamesOk = $false
            $script:RunState.CleanupErrors += ('Games.exe PID=' + $identity.ProcessId + ' cleanup error: ' + $_.Exception.Message)
            Write-CleanupNote $script:RunState.CleanupErrors[-1]
        }
        Save-CleanupState
    }

    $script:RunState.GamesCleanupConfirmed = [bool]$gamesOk
    $script:RunState.CleanupComplete = [bool]($launcherOk -and $gamesOk)
    Save-CleanupState
    if (-not $script:RunState.CleanupComplete) {
        Write-CleanupNote 'Cleanup did not confirm every recorded launcher process exited; the run will finish with a failure status.'
    }
    return [bool]$script:RunState.CleanupComplete
}

function Complete-GameLaunch($Paths, $GameReference, $GameInfo, $GameWindowHandle) {
    try {
        if (-not [HiddenDesktopNative]::IsRunning($GameReference)) {
            $script:RunState.Status = 'GameExitedBeforeCleanup'
            Save-RunState
            throw 'Endfield exited before cleanup validation.'
        }
        $currentGame = [HiddenDesktopNative]::ReadProcess($GameReference)
        if ($currentGame.ProcessId -ne [uint32]$GameInfo.ProcessId -or
            $currentGame.CreationFileTimeUtc -ne [long]$GameInfo.CreationFileTimeUtc -or
            $currentGame.SessionId -ne [uint32]$script:SessionId -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($currentGame.ImagePath), [System.IO.Path]::GetFullPath($Paths.Game), [StringComparison]::OrdinalIgnoreCase) -or
            $currentGame.ParentProcessId -ne [uint32]$script:RunState.ExpectedParentProcessId) {
            $script:RunState.Status = 'GameIdentityChangedBeforeCleanup'
            Save-RunState
        throw 'Endfield identity or parent PID changed before cleanup validation.'
        }
        $finalScan = [HiddenDesktopNative]::ReadGameWindowScan([uint32]$currentGame.ProcessId, $script:VisibleDesktopReference)
        if ($finalScan.Kind.ToString() -ne 'MainFound' -or $finalScan.Handle -ne $GameWindowHandle) {
            $script:RunState.Status = 'GameWindowChangedBeforeCleanup'
            Save-RunState
            throw 'The same unique Endfield main window was not present during cleanup validation.'
        }
    }
    catch {
        if ($script:RunState.Status -notin @('GameExitedBeforeCleanup', 'GameIdentityChangedBeforeCleanup', 'GameWindowChangedBeforeCleanup')) {
            $script:RunState.Status = 'GameCleanupPrecheckFailed'
        }
        Save-RunState
        throw
    }

    $script:RunState.Status = 'CleaningLauncherProcesses'
    $script:RunState.GameWindowHandle = $GameWindowHandle.ToInt64()
    Save-RunState
    Write-RunStatus "Endfield main window stayed valid on the same HWND for 2 seconds; cleaning up this run's official launcher processes."
    $cleanupComplete = Invoke-ThisRunProcessCleanup $Paths

    $gameStillRunning = $false
    try { $gameStillRunning = [HiddenDesktopNative]::IsRunning($GameReference) }
    catch { $script:RunState.GameStateAfterCleanupError = $_.Exception.Message }
    if (-not $gameStillRunning) {
        $script:RunState.Status = 'GameExitedDuringCleanup'
        Save-RunState
        throw 'Endfield exited during launcher cleanup; the run is not marked complete.'
    }

    $launcherStillRunning = $true
    $gamesStillRunning = $true
    try { $launcherStillRunning = [HiddenDesktopNative]::IsRunning($script:LauncherReference) }
    catch { $script:RunState.LauncherStateAfterCleanupError = $_.Exception.Message }
    try { $gamesStillRunning = [HiddenDesktopNative]::IsRunning($script:GamesReference) }
    catch { $script:RunState.GamesStateAfterCleanupError = $_.Exception.Message }

    if (-not $cleanupComplete -or $launcherStillRunning -or $gamesStillRunning) {
        $script:RunState.Status = 'LauncherCleanupFailed'
        Save-RunState
        throw "Endfield is running, but this run's Launcher.exe and Games.exe could not both be confirmed exited."
    }

    $script:RunState.Status = 'Completed'
    $script:RunState.CompletedAt = (Get-Date).ToString('o')
    Save-RunState
    Write-RunStatus "Endfield remains running and both this run's Launcher.exe and Games.exe are confirmed exited."
    return 0
}

function Compile-MockWindow([string]$Directory) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "SelfTest needs the .NET Framework 64-bit C# compiler: $compiler" }
    $sourcePath = Join-Path $Directory 'MockVisibleWindow.cs'
    $outputPath = Join-Path $Directory 'MockVisibleWindow.exe'
    $mockSource = @'
using System;
using System.Windows.Forms;
internal static class MockVisibleWindow
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        string[] args = Environment.GetCommandLineArgs();
        string title = args.Length > 1 ? args[1] : "Endfield";
        int exitAfterMs = 0;
        int showDelayMs = 0;
        if (args.Length > 2) Int32.TryParse(args[2], out exitAfterMs);
        if (args.Length > 3) Int32.TryParse(args[3], out showDelayMs);
        bool twoWindows = args.Length > 4 && args[4] == "two";
        Form main = new Form { Text = title, Width = 420, Height = 240 };
        main.FormClosed += delegate { Application.ExitThread(); };
        Timer showTimer = null;
        Action showMain = delegate
        {
            main.Show();
            if (twoWindows) new Form { Text = "Endfield", Width = 420, Height = 240 }.Show();
        };
        if (showDelayMs > 0)
        {
            showTimer = new Timer { Interval = showDelayMs };
            showTimer.Tick += delegate { showTimer.Stop(); showTimer.Dispose(); showMain(); };
            showTimer.Start();
        }
        else showMain();
        if (exitAfterMs > 0)
        {
            Timer timer = new Timer { Interval = exitAfterMs };
            timer.Tick += delegate { timer.Stop(); main.Close(); };
            if (showDelayMs > 0)
                main.Shown += delegate { timer.Start(); };
            else timer.Start();
        }
        Application.Run();
    }
}
'@
    [System.IO.File]::WriteAllText($sourcePath, $mockSource, [System.Text.UTF8Encoding]::new($false))
    $arguments = '/nologo /target:winexe /out:"' + $outputPath + '" /r:"' + (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll') + '" /r:"' + (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll') + '" "' + $sourcePath + '"'
    $compilerProcess = Start-Process -FilePath $compiler -ArgumentList $arguments -WorkingDirectory $Directory -Wait -PassThru -NoNewWindow
    if ($compilerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "SelfTest mock compilation failed with exit code $($compilerProcess.ExitCode)." }
    return $outputPath
}

function Invoke-SelfTest {
    Assert-64BitWindows
    if (-not [HiddenDesktopNative]::RunGameWindowPolicySelfTests()) {
        throw 'SelfTest failed: game-window policy classification did not pass.'
    }
    $visibleDesktopName = [HiddenDesktopNative]::GetCurrentDesktopName()
    if (-not [string]::Equals($visibleDesktopName, 'Default', [StringComparison]::OrdinalIgnoreCase)) {
        throw "SelfTest requires the caller's current desktop to be WinSta0\Default; current desktop is '$visibleDesktopName'."
    }
    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('HiddenDesktopTest-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDirectory)
    $hiddenName = 'HDTest-' + [Guid]::NewGuid().ToString('N').Substring(0, 16)
    $hiddenDesktop = $null
    $visibleDesktop = $null
    $mockParent = $null
    $mockChild = $null
    $failureCleanupLauncher = $null
    $failureCleanupGamesOne = $null
    $failureCleanupGamesTwo = $null
    $timeoutProcess = $null
    $earlyExitProcess = $null
    $failureDialogProcess = $null
    $delayedWindowProcess = $null
    $multipleWindowProcess = $null
    $parentInfo = $null
    $childInfo = $null
    $failureCleanupLauncherInfo = $null
    $failureCleanupGamesOneInfo = $null
    $failureCleanupGamesTwoInfo = $null
    $timeoutInfo = $null
    $earlyExitInfo = $null
    $failureDialogInfo = $null
    $delayedWindowInfo = $null
    $multipleWindowInfo = $null
    try {
        $mockImage = Compile-MockWindow $tempDirectory
        $hiddenDesktop = [HiddenDesktopNative]::CreateHiddenDesktop($hiddenName)
        $visibleDesktop = [HiddenDesktopNative]::OpenDesktop($visibleDesktopName)
        $mockParent = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'HiddenParent', $tempDirectory, [HiddenDesktopNative]::DesktopPath($hiddenName), $null, $false)
        $parentInfo = [HiddenDesktopNative]::ReadProcess($mockParent)
        $hiddenEvidence = $null
        $hiddenQueryError = $null
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $hiddenEvidence = [HiddenDesktopNative]::ReadDesktopEvidence($parentInfo.ProcessId, $hiddenDesktop)
                $hiddenQueryError = $null
                if ($hiddenEvidence.VisibleWindowsOnRequestedDesktop -gt 0) { break }
            }
            catch {
                $hiddenQueryException = $_.Exception
                if ($hiddenQueryException.InnerException) { $hiddenQueryException = $hiddenQueryException.InnerException }
                $hiddenQueryError = $hiddenQueryException.Message
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $hiddenEvidence -or $hiddenEvidence.VisibleWindowsOnRequestedDesktop -lt 1 -or $hiddenEvidence.WindowThreadIds.Count -lt 1) { throw "SelfTest failed: mock GUI parent window was not enumerated on hidden desktop '$hiddenName'; window query error='$hiddenQueryError'." }
        Write-Status ("SelfTest hidden GUI parent: PID={0}, image={1}, hiddenDesktop={2}, windowThreadIds={3}, PASS" -f $parentInfo.ProcessId, $parentInfo.ImagePath, $hiddenName, ($hiddenEvidence.WindowThreadIds -join ','))

        $mockChild = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'Endfield', $tempDirectory, [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $mockParent, $false)
        $childInfo = [HiddenDesktopNative]::ReadProcess($mockChild)
        $childEvidence = $null
        $childQueryError = $null
        for ($i = 0; $i -lt 50; $i++) {
            try {
                $childEvidence = [HiddenDesktopNative]::ReadDesktopEvidence($childInfo.ProcessId, $visibleDesktop)
                $childQueryError = $null
                if ($childEvidence.VisibleWindowsOnRequestedDesktop -gt 0) { break }
            }
            catch {
                $childQueryException = $_.Exception
                if ($childQueryException.InnerException) { $childQueryException = $childQueryException.InnerException }
                $childQueryError = $childQueryException.Message
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $childEvidence) { throw "SelfTest failed: mock GUI child window enumeration never succeeded; window query error='$childQueryError'." }
        $parentMatches = $childInfo.ParentProcessId -eq $parentInfo.ProcessId
        $visibleMatches = $childEvidence.WindowThreadIds.Count -gt 0 -and $childEvidence.VisibleWindowsOnRequestedDesktop -gt 0
        Write-Status ("SelfTest child: PID={0}, observedPPID={1}, expectedPPID={2}, explicitDesktop={3}, windowThreadIds={4}, windowsOnDefault={5}, visibleWindowsOnDefault={6}" -f $childInfo.ProcessId, $childInfo.ParentProcessId, $parentInfo.ProcessId, $visibleDesktopName, ($childEvidence.WindowThreadIds -join ','), $childEvidence.WindowsOnRequestedDesktop, $childEvidence.VisibleWindowsOnRequestedDesktop)
        if (-not $parentMatches) { throw 'SelfTest failed: the native parent-process attribute did not produce the expected PPID.' }
        if (-not $visibleMatches) { throw 'SelfTest failed: the mock child did not create a window on the visible Default desktop.' }
        Write-Status 'SelfTest PASS: hidden mock parent, explicit PPID, and visible Default-desktop child were observed.'

        $script:RunStatePath = $null
        $script:VisibleDesktopReference = $visibleDesktop
        $script:LauncherReference = $mockParent
        $script:GamesReference = $mockParent
        $wrongIdentity = ConvertTo-Identity $childInfo
        $wrongIdentity.CreationFileTimeUtc = [long]$childInfo.CreationFileTimeUtc + 1
        $wrongIdentityStopped = Stop-ThisRunProcess $mockChild $wrongIdentity $mockImage 'mock Endfield.exe'
        if ($wrongIdentityStopped -or -not [HiddenDesktopNative]::IsRunning($mockChild)) {
            throw "SelfTest failed: Stop-ThisRunProcess did not reject the child's wrong creation-time identity."
        }
        Write-Status 'SelfTest PASS: wrong creation-time identity was rejected and the mock game stayed alive.'

        $scanTestState = [pscustomobject]@{ Count = 0 }
        $scanWithTransientUnknown = {
            param($scanPid, $scanDesktop)
            $scanTestState.Count++
            if ($scanTestState.Count -le 2) {
                return [pscustomobject]@{ Kind = 'Unknown'; Detail = 'selftest transient enumeration failure'; Handle = [IntPtr]::Zero }
            }
            return [HiddenDesktopNative]::ReadGameWindowScan([uint32]$scanPid, $scanDesktop)
        }.GetNewClosure()
        $stableResult = Wait-ForStableGameWindow $mockChild $childInfo.ProcessId $visibleDesktop 5000 $scanWithTransientUnknown
        if ($stableResult.Status -ne 'Stable' -or $stableResult.WindowHandle -eq [IntPtr]::Zero) {
            throw "SelfTest failed: valid Endfield window did not become stable; status=$($stableResult.Status), detail=$($stableResult.Detail)."
        }
        if ($scanTestState.Count -lt 3 -or $stableResult.LastIssue -notlike 'Unknown:*') {
            throw 'SelfTest failed: a transient Unknown window query did not recover within the wait budget.'
        }
        Write-Status ("SelfTest PASS: same Endfield HWND stayed valid for 2 seconds (HWND={0}, elapsedMs={1})." -f $stableResult.WindowHandle.ToInt64(), $stableResult.ElapsedMilliseconds)

        $script:RunState = [ordered]@{
            Status = 'WaitingForGameWindow'
            Launcher = ConvertTo-Identity $parentInfo
            Games = ConvertTo-Identity $parentInfo
            GamesCandidates = @()
            Game = ConvertTo-Identity $childInfo
            ExpectedParentProcessId = [uint32]$parentInfo.ProcessId
            LauncherLaunchAttempted = $true
            CleanupAttempted = $false
            CleanupComplete = $false
            CleanupResults = @()
            CleanupErrors = @()
        }
        $mockPaths = [pscustomobject]@{ Launcher = $mockImage; Games = $mockImage; Game = $mockImage }
        $completionCode = Complete-GameLaunch $mockPaths $mockChild $childInfo $stableResult.WindowHandle
        if ($completionCode -ne 0 -or $script:RunState.Status -ne 'Completed' -or
            -not $script:RunState.LauncherCleanupConfirmed -or -not $script:RunState.GamesCleanupConfirmed) {
            throw 'SelfTest failed: verified launcher cleanup did not reach the completed state.'
        }
        if ([HiddenDesktopNative]::IsRunning($mockParent)) {
            throw 'SelfTest failed: the verified mock launcher parent process did not exit.'
        }
        if (-not [HiddenDesktopNative]::IsRunning($mockChild)) {
            throw 'SelfTest failed: ending the mock parent also ended the child process.'
        }
        Write-Status 'SelfTest PASS: verified launcher cleanup exited the parent, treated the already-exited second identity as complete, and kept the game child alive.'

        $failureCleanupLauncher = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'CleanupLauncher', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($hiddenName), $null, $false)
        $failureCleanupGamesOne = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'CleanupGamesOne', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($hiddenName), $null, $false)
        $failureCleanupGamesTwo = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'CleanupGamesTwo', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($hiddenName), $null, $false)
        $failureCleanupLauncherInfo = [HiddenDesktopNative]::ReadProcess($failureCleanupLauncher)
        $failureCleanupGamesOneInfo = [HiddenDesktopNative]::ReadProcess($failureCleanupGamesOne)
        $failureCleanupGamesTwoInfo = [HiddenDesktopNative]::ReadProcess($failureCleanupGamesTwo)
        $script:LauncherReference = $failureCleanupLauncher
        $script:GamesReference = $failureCleanupGamesTwo
        $script:RunState = [ordered]@{
            Status = 'GameWindowTimeout'
            Launcher = ConvertTo-Identity $failureCleanupLauncherInfo
            Games = ConvertTo-Identity $failureCleanupGamesTwoInfo
            GamesCandidates = @((ConvertTo-Identity $failureCleanupGamesOneInfo), (ConvertTo-Identity $failureCleanupGamesTwoInfo))
            Game = ConvertTo-Identity $childInfo
            LauncherLaunchAttempted = $true
            CleanupAttempted = $false
            CleanupComplete = $false
            CleanupResults = @()
            CleanupErrors = @()
        }
        $failureCleanupComplete = Invoke-ThisRunProcessCleanup $mockPaths
        if (-not $failureCleanupComplete -or $script:RunState.Status -ne 'GameWindowTimeout' -or
            [HiddenDesktopNative]::IsRunning($failureCleanupLauncher) -or
            [HiddenDesktopNative]::IsRunning($failureCleanupGamesOne) -or
            [HiddenDesktopNative]::IsRunning($failureCleanupGamesTwo) -or
            -not [HiddenDesktopNative]::IsRunning($mockChild)) {
            throw 'SelfTest failed: failure cleanup did not stop every recorded launcher process while preserving the game.'
        }
        Write-Status 'SelfTest PASS: timeout cleanup stopped the launcher and every recorded Games candidate while preserving Endfield.'

        $timeoutProcess = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'WaitingWindow', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $null, $false)
        $timeoutInfo = [HiddenDesktopNative]::ReadProcess($timeoutProcess)
        $timeoutResult = Wait-ForStableGameWindow $timeoutProcess $timeoutInfo.ProcessId $visibleDesktop 500
        if ($timeoutResult.Status -ne 'TimedOut' -or -not [HiddenDesktopNative]::IsRunning($timeoutProcess)) {
            throw "SelfTest failed: missing Endfield window did not stay live until timeout; status=$($timeoutResult.Status)."
        }
        Write-Status ("SelfTest PASS: missing main window timed out after {0}ms while preserving the process." -f $timeoutResult.ElapsedMilliseconds)

        $earlyExitProcess = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'Endfield 1200', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $null, $false)
        $earlyExitInfo = [HiddenDesktopNative]::ReadProcess($earlyExitProcess)
        $earlyExitResult = Wait-ForStableGameWindow $earlyExitProcess $earlyExitInfo.ProcessId $visibleDesktop 5000
        if ($earlyExitResult.Status -ne 'Exited') {
            throw "SelfTest failed: process exit before a stable window was not detected; status=$($earlyExitResult.Status)."
        }
        Write-Status ("SelfTest PASS: early game exit was detected at {0}ms." -f $earlyExitResult.ElapsedMilliseconds)

        $failureDialogProcess = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, '游戏启动失败', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $null, $false)
        $failureDialogInfo = [HiddenDesktopNative]::ReadProcess($failureDialogProcess)
        $failureDialogResult = Wait-ForStableGameWindow $failureDialogProcess $failureDialogInfo.ProcessId $visibleDesktop 5000
        if ($failureDialogResult.Status -ne 'FailureDialog') {
            throw "SelfTest failed: visible game-failure dialog was not detected; status=$($failureDialogResult.Status)."
        }
        Write-Status 'SelfTest PASS: visible game-failure dialog is classified as an immediate startup failure.'

        $delayedWindowProcess = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'Endfield 0 1200', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $null, $false)
        $delayedWindowInfo = [HiddenDesktopNative]::ReadProcess($delayedWindowProcess)
        $delayedWindowResult = Wait-ForStableGameWindow $delayedWindowProcess $delayedWindowInfo.ProcessId $visibleDesktop 6000
        if ($delayedWindowResult.Status -ne 'Stable' -or $delayedWindowResult.ElapsedMilliseconds -lt 3000) {
            throw "SelfTest failed: delayed main window did not appear and stabilize within the wait budget; status=$($delayedWindowResult.Status), elapsedMs=$($delayedWindowResult.ElapsedMilliseconds)."
        }
        Write-Status ("SelfTest PASS: delayed main window appeared after startup and stabilized at {0}ms." -f $delayedWindowResult.ElapsedMilliseconds)

        $multipleWindowProcess = [HiddenDesktopNative]::StartProcessOnDesktop($mockImage, 'Endfield 0 0 two', $tempDirectory,
            [HiddenDesktopNative]::DesktopPath($visibleDesktopName), $null, $false)
        $multipleWindowInfo = [HiddenDesktopNative]::ReadProcess($multipleWindowProcess)
        $multipleResult = Wait-ForStableGameWindow $multipleWindowProcess $multipleWindowInfo.ProcessId $visibleDesktop 700
        if ($multipleResult.Status -ne 'TimedOut' -or $multipleResult.LastIssue -notlike 'MultipleMainWindows:*') {
            throw "SelfTest failed: multiple Endfield main windows were not rejected; status=$($multipleResult.Status)."
        }
        Write-Status 'SelfTest PASS: multiple candidate windows are retried until timeout rather than causing immediate cleanup.'
        return 0
    }
    finally {
        if ($visibleDesktop) {
            foreach ($item in @(
                @{ Reference = $mockChild; Identity = $childInfo },
                @{ Reference = $timeoutProcess; Identity = $timeoutInfo },
                @{ Reference = $earlyExitProcess; Identity = $earlyExitInfo },
                @{ Reference = $failureDialogProcess; Identity = $failureDialogInfo },
                @{ Reference = $delayedWindowProcess; Identity = $delayedWindowInfo },
                @{ Reference = $multipleWindowProcess; Identity = $multipleWindowInfo }
            )) {
                if ($item.Reference) {
                    try {
                        if ([HiddenDesktopNative]::IsRunning($item.Reference)) {
                            [void][HiddenDesktopNative]::CloseWindowsOnDesktop([uint32]$item.Identity.ProcessId, $visibleDesktop)
                            Start-Sleep -Milliseconds 100
                            if ([HiddenDesktopNative]::IsRunning($item.Reference)) {
                                [void][HiddenDesktopNative]::StopVerifiedProcess([uint32]$item.Identity.ProcessId,
                                    [string]$item.Identity.ImagePath, [long]$item.Identity.CreationFileTimeUtc,
                                    [uint32]$item.Identity.SessionId)
                            }
                        }
                    }
                    catch { Write-Status "SelfTest mock process cleanup note: $($_.Exception.Message)" }
                    $item.Reference.Dispose()
                }
            }
        }
        if ($mockParent) {
            try {
                if ([HiddenDesktopNative]::IsRunning($mockParent) -and $parentInfo) {
                    [void][HiddenDesktopNative]::StopVerifiedProcess([uint32]$parentInfo.ProcessId,
                        [string]$parentInfo.ImagePath, [long]$parentInfo.CreationFileTimeUtc,
                        [uint32]$parentInfo.SessionId)
                }
            } catch { Write-Status "SelfTest mock parent cleanup note: $($_.Exception.Message)" }
            $mockParent.Dispose()
        }
        foreach ($item in @(
            @{ Reference = $failureCleanupLauncher; Identity = $failureCleanupLauncherInfo },
            @{ Reference = $failureCleanupGamesOne; Identity = $failureCleanupGamesOneInfo },
            @{ Reference = $failureCleanupGamesTwo; Identity = $failureCleanupGamesTwoInfo }
        )) {
            if ($item.Reference) {
                try {
                    if ([HiddenDesktopNative]::IsRunning($item.Reference) -and $item.Identity) {
                        [void][HiddenDesktopNative]::StopVerifiedProcess([uint32]$item.Identity.ProcessId,
                            [string]$item.Identity.ImagePath, [long]$item.Identity.CreationFileTimeUtc,
                            [uint32]$item.Identity.SessionId)
                    }
                } catch { Write-Status "SelfTest launcher mock cleanup note: $($_.Exception.Message)" }
                $item.Reference.Dispose()
            }
        }
        if ($visibleDesktop) { $visibleDesktop.Dispose() }
        if ($hiddenDesktop) { $hiddenDesktop.Dispose() }
        try {
            $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            $tempFull = [System.IO.Path]::GetFullPath($tempDirectory)
            $leaf = [System.IO.Path]::GetFileName($tempFull)
            if (-not $tempFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
                -not $leaf.StartsWith('HiddenDesktopTest-', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Resolved self-test cleanup target failed its temp-directory check: $tempFull"
            }
            Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction Stop
        }
        catch { Write-Status "SelfTest temporary files remain at: $tempDirectory ($($_.Exception.Message))" }
    }
}

function Wait-ForOfficialGames($Paths, [System.Collections.Generic.HashSet[uint32]]$BaselinePids, [DateTime]$LaunchUtc, [string]$HiddenDesktopName, $HiddenDesktopHandle, $VisibleDesktopHandle, $State) {
    $references = @{}
    $State.GamesCandidates = @()
    $lastDesktopEvidenceError = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='Games.exe'" -ErrorAction Stop |
                Where-Object { [int]$_.SessionId -eq $script:SessionId })
            foreach ($row in $rows) {
                $candidateId = [uint32]$row.ProcessId
                if ($BaselinePids.Contains($candidateId) -or $references.ContainsKey([string]$candidateId)) { continue }
                $reference = $null
                try {
                    $reference = [HiddenDesktopNative]::OpenProcessRef($candidateId, $script:ProcessParentAccess)
                    $snapshot = [HiddenDesktopNative]::ReadProcess($reference)
                    if ($snapshot.SessionId -ne [uint32]$script:SessionId) { $reference.Dispose(); continue }
                    if (-not [string]::Equals([System.IO.Path]::GetFullPath($snapshot.ImagePath), [System.IO.Path]::GetFullPath($Paths.Games), [StringComparison]::OrdinalIgnoreCase)) {
                        $reference.Dispose()
                        continue
                    }
                    $createdUtc = [DateTime]::FromFileTimeUtc([long]$snapshot.CreationFileTimeUtc)
                    if ($createdUtc -lt $LaunchUtc.AddSeconds(-2)) { $reference.Dispose(); continue }
                    $references[[string]$candidateId] = [pscustomobject]@{ Reference = $reference; Snapshot = $snapshot }
                    $State.Games = ConvertTo-Identity $snapshot
                    $State.GamesCandidates = @($State.GamesCandidates) + @($State.Games)
                    $State.Status = 'OfficialGamesFound'
                    Save-RunState
                    Write-RunStatus ("Discovered exact official Games.exe PID={0}; path and creation time were verified from an open process handle." -f $snapshot.ProcessId)
                }
                catch {
                    if ($reference) { $reference.Dispose() }
                    throw "Could not verify a new same-session Games.exe PID=$candidateId; refusing to guess. $($_.Exception.Message)"
                }
            }
            if ($references.Count -gt 1) { throw "More than one new official Games.exe PID appeared in this session; refusing to choose among them." }
            if ($references.Count -eq 1) {
                $item = @($references.Values)[0]
                if (-not [HiddenDesktopNative]::IsRunning($item.Reference)) { throw 'The newly discovered official Games.exe exited before it could be selected.' }
                try {
                    $evidence = [HiddenDesktopNative]::ReadDesktopEvidence($item.Snapshot.ProcessId, $HiddenDesktopHandle)
                    $visibleEvidence = [HiddenDesktopNative]::ReadDesktopEvidence($item.Snapshot.ProcessId, $VisibleDesktopHandle)
                    $lastDesktopEvidenceError = $null
                }
                catch {
                    $evidenceException = $_.Exception
                    if ($evidenceException.InnerException) { $evidenceException = $evidenceException.InnerException }
                    $lastDesktopEvidenceError = $evidenceException.Message
                    $State.DesktopEvidenceLastError = $lastDesktopEvidenceError
                    Save-RunState
                    if (-not $State.DesktopEvidenceRetryLogged) {
                        Write-RunStatus ("Window enumeration is not ready for Games.exe yet; retrying until the startup timeout. Error: {0}" -f $lastDesktopEvidenceError)
                        $State.DesktopEvidenceRetryLogged = $true
                        Save-RunState
                    }
                    Start-Sleep -Milliseconds 200
                    continue
                }
                $State.GamesWindowThreadIds = @($evidence.WindowThreadIds)
                $State.GamesWindowsOnHiddenDesktop = [int]$evidence.WindowsOnRequestedDesktop
                $State.GamesWindowsOnDefaultDesktop = [int]$visibleEvidence.WindowsOnRequestedDesktop
                Save-RunState
                if ($visibleEvidence.WindowsOnRequestedDesktop -gt 0) {
                    $State.Status = 'GamesDesktopMismatch'
                    Save-RunState
                    throw "Official Games.exe owns a window on Default instead of staying on hidden desktop '$HiddenDesktopName'. No Endfield process was started; use -StopLastRun if you want to close only the recorded launcher/Games processes."
                }
                if ($evidence.WindowThreadIds.Count -gt 0 -and $evidence.WindowsOnRequestedDesktop -gt 0) {
                    $State.Status = 'OfficialGamesOnHiddenDesktop'
                    Save-RunState
                    return $item
                }
            }
            Start-Sleep -Milliseconds 200
        }
        $State.Status = 'GamesDesktopEvidenceTimeout'
        Save-RunState
        $timeoutMessage = "Timed out after $TimeoutSeconds seconds without a unique official Games.exe window/thread on hidden desktop '$HiddenDesktopName'. No Endfield process was started."
        if ($lastDesktopEvidenceError) { $timeoutMessage += " Last window enumeration error: $lastDesktopEvidenceError" }
        throw $timeoutMessage
    }
    catch {
        foreach ($item in $references.Values) { $item.Reference.Dispose() }
        throw
    }
}

function Invoke-ActualRun {
    Assert-64BitWindows
    if (-not (Test-IsAdministrator)) { throw 'Actual runs require elevated 64-bit PowerShell. Use Start-Endfield.cmd to request elevation.' }
    $paths = Get-InstallPaths
    $callerDesktop = [HiddenDesktopNative]::GetCurrentDesktopName()
    if (-not [string]::Equals($callerDesktop, 'Default', [StringComparison]::OrdinalIgnoreCase)) {
        throw "The caller is on desktop '$callerDesktop'; actual run requires WinSta0\Default so the game can be explicitly created on the visible desktop. No process was started."
    }
    $oldState = Get-RecordedState
    if ($oldState) {
        foreach ($identity in @($oldState.Games, $oldState.Launcher)) {
            if (Test-RecordedProcessLive $identity) {
                throw "A process from saved run $($oldState.RunId) is still alive. Use -StopLastRun before starting another launch."
            }
        }
    }
    $active = @(Get-SessionNamedProcesses)
    if ($active.Count -gt 0) {
        $details = @($active | ForEach-Object {
            $pathText = if ($_.ExecutablePath) { $_.ExecutablePath } else { '<path unavailable>' }
            '{0} PID={1} Path={2}' -f $_.Name, $_.ProcessId, $pathText
        }) -join '; '
        throw "A Launcher.exe, Games.exe, or Endfield.exe process is already listed in this session ($details). Close it and retry. No new process was launched."
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $script:RunStatePath = Join-Path $script:ToolDirectory ('run-' + $runId + '.json')
    $hiddenName = 'HGEndfield-' + $runId.Substring(0, 16)
    $hiddenPath = [HiddenDesktopNative]::DesktopPath($hiddenName)
    $script:RunState = [ordered]@{
        Schema = 1
        RunId = $runId
        CreatedAt = (Get-Date).ToString('o')
        SessionId = $script:SessionId
        CallerDesktop = $callerDesktop
        HiddenDesktop = $hiddenName
        Launcher = $null
        Games = $null
        GamesCandidates = @()
        GamesWindowThreadIds = @()
        GamesWindowsOnHiddenDesktop = 0
        GamesWindowsOnDefaultDesktop = 0
        Game = $null
        GameWindowWait = $null
        GameWindowHandle = $null
        GameWindowFinalValidationLastIssue = $null
        DesktopEvidenceLastError = $null
        DesktopEvidenceRetryLogged = $false
        LauncherLaunchAttempted = $false
        CleanupAttempted = $false
        CleanupComplete = $false
        LauncherCleanupConfirmed = $false
        GamesCleanupConfirmed = $false
        CleanupResults = @()
        CleanupErrors = @()
        Status = 'Starting'
    }
    $hiddenDesktop = $null
    $visibleDesktop = $null
    $launcherRef = $null
    $script:LauncherReference = $null
    $script:GamesReference = $null
    $gamesItem = $null
    $gameRef = $null
    try {
        $hiddenDesktop = [HiddenDesktopNative]::CreateHiddenDesktop($hiddenName)
        $visibleDesktop = [HiddenDesktopNative]::OpenDesktop($callerDesktop)
        $script:VisibleDesktopReference = $visibleDesktop
        $baselinePids = New-Object 'System.Collections.Generic.HashSet[uint32]'
        foreach ($row in @(Get-SessionNamedProcesses)) { [void]$baselinePids.Add([uint32]$row.ProcessId) }
        $launchUtc = [DateTime]::UtcNow
        Write-RunStatus "Starting root Launcher.exe on hidden desktop '$hiddenName' with official Endfield arguments."
        $script:RunState.LauncherLaunchAttempted = $true
        Save-RunState
        $launcherRef = [HiddenDesktopNative]::StartProcessOnDesktop($paths.Launcher, '--game=endfield --reason=4', $paths.Root, $hiddenPath, $null, $true)
        $script:LauncherReference = $launcherRef
        $launcherSnapshot = [HiddenDesktopNative]::ReadProcess($launcherRef)
        $script:RunState.Launcher = ConvertTo-Identity $launcherSnapshot
        $script:RunState.Status = 'LauncherStarted'
        Save-RunState
        if ($launcherSnapshot.SessionId -ne [uint32]$script:SessionId -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($launcherSnapshot.ImagePath), [System.IO.Path]::GetFullPath($paths.Launcher), [StringComparison]::OrdinalIgnoreCase)) {
            $script:RunState.Status = 'LauncherIdentityMismatch'
            Save-RunState
            throw 'Started Launcher.exe did not match the expected image path and session; no further launch action was taken.'
        }
        Write-RunStatus ("Launcher created: PID={0}, path={1}, session={2}, creationUtc={3}; state saved before game launch." -f $launcherSnapshot.ProcessId, $launcherSnapshot.ImagePath, $launcherSnapshot.SessionId, [DateTime]::FromFileTimeUtc($launcherSnapshot.CreationFileTimeUtc).ToString('o'))
        Write-RunStatus 'Waiting for one newly created exact-path Games.exe process and verifying its window-owning thread by enumerating both hidden and Default desktops.'
        $gamesItem = Wait-ForOfficialGames $paths $baselinePids $launchUtc $hiddenName $hiddenDesktop $visibleDesktop $script:RunState
        $script:GamesReference = $gamesItem.Reference

        if ($InitializationDelaySeconds -gt 0) {
            Write-RunStatus ("Waiting {0} seconds after the hidden Games.exe window appeared; this is a startup heuristic, not authorization evidence." -f $InitializationDelaySeconds)
            Start-Sleep -Seconds $InitializationDelaySeconds
        }
        if (-not [HiddenDesktopNative]::IsRunning($gamesItem.Reference)) { throw 'The selected official Games.exe exited before Endfield could be started.' }
        $parentInfo = [HiddenDesktopNative]::ReadProcess($gamesItem.Reference)
        if ($parentInfo.SessionId -ne [uint32]$script:SessionId) { throw 'Selected Games.exe is no longer in the current session.' }
        $finalGamesEvidence = [HiddenDesktopNative]::ReadDesktopEvidence($parentInfo.ProcessId, $hiddenDesktop)
        $finalDefaultEvidence = [HiddenDesktopNative]::ReadDesktopEvidence($parentInfo.ProcessId, $visibleDesktop)
        if ($finalDefaultEvidence.WindowsOnRequestedDesktop -gt 0 -or $finalGamesEvidence.WindowThreadIds.Count -lt 1) {
            $script:RunState.Status = 'GamesDesktopChangedDuringDelay'
            $script:RunState.GamesWindowThreadIds = @($finalGamesEvidence.WindowThreadIds)
            $script:RunState.GamesWindowsOnHiddenDesktop = [int]$finalGamesEvidence.WindowsOnRequestedDesktop
            $script:RunState.GamesWindowsOnDefaultDesktop = [int]$finalDefaultEvidence.WindowsOnRequestedDesktop
            Save-RunState
            throw 'Games.exe no longer has a window and thread on the hidden desktop after the initialization delay. No Endfield process was started.'
        }
        $gameDesktopPath = [HiddenDesktopNative]::DesktopPath($callerDesktop)
        $providedArguments = if ([string]::IsNullOrWhiteSpace($GameArguments)) { '' } else { $GameArguments }
        Write-RunStatus ("Creating Endfield.exe with explicit desktop '{0}', bInheritHandles=false, parent PID={1}; custom arguments provided={2} (values are not logged)." -f $gameDesktopPath, $parentInfo.ProcessId, [bool]$providedArguments)
        $gameRef = [HiddenDesktopNative]::StartProcessOnDesktop($paths.Game, $providedArguments, (Split-Path -Parent $paths.Game), $gameDesktopPath, $gamesItem.Reference, $false)
        if (-not [HiddenDesktopNative]::IsRunning($gameRef)) {
            $script:RunState.Status = 'GameExitedBeforeWindow'
            Save-RunState
            throw 'Endfield exited immediately after process creation; cleanup will close only this run launcher processes.'
        }
        $gameInfo = [HiddenDesktopNative]::ReadProcess($gameRef)
        $script:RunState.Game = ConvertTo-Identity $gameInfo
        $script:RunState.ExpectedParentProcessId = [uint32]$parentInfo.ProcessId
        $script:RunState.ParentPidObserved = [bool]($gameInfo.ParentProcessId -eq $parentInfo.ProcessId)
        $script:RunState.Status = 'GameCreated'
        Save-RunState
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($gameInfo.ImagePath), [System.IO.Path]::GetFullPath($paths.Game), [StringComparison]::OrdinalIgnoreCase) -or
            $gameInfo.SessionId -ne [uint32]$script:SessionId) {
            $script:RunState.Status = 'GameIdentityMismatch'
            Save-RunState
            throw 'Endfield process image path or session did not match the selected installation; cleanup will close only this run launcher processes.'
        }
        if ($gameInfo.ParentProcessId -ne [uint32]$parentInfo.ProcessId) {
            $script:RunState.Status = 'GameParentMismatch'
            Save-RunState
            throw 'Endfield observed parent PID did not match the selected Games.exe; cleanup will close only this run launcher processes.'
        }
        Write-RunStatus ("Game process created and verified: PID={0}, parent PID={1}, session={2}, image={3}. Waiting up to {4} seconds for a stable main window." -f $gameInfo.ProcessId, $gameInfo.ParentProcessId, $gameInfo.SessionId, $gameInfo.ImagePath, $GameWindowTimeoutSeconds)
        $script:RunState.Status = 'WaitingForGameWindow'
        Save-RunState
        $windowTimeoutMilliseconds = $GameWindowTimeoutSeconds * 1000
        $windowWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $windowResult = $null
        $finalWindowScan = $null
        $lastFinalWindowIssue = ''
        while ($windowWatch.ElapsedMilliseconds -lt $windowTimeoutMilliseconds) {
            $remainingMilliseconds = [int]($windowTimeoutMilliseconds - $windowWatch.ElapsedMilliseconds)
            $windowResult = Wait-ForStableGameWindow $gameRef ([uint32]$gameInfo.ProcessId) $visibleDesktop $remainingMilliseconds
            $script:RunState.GameWindowWait = [ordered]@{
                Status = $windowResult.Status
                ElapsedMilliseconds = [long]$windowWatch.ElapsedMilliseconds
                Detail = $windowResult.Detail
                LastIssue = $windowResult.LastIssue
            }
            Save-RunState
            if ($windowResult.Status -ne 'Stable') {
                $statusMap = @{
                    Exited = 'GameExitedBeforeStableWindow'
                    FailureDialog = 'GameFailureDialog'
                    MultipleMainWindows = 'GameMultipleMainWindows'
                    Unknown = 'GameWindowQueryUnknown'
                    TimedOut = 'GameWindowTimeout'
                }
                $script:RunState.Status = $statusMap[$windowResult.Status]
                Save-RunState
                throw ("Game startup was not confirmed ({0}); this run's launcher processes will be cleaned up. {1}" -f $windowResult.Status, $windowResult.Detail)
            }

            if (-not [HiddenDesktopNative]::IsRunning($gameRef)) {
                $script:RunState.Status = 'GameExitedBeforeCleanup'
                Save-RunState
                throw "Endfield exited after the stable-window check; this run's launcher processes will be cleaned up."
            }
            $finalGameInfo = [HiddenDesktopNative]::ReadProcess($gameRef)
            if ($finalGameInfo.ProcessId -ne [uint32]$gameInfo.ProcessId -or
                $finalGameInfo.CreationFileTimeUtc -ne [long]$gameInfo.CreationFileTimeUtc -or
                $finalGameInfo.SessionId -ne [uint32]$script:SessionId -or
                -not [string]::Equals([System.IO.Path]::GetFullPath($finalGameInfo.ImagePath), [System.IO.Path]::GetFullPath($paths.Game), [StringComparison]::OrdinalIgnoreCase) -or
                $finalGameInfo.ParentProcessId -ne [uint32]$parentInfo.ProcessId) {
                $script:RunState.Status = 'GameIdentityChangedBeforeCleanup'
                Save-RunState
                throw "Endfield process identity changed before launcher cleanup; this run's launcher processes will be cleaned up."
            }
            try { $finalWindowScan = [HiddenDesktopNative]::ReadGameWindowScan([uint32]$gameInfo.ProcessId, $visibleDesktop) }
            catch { $finalWindowScan = [pscustomobject]@{ Kind = 'Unknown'; Handle = [IntPtr]::Zero; Detail = $_.Exception.Message } }
            if ($finalWindowScan.Kind.ToString() -eq 'FailureDialog') {
                $script:RunState.Status = 'GameFailureDialog'
                Save-RunState
                throw ("A game failure dialog appeared during final window validation: {0}" -f $finalWindowScan.Detail)
            }
            if ($finalWindowScan.Kind.ToString() -eq 'MainFound' -and $finalWindowScan.Handle -eq $windowResult.WindowHandle) { break }

            $lastFinalWindowIssue = '{0}: {1}' -f $finalWindowScan.Kind, $finalWindowScan.Detail
            if ($lastFinalWindowIssue -ne $script:RunState.GameWindowFinalValidationLastIssue) {
                $script:RunState.GameWindowFinalValidationLastIssue = $lastFinalWindowIssue
                Write-RunStatus ("Final game-window query did not confirm the stable HWND; continuing within the timeout. {0}" -f $lastFinalWindowIssue)
            }
            $script:RunState.GameWindowFinalValidationLastIssue = $lastFinalWindowIssue
            Save-RunState
        }
        if (-not $windowResult -or $windowResult.Status -ne 'Stable' -or
            $finalWindowScan.Kind.ToString() -ne 'MainFound' -or $finalWindowScan.Handle -ne $windowResult.WindowHandle) {
            $script:RunState.Status = 'GameWindowTimeout'
            $script:RunState.GameWindowWait.Status = 'TimedOut'
            if ($lastFinalWindowIssue) { $script:RunState.GameWindowWait.Detail = 'Final window validation did not recover before timeout. Last query: ' + $lastFinalWindowIssue }
            Save-RunState
            throw ("Game main window was not confirmed through final validation within {0} seconds. {1}" -f $GameWindowTimeoutSeconds, $lastFinalWindowIssue)
        }
        return (Complete-GameLaunch $paths $gameRef $gameInfo $windowResult.WindowHandle)
    }
    finally {
        if ($script:RunState -and $script:RunState.LauncherLaunchAttempted -and -not $script:RunState.CleanupAttempted) {
            if (-not $script:RunState.Launcher -and $launcherRef) {
                try {
                    if ([HiddenDesktopNative]::IsRunning($launcherRef)) {
                        $lateLauncherSnapshot = [HiddenDesktopNative]::ReadProcess($launcherRef)
                        if ($lateLauncherSnapshot.SessionId -eq [uint32]$script:SessionId -and
                            [string]::Equals([System.IO.Path]::GetFullPath([string]$lateLauncherSnapshot.ImagePath), [System.IO.Path]::GetFullPath($paths.Launcher), [StringComparison]::OrdinalIgnoreCase)) {
                            $script:RunState.Launcher = ConvertTo-Identity $lateLauncherSnapshot
                        }
                        else { $script:RunState.CleanupErrors += 'Launcher handle did not match the current session and exact install path during identity recovery.' }
                    }
                    else { $script:RunState.LauncherLaunchAttempted = $false }
                }
                catch { $script:RunState.CleanupErrors += ('Launcher identity recovery failed: ' + $_.Exception.Message) }
            }
            try { [void](Invoke-ThisRunProcessCleanup $paths) }
            catch {
                $script:RunState.CleanupErrors += ('Launcher cleanup coordinator failed: ' + $_.Exception.Message)
                try { Save-RunState; Write-RunStatus $script:RunState.CleanupErrors[-1] } catch { }
            }
        }
        if ($gameRef) { $gameRef.Dispose() }
        if ($gamesItem -and $gamesItem.Reference) { $gamesItem.Reference.Dispose() }
        if ($launcherRef) { $launcherRef.Dispose() }
        if ($visibleDesktop) { $visibleDesktop.Dispose() }
        if ($hiddenDesktop) { $hiddenDesktop.Dispose() }
    }
}

try {
    Assert-64BitWindows
    Import-NativeHelper
    $selectedModes = @()
    if ($CheckOnly) { $selectedModes += 'CheckOnly' }
    if ($SelfTest) { $selectedModes += 'SelfTest' }
    if ($StopLastRun) { $selectedModes += 'StopLastRun' }
    if ($selectedModes.Count -gt 1) { throw 'Choose only one of -CheckOnly, -SelfTest, or -StopLastRun.' }
    if ($CheckOnly) { $exitCode = Invoke-CheckOnly }
    elseif ($SelfTest) { $exitCode = Invoke-SelfTest }
    elseif ($StopLastRun) { $exitCode = Invoke-StopLastRun }
    else { $exitCode = Invoke-ActualRun }
    exit $exitCode
}
catch {
    if ($script:RunState -and $script:RunStatePath) {
        try {
            $script:RunState.FailureReason = $_.Exception.Message
            if ($script:RunState.Status -notin @(
                'GamesDesktopMismatch', 'GamesDesktopChangedDuringDelay', 'GamesDesktopEvidenceTimeout',
                'LauncherIdentityMismatch', 'GameExitedBeforeWindow', 'GameIdentityMismatch', 'GameParentMismatch',
                'GameExitedBeforeStableWindow', 'GameFailureDialog', 'GameMultipleMainWindows', 'GameWindowQueryUnknown',
                'GameWindowTimeout', 'GameExitedBeforeCleanup', 'GameIdentityChangedBeforeCleanup',
                'GameWindowChangedBeforeCleanup', 'GameCleanupPrecheckFailed', 'GameExitedDuringCleanup', 'LauncherCleanupFailed'
            )) {
                $script:RunState.Status = 'Failed'
            }
            Save-RunState
            Write-RunStatus ("Run stopped: {0}" -f $_.Exception.Message)
        } catch { }
    }
    Write-Error $_
    exit 1
}
