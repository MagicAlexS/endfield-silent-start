Option Explicit

Const Quote = """"

Dim fso
Dim shell
Dim shellApplication
Dim processEnvironment
Dim baseDirectory
Dim runnerPath
Dim windowsDirectory
Dim powershellDirectory
Dim powershellPath
Dim arguments
Dim launchError

If WScript.Arguments.Count <> 0 Then WScript.Quit 2

Set fso = CreateObject("Scripting.FileSystemObject")
baseDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
runnerPath = fso.BuildPath(baseDirectory, "Start-Endfield.ps1")
If Not fso.FileExists(runnerPath) Then WScript.Quit 1

Set shell = CreateObject("WScript.Shell")
windowsDirectory = shell.ExpandEnvironmentStrings("%WINDIR%")
Set processEnvironment = shell.Environment("PROCESS")
If Len(processEnvironment("PROCESSOR_ARCHITEW6432")) > 0 Then
    powershellDirectory = "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
Else
    powershellDirectory = "System32\WindowsPowerShell\v1.0\powershell.exe"
End If
powershellPath = fso.BuildPath(windowsDirectory, powershellDirectory)
If Not fso.FileExists(powershellPath) Then WScript.Quit 1

arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Quote & runnerPath & Quote

On Error Resume Next
Set shellApplication = CreateObject("Shell.Application")
If Err.Number <> 0 Then WScript.Quit 1
Err.Clear
shellApplication.ShellExecute powershellPath, arguments, baseDirectory, "runas", 0
launchError = Err.Number
On Error GoTo 0

If launchError <> 0 Then WScript.Quit 1
WScript.Quit 0
