Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "D:\Desktop\DSH\feiyu-desktop"
On Error Resume Next
sh.Run "cmd /c del /q ""D:\Desktop\DSH\feiyu-desktop\widget.stopped""", 0, True
On Error GoTo 0
sh.Run """C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""D:\Desktop\DSH\feiyu-desktop\FeiyuMoodDesktop.ps1""", 0, False
