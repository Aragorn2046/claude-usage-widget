# usage-monitor.ps1
# Runs silently in the background, writes usage % to text files every 60s.
# Outputs: usage-5h.txt (5-hour window) and usage-7d.txt (7-day window)
# Stream Deck "Text File Tools" plugin reads the files to show them on buttons.
#
# Start from Stream Deck (one-time):
#   powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "<path>\usage-monitor.ps1"
# Or add to Task Scheduler to start at login.

$credPath    = "$env:USERPROFILE\.claude\.credentials.json"
$outFile5h   = "$PSScriptRoot\usage-5h.txt"
$outFile7d   = "$PSScriptRoot\usage-7d.txt"
$clientId    = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$intervalSec = 60

# ── Prevent duplicate instances ───────────────────────────────────────────────
$mutex = [System.Threading.Mutex]::new($false, "Global\ClaudeUsageMonitor")
if (-not $mutex.WaitOne(0)) {
    exit
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Refresh-Token {
    $script:creds = Get-Content $credPath -Raw | ConvertFrom-Json
    $refreshToken = $creds.claudeAiOauth.refreshToken
    if (-not $refreshToken) { return $false }

    try {
        $body = @{
            grant_type    = "refresh_token"
            refresh_token = $refreshToken
            client_id     = $clientId
        }
        $resp = Invoke-RestMethod `
            -Uri         "https://console.anthropic.com/v1/oauth/token" `
            -Method      POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body        $body `
            -ErrorAction Stop

        $script:token = $resp.access_token
        $creds.claudeAiOauth.accessToken  = $resp.access_token
        $creds.claudeAiOauth.refreshToken = $resp.refresh_token
        $creds.claudeAiOauth.expiresAt    = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeMilliseconds()
        $creds | ConvertTo-Json -Depth 10 | Set-Content $credPath -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Fetch-Usage {
    $headers = @{
        "Authorization"  = "Bearer $script:token"
        "anthropic-beta" = "oauth-2025-04-20"
        "Accept"         = "application/json"
        "User-Agent"     = "claude-code/2.0.32"
    }
    return Invoke-RestMethod `
        -Uri     "https://api.anthropic.com/api/oauth/usage" `
        -Headers $headers `
        -Method  GET `
        -ErrorAction Stop
}

function Write-Both($text5h, $text7d) {
    [System.IO.File]::WriteAllText($outFile5h, $text5h)
    [System.IO.File]::WriteAllText($outFile7d, $text7d)
}

# ── Main loop ─────────────────────────────────────────────────────────────────
try {
    while ($true) {
        try {
            # Load / refresh creds
            if (-not (Test-Path $credPath)) {
                Write-Both "?" "?"
                Start-Sleep $intervalSec
                continue
            }

            $creds = Get-Content $credPath -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken

            # Refresh if expired
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($creds.claudeAiOauth.expiresAt -and $nowMs -ge $creds.claudeAiOauth.expiresAt) {
                if (-not (Refresh-Token)) {
                    Write-Both "?" "?"
                    Start-Sleep $intervalSec
                    continue
                }
            }

            # Fetch
            try {
                $resp = Fetch-Usage
            } catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 401) {
                    if (Refresh-Token) {
                        $resp = Fetch-Usage
                    } else {
                        Write-Both "?" "?"
                        Start-Sleep $intervalSec
                        continue
                    }
                } else { throw }
            }

            $pct5h = [math]::Round($resp.five_hour.utilization, 0)
            $pct7d = [math]::Round($resp.seven_day.utilization, 0)
            Write-Both "$pct5h%" "$pct7d%"

        } catch {
            Write-Both "ERR" "ERR"
        }

        Start-Sleep $intervalSec
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
