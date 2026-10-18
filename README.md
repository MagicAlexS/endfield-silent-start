# endfield-silent-start

Windows 上的《明日方舟：终末地》静默启动工具。官方启动器在隐藏桌面运行，游戏显示在当前桌面；完成启动后关闭本轮启动器并退出工具，保留游戏进程。

提供 PowerShell 脚本、免编译的 VBS 入口和可自行编译的 EXE 入口。VBS 与 EXE 入口均隐藏控制台，并保留 Windows UAC 提权提示。运行信息只保存在内存中，不生成日志或状态文件，多次使用不会累积运行记录。

## 运行环境

- 64 位 Windows、Windows PowerShell 5.1 和 .NET Framework 4.x。
- 已安装官方鹰角启动器与《明日方舟：终末地》。
- 运行时需要管理员权限，并位于当前用户的默认桌面。

## 安装与配置

下载或克隆本仓库，保持脚本和 C# 源文件的相对位置。

**默认目录：** 将整个工具文件夹放在官方启动器安装目录下。程序会检查工具同目录或上一级目录中的 `Launcher.exe`，例如：

```text
Hypergryph Launcher/
├── Launcher.exe
├── 1.6.0/
│   └── Games.exe
├── games/Endfield Game/Endfield.exe
└── endfield-silent-start/
    ├── Start-Endfield.ps1
    ├── HiddenDesktopNative.cs
    └── ...
```

**自定义目录：** 工具也可以放在其他目录。复制 `config.example.json` 为 `config.json`，修改安装路径：

```json
{
  "InstallRoot": "D:\\Games\\Hypergryph Launcher",
  "GamePath": "games\\Endfield Game\\Endfield.exe",
  "GamesPath": ""
}
```

- `InstallRoot`：包含 `Launcher.exe` 的目录。相对路径以工具目录为基准。
- `GamePath`：游戏可执行文件，可填绝对路径或相对于 `InstallRoot` 的路径。
- `GamesPath`：通常留空，自动查找安装根目录或一层数字版本目录中的唯一 `Games.exe`。存在多个版本时，可填 `1.6.0\Games.exe` 等路径，指定其中一个。

命令行参数优先于配置文件。运行前关闭已有的游戏和官方启动器。

## 使用

### VBS 启动（免编译）

系统启用 Windows Script Host 和 VBScript 时，可以直接双击 `Start-Endfield.vbs`，在 UAC 提示中确认，无需编译 EXE。VBS 会隐藏启动 64 位 PowerShell；游戏仍显示在当前桌面。

也可以显式使用 Windows 脚本宿主运行：

```cmd
wscript.exe Start-Endfield.vbs
```

VBS 需要与 `Start-Endfield.ps1`、`HiddenDesktopNative.cs` 放在同一目录，自定义安装路径仍使用 `config.json`。VBS 发起启动后即退出，后续等待和清理由 PowerShell 脚本完成；它不传递主脚本的最终退出码。

### EXE 启动

先按下文编译 EXE，然后双击 `EndfieldSilentStart.exe`，在 UAC 提示中确认。启动过程不显示 CMD 或 PowerShell 控制台。

EXE 运行时依赖同目录的 `Start-Endfield.ps1` 和 `HiddenDesktopNative.cs`。

### 脚本启动

双击 `Start-Endfield.cmd` 可显示控制台运行；也可以在管理员权限的 64 位 Windows PowerShell 中执行：

```powershell
.\Start-Endfield.ps1
.\Start-Endfield.ps1 -InstallRoot 'D:\Games\Hypergryph Launcher'
.\Start-Endfield.ps1 -InstallRoot 'D:\Games\Hypergryph Launcher' -GamePath 'E:\Games\Endfield\Endfield.exe'
```

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-InstallRoot` | 自动定位 | 官方启动器安装目录 |
| `-GamePath` | `games\Endfield Game\Endfield.exe` | 游戏可执行文件路径 |
| `-GamesPath` | 自动查找 | 指定官方 `Games.exe` 路径 |
| `-TimeoutSeconds` | `60` | 等待启动器窗口的上限，5–300 秒 |
| `-InitializationDelaySeconds` | `1` | 启动器窗口出现后的初始化等待，0–60 秒 |
| `-GameWindowTimeoutSeconds` | `300` | 等待游戏窗口的上限，5–900 秒 |

游戏主窗口连续稳定显示 2 秒后立即清理启动器，不必等待超时上限。窗口暂未出现、查询暂时失败或存在多个候选窗口时，会在等待期限内重试。检测失败或超时也会清理本轮启动器，保留游戏进程。

清理仅针对本轮在内存中记录且路径、创建时间及会话匹配的 `Launcher.exe`、`Games.exe`，不会递归结束进程树。退出后丢弃本轮运行信息。

## 工作原理

1. 创建 Win32 隐藏桌面，在其中运行官方 `Launcher.exe --game=endfield --reason=4`。
2. 查找同一会话中新出现的官方 `Games.exe`，核对其文件路径和窗口所属桌面。
3. 通过 Windows `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS` 指定该 `Games.exe` 为父进程，在 `WinSta0\Default` 桌面创建游戏进程。
4. 等待同一游戏主窗口稳定显示，然后清理本轮启动器并退出。

脚本不修改游戏或启动器文件。窗口稳定是进程启动的观察条件，不等同于完成游戏内登录；客户端更新可能需要同步调整路径或窗口识别规则。

## 编译 EXE

在 Windows 上执行：

```cmd
build.cmd
```

构建脚本调用 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`，将 `SilentStart.cs` 编译为 64 位 Windows GUI 程序 `EndfieldSilentStart.exe`，并嵌入 `SilentStart.manifest` 中的管理员权限声明。GUI 子系统和 `CreateNoWindow` 用于避免创建控制台窗口，不依赖额外打包工具或游戏图标。

分发自行编译的入口时，至少保留这三个文件：

```text
EndfieldSilentStart.exe
Start-Endfield.ps1
HiddenDesktopNative.cs
```

如需自定义路径，同时放置 `config.json`。本仓库仅发布源代码，不提交编译产物。

## 开发检查

```powershell
.\Start-Endfield.ps1 -CheckOnly
.\Start-Endfield.ps1 -SelfTest
.\tests\Test-Paths.ps1
.\tests\Test-NoState.ps1
.\tests\Test-ConsoleExit.ps1
.\tests\Test-SilentStart.ps1
.\tests\Test-VbsStart.ps1
```

`-CheckOnly` 检查配置、路径及进程状态；其余检查使用临时模拟进程，不启动真实游戏。

## 许可证

本项目源码采用 [MIT 许可证](LICENSE)，允许使用、修改和再分发，分发时须保留版权和许可声明。仓库不包含游戏、官方启动器或其图标等资源。
