Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "D:\Desktop\DSH\feiyu-desktop"
sh.Run """C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""D:\Desktop\DSH\feiyu-desktop\FeiyuMoodDesktop.ps1""", 0, False