' launch-widget.vbs — Silent launcher for claude-usage-widget
' Starts the widget with zero visible windows (no PowerShell console flash)
' Usage: double-click, or add to shell:startup for auto-start at login
'
' This uses WScript.Shell Run with vbHide flag (0) to ensure
' the PowerShell process starts completely hidden — no flash, no taskbar entry.

Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
widgetScript = scriptDir & "\usage-widget.ps1"

' Verify the widget script exists
If Not CreateObject("Scripting.FileSystemObject").FileExists(widgetScript) Then
    MsgBox "Widget script not found: " & widgetScript, vbExclamation, "Claude Usage Widget"
    WScript.Quit 1
End If

' Launch PowerShell completely hidden (0 = vbHide)
WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & widgetScript & """", 0, False
