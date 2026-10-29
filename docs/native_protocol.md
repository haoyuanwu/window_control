# Flutter / Native 协议

通道名：window_control/native。平台应对参数做独立验证，不能只相信界面。以下为本轮约定，实际实现与验收分开记录。

## configure

参数为对象：

```json
{
  "enabled": false,
  "resizeKeys": ["ctrl", "alt"],
  "moveKeys": ["ctrl", "shift"],
  "excludedApps": [],
  "edgeResize": true,
  "rememberWindows": false,
  "launchAtLogin": false,
  "applyLaunchAtLogin": false,
  "autoEnable": false,
  "closeToTray": true
}
```

返回 status 对象。enabled=false 必须先停止拦截，即使其他字段非法。其他非法参数返回 FlutterError，不得留下界面显示关闭但旧监听继续运行的状态。

键名只允许 ctrl / alt / shift / meta，集合非空、无重复。比例键组合由 resizeKeys 派生：不含 shift 则增加 shift，否则增加 alt。要求普通缩放、比例缩放、移动三者均不同；否则明确拒绝配置。

launchAtLogin 字段表示期望值，不能把每次 configure 变成一次系统登录项写入。实际登录项变更由 applyLaunchAtLogin=true 显式门禁控制，仅用户主动切换该选项时设置为 true；初始化、其他设置保存、单纯读取状态必须为 false 或省略。开发测试只能使用隔离替身，不得产生真实登录设置副作用。macOS 采用 macOS 13+ SMAppService.mainApp，旧系统明确报告不支持。

## 状态和权限

getStatus 无参数，返回至少：

```json
{
  "enabled": false,
  "accessibility": false,
  "inputMonitoring": false,
  "message": "服务已暂停",
  "undoCount": 0,
  "launchAtLogin": false
}
```

enabled 为实际服务状态；launchAtLogin 为真实系统状态；undoCount 为历史计数（0..20）。权限或后台菜单导致变化时，Flutter 和托盘需刷新。requestPermissions 返回相同状态格式；仅在用户主动请求时展示系统授权界面。

## 窗口列表与操作

listWindows 无参数，返回数组：

```json
[{"id":"platform-window-id","title":"窗口标题","app":"stable-platform-app-id"}]
```

id 是不透明标识，Flutter 原样回传；不得将标题当作窗口身份。排除和不可操作窗口应过滤，操作前重新校验目标与进程身份。

applyPreset 参数：windowId（listWindows 返回的 id）、width、height、center（bool），返回 bool。尺寸为整数，各边 100..16384；逻辑/物理坐标转换由平台在对应目标屏幕处理。成功产生一条撤销记录；失败不得虚构成功。

centerWindow 参数：windowId，返回 bool。使用目标工作区居中并保持实际尺寸，不切换系统全屏。成功且几何确有变化才记录撤销。

restoreLast 无参数，返回 bool；最多保留 20 步操作前几何，需验证目标身份、防止句柄复用。返回后刷新 undoCount。

尺寸预设集合由 Flutter 持久化，不通过 configure 发送。

## 托盘与本地状态

托盘至少提供显示、启停、撤销、退出。创建图标成功才允许 closeToTray 隐藏主窗口。托盘操作必须使用与界面相同服务/撤销逻辑，并让状态可读回。关闭进程需清理监听、定时器和待执行几何任务。

## 验证隔离

登录项写入、配置文件、记忆文件须支持隔离验证。测试不得写真实 Windows Run 或真实 macOS 13+ SMAppService 登录项，不得向用户已有第三方窗口注入事件。受控原生测试和真实物理输入人工验证分开记录。
