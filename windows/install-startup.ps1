# install-startup.ps1 — Configure claude-usage-widget to start automatically at login
# Run this once to set up auto-start. Run with -Remove to uninstall.
#
# Two methods available:
#   1. Startup folder shortcut (default) — simple, visible in shell:startup
#   2. Scheduled Task (-UseScheduledTask) — runs at logon, survives startup folder cleanup

param(
    [switch]$Remove,
    [switch]$UseScheduledTask
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbsPath = Join-Path $scriptDir "launch-widget.vbs"
$taskName = "ClaudeUsageWidget"

if ($Remove) {
    # Remove startup shortcut
    $startupDir = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupDir "Claude Usage Widget.lnk"
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "[OK] Removed startup shortcut: $shortcutPath" -ForegroundColor Green
    }
    # Remove scheduled task
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "[OK] Removed scheduled task: $taskName" -ForegroundColor Green
        }
    } catch {}
    Write-Host "Auto-start removed." -ForegroundColor Cyan
    exit 0
}

if (-not (Test-Path $vbsPath)) {
    Write-Host "[ERROR] launch-widget.vbs not found at: $vbsPath" -ForegroundColor Red
    Write-Host "Make sure this script is in the same folder as launch-widget.vbs" -ForegroundColor Yellow
    exit 1
}

if ($UseScheduledTask) {
    # Method 2: Scheduled Task
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    } catch {}

    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Claude Code Usage Widget (auto-start at login)" | Out-Null

    Write-Host "[OK] Scheduled task '$taskName' created." -ForegroundColor Green
    Write-Host "The widget will start automatically at next login." -ForegroundColor Cyan
} else {
    # Method 1: Startup folder shortcut (default)
    $startupDir = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupDir "Claude Usage Widget.lnk"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.Description = "Claude Code Usage Widget"
    $shortcut.Save()

    Write-Host "[OK] Startup shortcut created: $shortcutPath" -ForegroundColor Green
    Write-Host "The widget will start automatically at next login." -ForegroundColor Cyan
    Write-Host "To remove: run this script with -Remove" -ForegroundColor DarkGray
}
