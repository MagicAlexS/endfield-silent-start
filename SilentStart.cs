using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class EndfieldSilentStart
{
    private const string RunnerFileName = "Start-Endfield.ps1";

    private static int Main(string[] args)
    {
        try
        {
            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            bool stopLastRun = false;

            if (args.Length == 1 && string.Equals(args[0], "-StopLastRun", StringComparison.OrdinalIgnoreCase))
            {
                stopLastRun = true;
            }
            else if (args.Length != 0)
            {
                return 2;
            }

            string runnerPath = Path.GetFullPath(Path.Combine(baseDirectory, RunnerFileName));
            if (!File.Exists(runnerPath))
            {
                return 1;
            }

            string windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powershellPath = Path.Combine(windowsDirectory, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershellPath))
            {
                return 1;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powershellPath;
            startInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + QuoteArgument(runnerPath) +
                (stopLastRun ? " -StopLastRun" : String.Empty);
            startInfo.WorkingDirectory = baseDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;

            using (Process process = new Process())
            {
                process.StartInfo = startInfo;
                if (!process.Start())
                {
                    return 1;
                }

                // Acquire the process handle before waiting; WaitForExit waits for this process only.
                IntPtr processHandle = process.Handle;
                if (processHandle == IntPtr.Zero)
                {
                    return 1;
                }

                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            // Keep the GUI-subsystem launcher silent; a launch failure is reported by exit code 1.
            return 1;
        }
    }

    private static string QuoteArgument(string value)
    {
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;

        for (int i = 0; i < value.Length; i++)
        {
            char character = value[i];
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            if (backslashes != 0)
            {
                result.Append('\\', backslashes);
                backslashes = 0;
            }
            result.Append(character);
        }

        if (backslashes != 0)
        {
            result.Append('\\', backslashes * 2);
        }
        result.Append('"');
        return result.ToString();
    }

}
