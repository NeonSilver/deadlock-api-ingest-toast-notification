Set WshShell = CreateObject("WScript.Shell")

args = ""
For Each arg In WScript.Arguments
  args = args & " " & arg
Next

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
      """" & CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\ingest-notify.ps1" & """" & args

WshShell.Run cmd, 0, False
