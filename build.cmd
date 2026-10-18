@echo off
setlocal
set "ENDFIELD_SILENT_START_DIR=%~dp0"
set "ENDFIELD_SILENT_START_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if not exist "%ENDFIELD_SILENT_START_CSC%" (
    >&2 echo .NET Framework 64-bit csc.exe was not found.
    endlocal & exit /b 1
)

"%ENDFIELD_SILENT_START_CSC%" /nologo /target:winexe /platform:x64 /win32manifest:"%ENDFIELD_SILENT_START_DIR%SilentStart.manifest" /out:"%ENDFIELD_SILENT_START_DIR%EndfieldSilentStart.exe" "%ENDFIELD_SILENT_START_DIR%SilentStart.cs"
set "ENDFIELD_SILENT_START_BUILD_EXIT=%ERRORLEVEL%"
endlocal & exit /b %ENDFIELD_SILENT_START_BUILD_EXIT%
