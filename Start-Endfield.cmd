@echo off
setlocal
set "ENDFIELD_SILENT_START_RUNNER=%~dp0Start-Endfield-Elevated.ps1"
set "ENDFIELD_SILENT_START_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $a='-NoProfile -ExecutionPolicy Bypass -File '+$q+$env:ENDFIELD_SILENT_START_RUNNER+$q; if(([string]$env:ENDFIELD_SILENT_START_ARGS).Trim()){Write-Error 'Use the main PS1 for command-line options.'; exit 2}; $p=$null; try{$p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $a -PassThru; $null=$p.Handle; $p.WaitForExit(); exit $p.ExitCode}catch{Write-Error $_; exit 1}finally{if($p){$p.Dispose()}}"
set "ENDFIELD_SILENT_START_EXIT=%errorlevel%"
if not "%ENDFIELD_SILENT_START_EXIT%"=="0" echo The elevated launcher reported exit code %ENDFIELD_SILENT_START_EXIT%.
endlocal & exit /b %ENDFIELD_SILENT_START_EXIT%
