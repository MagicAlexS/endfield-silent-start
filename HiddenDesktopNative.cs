using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class HiddenDesktopNative
{
    internal const uint ProcessCreateProcess = 0x0080;
    internal const uint ProcessQueryLimitedInformation = 0x1000;
    internal const uint ProcessTerminate = 0x0001;
    internal const uint Synchronize = 0x00100000;
    internal const uint WaitObject0 = 0;
    internal const uint WaitTimeout = 0x102;
    internal const uint CreateUnicodeEnvironment = 0x00000400;
    internal const uint ExtendedStartupInfoPresent = 0x00080000;
    internal const uint StartfUseShowWindow = 0x00000001;
    internal const short SwHide = 0;
    internal const int UoiName = 2;
    private const uint DesktopCreateWindow = 0x0002;
    private const uint DesktopEnumerate = 0x0040;
    private const uint DesktopReadObjects = 0x0001;
    private const uint DesktopWriteObjects = 0x0080;
    private const uint ParentProcessAttribute = 0x00020000;
    private const uint Th32csSnapProcess = 0x00000002;
    private const uint ErrorInsufficientBuffer = 122;

    public sealed class DesktopHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private DesktopHandle() : base(true) { }
        internal DesktopHandle(IntPtr handle) : base(true) { SetHandle(handle); }
        protected override bool ReleaseHandle() { return CloseDesktop(handle); }
    }

    public sealed class ProcessRef : IDisposable
    {
        internal readonly SafeProcessHandle Handle;
        internal ProcessRef(IntPtr handle) { Handle = new SafeProcessHandle(handle, true); }
        internal ProcessRef(SafeProcessHandle handle) { Handle = handle; }
        public void Dispose() { Handle.Dispose(); }
    }

    public sealed class ProcessSnapshot
    {
        public uint ProcessId;
        public uint ParentProcessId;
        public uint SessionId;
        public string ImagePath;
        public long CreationFileTimeUtc;
    }

    public sealed class DesktopEvidence
    {
        public uint[] WindowThreadIds;
        public int WindowsOnRequestedDesktop;
        public int VisibleWindowsOnRequestedDesktop;
    }

    public enum GameWindowScanKind { Unknown, None, MainFound, FailureDialog, Multiple }

    public sealed class GameWindowSnapshot
    {
        public uint ProcessId;
        public IntPtr Handle;
        public bool Visible, Minimized, Owned;
        public string Title;
        public int ClientWidth, ClientHeight;

        public GameWindowSnapshot(uint processId, IntPtr handle, bool visible, bool minimized,
            bool owned, string title, int clientWidth, int clientHeight)
        {
            ProcessId = processId;
            Handle = handle;
            Visible = visible;
            Minimized = minimized;
            Owned = owned;
            Title = title ?? String.Empty;
            ClientWidth = clientWidth;
            ClientHeight = clientHeight;
        }
    }

    public sealed class GameWindowScanResult
    {
        public GameWindowScanKind Kind;
        public IntPtr Handle;
        public string Detail;

        public GameWindowScanResult(GameWindowScanKind kind, IntPtr handle, string detail)
        {
            Kind = kind;
            Handle = handle;
            Detail = detail ?? String.Empty;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public UIntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    private delegate bool EnumDesktopWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDesktopW(string lpszDesktop, IntPtr lpszDevice, IntPtr pDevmode,
        uint dwFlags, uint dwDesiredAccess, IntPtr lpsa);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenDesktopW(string lpszDesktop, uint dwFlags, bool fInherit, uint dwDesiredAccess);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseDesktop(IntPtr hDesktop);
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint dwErrCode);
    [DllImport("user32.dll")] private static extern IntPtr GetThreadDesktop(uint dwThreadId);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, IntPtr pvInfo, uint nLength, out uint lpnLengthNeeded);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumDesktopWindowsProc lpfn, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetWindowTextLengthW")]
    private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetWindowTextW")]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetClientRect(IntPtr hWnd, out Rect lpRect);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "QueryFullProcessImageNameW", SetLastError = true)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(SafeProcessHandle hProcess, out long lpCreationTime, out long lpExitTime, out long lpKernelTime, out long lpUserTime);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(SafeProcessHandle hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(SafeProcessHandle hProcess, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32FirstW(IntPtr hSnapshot, ref ProcessEntry32 lppe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32NextW(IntPtr hSnapshot, ref ProcessEntry32 lppe);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, uint dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
    private static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        string lpCurrentDirectory, ref StartupInfo lpStartupInfo, out ProcessInformation lpProcessInformation);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
    private static extern bool CreateProcessEx(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        string lpCurrentDirectory, ref StartupInfoEx lpStartupInfo, out ProcessInformation lpProcessInformation);

    public static string GetCurrentDesktopName()
    {
        IntPtr desktop = GetThreadDesktop(GetCurrentThreadId());
        if (desktop == IntPtr.Zero) ThrowLastError("GetThreadDesktop(current)");
        return GetObjectName(desktop);
    }

    public static DesktopHandle CreateHiddenDesktop(string name)
    {
        IntPtr desktop = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0,
            DesktopCreateWindow | DesktopEnumerate | DesktopReadObjects | DesktopWriteObjects, IntPtr.Zero);
        if (desktop == IntPtr.Zero) ThrowLastError("CreateDesktopW(" + name + ")");
        return new DesktopHandle(desktop);
    }

    public static DesktopHandle OpenDesktop(string name)
    {
        IntPtr desktop = OpenDesktopW(name, 0, false,
            DesktopEnumerate | DesktopReadObjects | DesktopWriteObjects);
        if (desktop == IntPtr.Zero) ThrowLastError("OpenDesktopW(" + name + ")");
        return new DesktopHandle(desktop);
    }

    public static string DesktopPath(string name) { return "WinSta0\\" + name; }

    public static ProcessRef OpenProcessRef(uint pid, uint access)
    {
        SafeProcessHandle handle = OpenProcess(access, false, pid);
        if (handle == null || handle.IsInvalid) ThrowLastError("OpenProcess(PID=" + pid + ")");
        return new ProcessRef(handle);
    }

    public static ProcessSnapshot ReadProcess(ProcessRef process)
    {
        if (process == null || process.Handle == null || process.Handle.IsInvalid) throw new ArgumentException("Process handle is invalid.");
        uint pid = GetProcessId(process.Handle);
        if (pid == 0) ThrowLastError("GetProcessId");
        string image = ReadImagePath(process.Handle);
        long creation, exit, kernel, user;
        if (!GetProcessTimes(process.Handle, out creation, out exit, out kernel, out user)) ThrowLastError("GetProcessTimes");
        uint session;
        if (!ProcessIdToSessionId(pid, out session)) ThrowLastError("ProcessIdToSessionId");
        return new ProcessSnapshot { ProcessId = pid, ParentProcessId = GetParentProcessId(pid), SessionId = session,
            ImagePath = image, CreationFileTimeUtc = creation };
    }

    public static bool IsRunning(ProcessRef process)
    {
        uint result = WaitForSingleObject(process.Handle, 0);
        if (result == WaitTimeout) return true;
        if (result == WaitObject0) return false;
        ThrowLastError("WaitForSingleObject");
        return false;
    }

    public static ProcessRef StartProcessOnDesktop(string applicationPath, string arguments, string workingDirectory,
        string desktopPath, ProcessRef parent, bool hideWindow)
    {
        if (parent == null)
        {
            StartupInfo si = new StartupInfo();
            si.cb = Marshal.SizeOf(typeof(StartupInfo));
            si.lpDesktop = desktopPath;
            if (hideWindow) { si.dwFlags = StartfUseShowWindow; si.wShowWindow = SwHide; }
            ProcessInformation pi;
            StringBuilder command = MakeCommandLine(applicationPath, arguments);
            bool ok = CreateProcess(applicationPath, command, IntPtr.Zero, IntPtr.Zero, false,
                CreateUnicodeEnvironment, IntPtr.Zero, workingDirectory, ref si, out pi);
            if (!ok) ThrowLastError("CreateProcess(" + applicationPath + ")");
            CloseHandle(pi.hThread);
            return new ProcessRef(pi.hProcess);
        }

        IntPtr size = IntPtr.Zero;
        bool sizeQueryResult = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        int expectedError = Marshal.GetLastWin32Error();
        if (sizeQueryResult || size == IntPtr.Zero || expectedError != ErrorInsufficientBuffer)
            throw new Win32Exception(expectedError, "InitializeProcThreadAttributeList(size) returned an unexpected result");
        IntPtr list = Marshal.AllocHGlobal(size);
        IntPtr parentValue = Marshal.AllocHGlobal(IntPtr.Size);
        bool listInitialized = false;
        bool addRef = false;
        try
        {
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) ThrowLastError("InitializeProcThreadAttributeList");
            listInitialized = true;
            parent.Handle.DangerousAddRef(ref addRef);
            Marshal.WriteIntPtr(parentValue, parent.Handle.DangerousGetHandle());
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(ParentProcessAttribute), parentValue,
                new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) ThrowLastError("UpdateProcThreadAttribute(PARENT_PROCESS)");
            StartupInfoEx si = new StartupInfoEx();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(StartupInfoEx));
            si.StartupInfo.lpDesktop = desktopPath;
            if (hideWindow) { si.StartupInfo.dwFlags = StartfUseShowWindow; si.StartupInfo.wShowWindow = SwHide; }
            si.lpAttributeList = list;
            ProcessInformation pi;
            StringBuilder command = MakeCommandLine(applicationPath, arguments);
            bool ok = CreateProcessEx(applicationPath, command, IntPtr.Zero, IntPtr.Zero, false,
                CreateUnicodeEnvironment | ExtendedStartupInfoPresent, IntPtr.Zero, workingDirectory, ref si, out pi);
            if (!ok)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "CreateProcess(parent process, image=" + applicationPath + ") failed (Win32 " + error + ")");
            }
            CloseHandle(pi.hThread);
            return new ProcessRef(pi.hProcess);
        }
        finally
        {
            if (listInitialized) DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(parentValue);
            Marshal.FreeHGlobal(list);
            if (addRef) parent.Handle.DangerousRelease();
        }
    }

    public static DesktopEvidence ReadDesktopEvidence(uint pid, DesktopHandle requestedDesktop)
    {
        List<uint> windowThreads = new List<uint>();
        int windows = 0;
        int visibleWindows = 0;
        int callbackCount = 0;
        SetLastError(0);
        bool enumerated = EnumDesktopWindows(requestedDesktop.DangerousGetHandle(), delegate(IntPtr hwnd, IntPtr lParam)
        {
            callbackCount++;
            uint windowPid;
            uint threadId = GetWindowThreadProcessId(hwnd, out windowPid);
            if (windowPid == pid)
            {
                windows++;
                if (!windowThreads.Contains(threadId)) windowThreads.Add(threadId);
                if (IsWindowVisible(hwnd)) visibleWindows++;
            }
            return true;
        }, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        if (!enumerated)
        {
            string detail = "EnumDesktopWindows returned false (Win32 " + error + ") for PID=" + pid +
                "; callbacks=" + callbackCount + "; windows owned by PID=" + windows + ".";
            if (error != 0) throw new Win32Exception(error, detail);
            throw new InvalidOperationException(detail);
        }
        return new DesktopEvidence { WindowThreadIds = windowThreads.ToArray(), WindowsOnRequestedDesktop = windows,
            VisibleWindowsOnRequestedDesktop = visibleWindows };
    }

    public static bool HasWindowOnDesktop(uint pid, DesktopHandle desktop)
    {
        return ReadDesktopEvidence(pid, desktop).WindowsOnRequestedDesktop > 0;
    }

    public static GameWindowScanResult ReadGameWindowScan(uint expectedPid, DesktopHandle desktop)
    {
        List<GameWindowSnapshot> windows = new List<GameWindowSnapshot>();
        int callbackCount = 0;
        Exception queryError = null;
        SetLastError(0);
        bool enumerated = EnumDesktopWindows(desktop.DangerousGetHandle(), delegate(IntPtr hwnd, IntPtr lParam)
        {
            callbackCount++;
            uint windowPid;
            uint threadId = GetWindowThreadProcessId(hwnd, out windowPid);
            if (threadId == 0)
            {
                if (!IsWindow(hwnd)) return true;
                queryError = new InvalidOperationException("GetWindowThreadProcessId returned zero for a live desktop window.");
                return false;
            }
            if (windowPid != expectedPid) return true;

            try
            {
                bool visible = IsWindowVisible(hwnd);
                string title = String.Empty;
                if (visible)
                {
                    SetLastError(0);
                    int titleLength = GetWindowTextLength(hwnd);
                    int titleLengthError = Marshal.GetLastWin32Error();
                    if (titleLength == 0 && titleLengthError != 0)
                    {
                        if (!IsWindow(hwnd)) return true;
                        throw new Win32Exception(titleLengthError, "GetWindowTextLengthW failed for a live process window.");
                    }
                    if (titleLength > 0)
                    {
                        StringBuilder titleBuffer = new StringBuilder(titleLength + 1);
                        int copied = GetWindowText(hwnd, titleBuffer, titleBuffer.Capacity);
                        if (copied <= 0)
                        {
                            if (!IsWindow(hwnd)) return true;
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowTextW returned no title for a live visible process window.");
                        }
                        title = titleBuffer.ToString();
                    }
                }

                int width = 0, height = 0;
                if (visible && String.Equals(title, "Endfield", StringComparison.Ordinal))
                {
                    Rect rect;
                    if (!GetClientRect(hwnd, out rect))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "GetClientRect failed for the Endfield window.");
                    width = rect.Right - rect.Left;
                    height = rect.Bottom - rect.Top;
                }

                windows.Add(new GameWindowSnapshot(expectedPid, hwnd, visible,
                    visible && IsIconic(hwnd), visible && GetWindow(hwnd, 4) != IntPtr.Zero,
                    title, width, height));
                return true;
            }
            catch (Exception ex)
            {
                queryError = ex;
                return false;
            }
        }, IntPtr.Zero);

        int error = Marshal.GetLastWin32Error();
        if (queryError != null)
            throw new InvalidOperationException("Could not reliably query a visible Endfield process window.", queryError);
        if (!enumerated)
        {
            string detail = "EnumDesktopWindows returned false (Win32 " + error + ") for PID=" + expectedPid +
                "; callbacks=" + callbackCount + ".";
            if (error != 0) throw new Win32Exception(error, detail);
            throw new InvalidOperationException(detail);
        }
        return ClassifyGameWindows(expectedPid, windows, true);
    }

    public static GameWindowScanResult ClassifyGameWindows(uint expectedPid,
        IList<GameWindowSnapshot> windows, bool enumerationKnown)
    {
        if (!enumerationKnown || windows == null)
            return new GameWindowScanResult(GameWindowScanKind.Unknown, IntPtr.Zero, "enumeration-unknown");

        for (int i = 0; i < windows.Count; i++)
        {
            GameWindowSnapshot window = windows[i];
            if (window == null)
                return new GameWindowScanResult(GameWindowScanKind.Unknown, IntPtr.Zero, "snapshot-null");
            if (window.ProcessId == expectedPid && window.Visible &&
                String.Equals(window.Title, "游戏启动失败", StringComparison.Ordinal))
                return new GameWindowScanResult(GameWindowScanKind.FailureDialog, window.Handle, "failure-dialog");
        }

        List<IntPtr> mainWindows = new List<IntPtr>();
        for (int i = 0; i < windows.Count; i++)
        {
            GameWindowSnapshot window = windows[i];
            if (window.ProcessId != expectedPid || !window.Visible || window.Minimized || window.Owned ||
                !String.Equals(window.Title, "Endfield", StringComparison.Ordinal)) continue;
            if (window.Handle == IntPtr.Zero)
                return new GameWindowScanResult(GameWindowScanKind.Unknown, IntPtr.Zero, "main-hwnd-invalid");
            if (window.ClientWidth >= 320 && window.ClientHeight >= 200) mainWindows.Add(window.Handle);
        }

        if (mainWindows.Count == 0)
            return new GameWindowScanResult(GameWindowScanKind.None, IntPtr.Zero, "no-main-window");
        if (mainWindows.Count > 1)
            return new GameWindowScanResult(GameWindowScanKind.Multiple, IntPtr.Zero, "multiple-main-windows");
        return new GameWindowScanResult(GameWindowScanKind.MainFound, mainWindows[0], "main-window");
    }

    public static bool RunGameWindowPolicySelfTests()
    {
        const uint pid = 1234;
        Func<GameWindowSnapshot, GameWindowScanKind> classify = delegate(GameWindowSnapshot window)
        {
            return ClassifyGameWindows(pid, new List<GameWindowSnapshot> { window }, true).Kind;
        };
        bool ok = true;
        ok &= classify(new GameWindowSnapshot(pid + 1, new IntPtr(1), true, false, false, "Endfield", 800, 600)) == GameWindowScanKind.None;
        ok &= classify(new GameWindowSnapshot(pid, new IntPtr(2), false, false, false, "Endfield", 800, 600)) == GameWindowScanKind.None;
        ok &= classify(new GameWindowSnapshot(pid, new IntPtr(3), true, false, true, "Endfield", 800, 600)) == GameWindowScanKind.None;
        ok &= classify(new GameWindowSnapshot(pid, new IntPtr(4), true, true, false, "Endfield", 800, 600)) == GameWindowScanKind.None;
        ok &= classify(new GameWindowSnapshot(pid, new IntPtr(5), true, false, false, "Endfield", 319, 200)) == GameWindowScanKind.None;
        ok &= classify(new GameWindowSnapshot(pid, new IntPtr(10), true, false, false, "Endfield", 320, 200)) == GameWindowScanKind.MainFound;
        ok &= ClassifyGameWindows(pid, null, false).Kind == GameWindowScanKind.Unknown;
        ok &= ClassifyGameWindows(pid, new List<GameWindowSnapshot> {
            new GameWindowSnapshot(pid, new IntPtr(6), true, false, false, "Endfield", 800, 600),
            new GameWindowSnapshot(pid, new IntPtr(7), true, false, false, "游戏启动失败", 400, 240)
        }, true).Kind == GameWindowScanKind.FailureDialog;
        ok &= ClassifyGameWindows(pid, new List<GameWindowSnapshot> {
            new GameWindowSnapshot(pid, new IntPtr(8), true, false, false, "Endfield", 800, 600),
            new GameWindowSnapshot(pid, new IntPtr(9), true, false, false, "Endfield", 800, 600)
        }, true).Kind == GameWindowScanKind.Multiple;
        Console.WriteLine("game-window-policy: " + (ok ? "PASS" : "FAIL") +
            " PID/visibility/owner/minimize/size/failure/multiple/unknown");
        return ok;
    }

    public static bool CloseWindowsOnDesktop(uint pid, DesktopHandle desktop)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumDesktopWindows(desktop.DangerousGetHandle(), delegate(IntPtr hwnd, IntPtr lParam)
        {
            uint windowPid;
            GetWindowThreadProcessId(hwnd, out windowPid);
            if (windowPid == pid) windows.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        bool posted = true;
        for (int i = 0; i < windows.Count; i++)
            if (!PostMessageW(windows[i], 0x0010, IntPtr.Zero, IntPtr.Zero)) posted = false;
        return posted;
    }

    public static bool StopVerifiedProcess(uint pid, string expectedPath, long expectedCreationFileTimeUtc)
    {
        return StopVerifiedProcess(pid, expectedPath, expectedCreationFileTimeUtc, UInt32.MaxValue);
    }

    public static bool StopVerifiedProcess(uint pid, string expectedPath, long expectedCreationFileTimeUtc,
        uint expectedSessionId)
    {
        using (ProcessRef process = OpenProcessRef(pid, ProcessQueryLimitedInformation | ProcessTerminate | Synchronize))
        {
            ProcessSnapshot info = ReadProcess(process);
            if (!String.Equals(NormalizePath(info.ImagePath), NormalizePath(expectedPath), StringComparison.OrdinalIgnoreCase) ||
                info.CreationFileTimeUtc != expectedCreationFileTimeUtc ||
                (expectedSessionId != UInt32.MaxValue && info.SessionId != expectedSessionId)) return false;
            uint existingWait = WaitForSingleObject(process.Handle, 0);
            if (existingWait == WaitObject0) return true;
            if (existingWait != WaitTimeout) ThrowLastError("WaitForSingleObject(PID=" + pid + ")");
            if (!TerminateProcess(process.Handle, 0)) ThrowLastError("TerminateProcess(PID=" + pid + ")");
            uint result = WaitForSingleObject(process.Handle, 5000);
            if (result == WaitObject0) return true;
            if (result != WaitTimeout) ThrowLastError("WaitForSingleObject(PID=" + pid + ")");
            return false;
        }
    }

    private static StringBuilder MakeCommandLine(string app, string args)
    {
        string value = "\"" + app + "\"" + (String.IsNullOrWhiteSpace(args) ? "" : " " + args);
        return new StringBuilder(value, value.Length + 2);
    }

    private static string ReadImagePath(SafeProcessHandle handle)
    {
        StringBuilder path = new StringBuilder(32768);
        uint size = (uint)path.Capacity;
        if (!QueryFullProcessImageName(handle, 0, path, ref size)) ThrowLastError("QueryFullProcessImageName");
        return path.ToString();
    }

    private static uint GetProcessId(SafeProcessHandle process)
    {
        return GetProcessIdNative(process);
    }
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "GetProcessId")]
    private static extern uint GetProcessIdNative(SafeProcessHandle hProcess);

    private static uint GetParentProcessId(uint pid)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snapshot == new IntPtr(-1)) ThrowLastError("CreateToolhelp32Snapshot");
        try
        {
            ProcessEntry32 entry = new ProcessEntry32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(ProcessEntry32));
            if (!Process32FirstW(snapshot, ref entry)) ThrowLastError("Process32FirstW");
            do { if (entry.th32ProcessID == pid) return entry.th32ParentProcessID; }
            while (Process32NextW(snapshot, ref entry));
            return 0;
        }
        finally { CloseHandle(snapshot); }
    }

    private static string GetObjectName(IntPtr handle)
    {
        uint needed;
        GetUserObjectInformationW(handle, UoiName, IntPtr.Zero, 0, out needed);
        int error = Marshal.GetLastWin32Error();
        if (needed == 0 && error != ErrorInsufficientBuffer) throw new Win32Exception(error, "GetUserObjectInformationW(size)");
        IntPtr buffer = Marshal.AllocHGlobal((int)needed + 2);
        try
        {
            if (!GetUserObjectInformationW(handle, UoiName, buffer, needed, out needed)) ThrowLastError("GetUserObjectInformationW(name)");
            return Marshal.PtrToStringUni(buffer);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static string NormalizePath(string path) { return System.IO.Path.GetFullPath(path).TrimEnd('\\'); }
    private static void ThrowLastError(string operation)
    {
        int error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, operation + " failed (Win32 " + error + ")");
    }
}
