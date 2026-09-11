' open-ui.vbs - ip-switch Windows 桌面入口（零窗口）
'
' 作用：通过 WScript.Shell 用 WindowStyle=0 调用同目录的 open-ui.mjs，
'       整条链路（wscript → node → cmd start → server.cjs）无任何可见窗口。
'       适合：桌面快捷方式、外行用户双击、文件管理器右键"打开方式"。
'
' 用法：
'   双击运行                  → 打开默认全功能表单 config-form.html
'   wscript open-ui.vbs aws   → 打开 AWS 配置页
'   wscript open-ui.vbs azure → 打开 Azure 配置页
'   wscript open-ui.vbs oci   → 打开 OCI 配置页
'   wscript open-ui.vbs vultr → 打开 Vultr 配置页
'
' 设计：
'   - 自动启用 --quiet：open-ui.mjs 把 [INFO]/[OK] 写 <install-dir>/data/open-ui.log，
'     stderr 干净（即使有人把 vbs 改成 console 模式调用也仍然没噪音）
'   - WindowStyle = 0  → 完全隐藏（不是最小化）
'   - bWaitOnReturn = False → 不阻塞 vbs 调用者（双击立即返回，浏览器异步打开）
'   - 不创建快捷方式 → 用户想桌面图标可自行「右键 → 发送到 → 桌面快捷方式」

Option Explicit

Dim shell, fso
Dim scriptPath, mjsPath, page, command

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' 同目录的 open-ui.mjs（与本 vbs 文件放一起）
scriptPath = WScript.ScriptFullName
mjsPath    = fso.BuildPath(fso.GetParentFolderName(scriptPath), "open-ui.mjs")

' 收集用户传入的参数（最多 1 个：页面名或 --status/--stop 等）
page = ""
If WScript.Arguments.Count > 0 Then
    page = " " & WScript.Arguments(0)
End If

' 在路径里的 \ 转义成 \\ 给 VBScript 的 Shell.Run 字符串解析用
'（vbscript 的 " 包裹路径是允许 \\ 转义的；cmd 看到 \\ 还原成 \）
command = "node """ & Replace(mjsPath, "\", "\\") & """ --quiet --open" & page

' WindowStyle = 0（隐藏），False（不等待）
shell.Run command, 0, False

' 显式释放 COM 对象，避免某些 Windows 版本 wscript 进程驻留
Set shell = Nothing
Set fso   = Nothing