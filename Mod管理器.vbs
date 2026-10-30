' 启动 Mod 管理器（不弹黑框；启动失败会弹提示）
Option Explicit

Dim fso, sh, dir, ps1, code
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(dir, "mod-manager.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "找不到 mod-manager.ps1。" & vbCrLf & vbCrLf & _
           "请先把压缩包完整解压到一个文件夹里，再双击 Mod管理器.vbs。", 16, "Mod 管理器"
    WScript.Quit
End If

sh.CurrentDirectory = dir

On Error Resume Next
code = sh.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, True)
If Err.Number <> 0 Then
    MsgBox "启动失败：" & Err.Description & vbCrLf & vbCrLf & _
           "可以右键 mod-manager.ps1 → 使用 PowerShell 运行，看看具体报错。", 16, "Mod 管理器"
    Err.Clear
End If
On Error GoTo 0

If code <> 0 Then
    MsgBox "管理器异常退出（返回码 " & code & "）。" & vbCrLf & vbCrLf & _
           "常见原因：被杀毒软件拦了，或者压缩包没解压完整。" & vbCrLf & _
           "想看详细报错：右键 mod-manager.ps1 → 使用 PowerShell 运行。", 16, "Mod 管理器"
End If
