' AnyFloat launcher - starts the tool hidden (no console window)
' NOTE: keep this file ASCII-only and WITHOUT BOM, otherwise wscript fails with "Invalid character".
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\AnyFloat.ps1""", 0, False