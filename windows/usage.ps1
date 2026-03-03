# claude-usage.ps1
# Shows Claude.ai 5-hour and 7-day usage as percentages in a WPF popup.
# Reads OAuth token from Claude Code's credential file — no separate setup needed.
# Auto-refreshes the token if expired.
# Stream Deck: powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "<path>\usage.ps1"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

# ── Credentials ───────────────────────────────────────────────────────────────
$credPath = "$env:USERPROFILE\.claude\.credentials.json"

if (-not (Test-Path $credPath)) {
    [System.Windows.MessageBox]::Show(
        "Credentials not found.`nPlease log in via Claude Code first.",
        "Claude Usage", "OK", "Error") | Out-Null
    exit
}

$creds    = Get-Content $credPath -Raw | ConvertFrom-Json
$token    = $creds.claudeAiOauth.accessToken
$subType  = if ($creds.claudeAiOauth.subscriptionType) { $creds.claudeAiOauth.subscriptionType } else { "Claude" }

if (-not $token) {
    [System.Windows.MessageBox]::Show(
        "No access token found.`nPlease re-authenticate via Claude Code.",
        "Claude Usage", "OK", "Error") | Out-Null
    exit
}

# ── Token refresh ─────────────────────────────────────────────────────────────
$clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

function Refresh-Token {
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

        # Update in-memory values
        $script:token = $resp.access_token
        $creds.claudeAiOauth.accessToken  = $resp.access_token
        $creds.claudeAiOauth.refreshToken = $resp.refresh_token
        $creds.claudeAiOauth.expiresAt    = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeMilliseconds()

        # Persist updated credentials
        $creds | ConvertTo-Json -Depth 10 | Set-Content $credPath -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# Check if token is expired
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($creds.claudeAiOauth.expiresAt -and $nowMs -ge $creds.claudeAiOauth.expiresAt) {
    $refreshed = Refresh-Token
    if (-not $refreshed) {
        [System.Windows.MessageBox]::Show(
            "Token expired and refresh failed.`nPlease run Claude Code to re-authenticate.",
            "Claude Usage", "OK", "Error") | Out-Null
        exit
    }
}

# ── Fetch usage ───────────────────────────────────────────────────────────────
function Fetch-Usage($accessToken) {
    $headers = @{
        "Authorization"  = "Bearer $accessToken"
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

$fiveHourPct      = 0.0
$sevenDayPct      = 0.0
$fiveHourResetStr = "Unknown"
$sevenDayResetStr = "Unknown"
$errorMsg         = ""

try {
    $resp = Fetch-Usage $token
} catch {
    # If 401, try refreshing once
    if ($_.Exception.Response.StatusCode.value__ -eq 401) {
        $refreshed = Refresh-Token
        if ($refreshed) {
            try { $resp = Fetch-Usage $token }
            catch { $resp = $null; $errorMsg = $_.Exception.Message }
        } else {
            $errorMsg = "Token expired. Run Claude Code to re-auth."
        }
    } else {
        $errorMsg = $_.Exception.Message
    }
}

if ($resp) {
    try {
        $fiveHourPct = [math]::Round($resp.five_hour.utilization, 1)
        $sevenDayPct = [math]::Round($resp.seven_day.utilization, 1)

        $now = [DateTime]::Now

        # 5-hour reset label
        $fiveReset = [DateTimeOffset]::Parse($resp.five_hour.resets_at).LocalDateTime
        $fiveDiff  = $fiveReset - $now
        $fiveHourResetStr = if ($fiveDiff.TotalSeconds -le 0) { "Resetting now" }
                            elseif ($fiveDiff.TotalMinutes -lt 60) { "Resets in $([math]::Round($fiveDiff.TotalMinutes))m" }
                            else { "Resets in $([math]::Round($fiveDiff.TotalHours, 1))h" }

        # 7-day reset label
        if ($resp.seven_day) {
            $sevenReset = [DateTimeOffset]::Parse($resp.seven_day.resets_at).LocalDateTime
            $sevenDiff  = $sevenReset - $now
            $sevenDayResetStr = if ($sevenDiff.TotalSeconds -le 0) { "Resetting now" }
                                elseif ($sevenDiff.TotalMinutes -lt 60) { "Resets in $([math]::Round($sevenDiff.TotalMinutes))m" }
                                elseif ($sevenDiff.TotalHours -lt 24) { "Resets in $([math]::Round($sevenDiff.TotalHours, 1))h" }
                                else { "Resets in $([math]::Round($sevenDiff.TotalDays, 1))d" }
        }
    } catch {
        $errorMsg = "Failed to parse response: $($_.Exception.Message)"
    }
}

if ($errorMsg) {
    if ($errorMsg.Length -gt 120) { $errorMsg = $errorMsg.Substring(0, 120) + "..." }
    $errorMsg = $errorMsg -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Get-Color($pct) {
    if ($pct -lt 50) { "#A6E3A1" }      # green  (Catppuccin green)
    elseif ($pct -lt 80) { "#F9E2AF" }  # yellow (Catppuccin yellow)
    else { "#F38BA8" }                   # red    (Catppuccin red)
}

# Bar width: window 300 - border margin 20 - stackpanel margin 40 - pct col 50 - gap 8 = ~182
$barW   = 180
$fiveW  = [math]::Max(4, [math]::Round($barW * [math]::Min($fiveHourPct, 100) / 100))
$sevenW = [math]::Max(0, [math]::Round($barW * [math]::Min($sevenDayPct, 100) / 100))

$fiveColor  = Get-Color $fiveHourPct
$sevenColor = Get-Color $sevenDayPct

$subDisplay = switch -Wildcard ($subType.ToLower()) {
    "*max*"  { "Claude Max" }
    "*pro*"  { "Claude Pro" }
    "*team*" { "Claude Team" }
    default  { $subType }
}

# ── XAML ──────────────────────────────────────────────────────────────────────
if ($errorMsg) {
    $contentXaml = @"
            <Border Background="#3D1A1A" CornerRadius="6" Padding="12 8">
                <TextBlock Text="$errorMsg" Foreground="#F38BA8"
                           FontSize="11" FontFamily="Segoe UI" TextWrapping="Wrap"/>
            </Border>
"@
} else {
    $contentXaml = @"
            <!-- 5-Hour Window -->
            <TextBlock Text="5-HOUR WINDOW" Foreground="#585B70" FontSize="10"
                       FontFamily="Segoe UI" FontWeight="SemiBold" Margin="0 0 0 5"/>
            <Grid Margin="0 0 0 3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="50"/>
                </Grid.ColumnDefinitions>
                <Border Background="#313244" CornerRadius="3" Height="9" Margin="0 0 8 0"
                        VerticalAlignment="Center">
                    <Border Background="$fiveColor" Width="$fiveW"
                            CornerRadius="3" HorizontalAlignment="Left"/>
                </Border>
                <TextBlock Text="$fiveHourPct%" Foreground="$fiveColor"
                           FontSize="13" FontWeight="Bold" FontFamily="Segoe UI"
                           Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <TextBlock Text="$fiveHourResetStr" Foreground="#45475A"
                       FontSize="10" FontFamily="Segoe UI" Margin="0 0 0 16"/>

            <!-- 7-Day Window -->
            <TextBlock Text="7-DAY WINDOW" Foreground="#585B70" FontSize="10"
                       FontFamily="Segoe UI" FontWeight="SemiBold" Margin="0 0 0 5"/>
            <Grid Margin="0 0 0 3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="50"/>
                </Grid.ColumnDefinitions>
                <Border Background="#313244" CornerRadius="3" Height="9" Margin="0 0 8 0"
                        VerticalAlignment="Center">
                    <Border Background="$sevenColor" Width="$sevenW"
                            CornerRadius="3" HorizontalAlignment="Left"/>
                </Border>
                <TextBlock Text="$sevenDayPct%" Foreground="$sevenColor"
                           FontSize="13" FontWeight="Bold" FontFamily="Segoe UI"
                           Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <TextBlock Text="$sevenDayResetStr" Foreground="#45475A"
                       FontSize="10" FontFamily="Segoe UI"/>
"@
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="300" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True"
        WindowStartupLocation="CenterScreen">
    <Border Background="#1E1E2E" CornerRadius="12" Margin="10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="24" Opacity="0.55" ShadowDepth="5" Color="#000000"/>
        </Border.Effect>
        <StackPanel Margin="20 16 20 20">

            <!-- Header -->
            <Grid Margin="0 0 0 16">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#89B4FA" Width="8" Height="8"
                            CornerRadius="4" Margin="0 0 8 0" VerticalAlignment="Center"/>
                    <StackPanel>
                        <TextBlock Text="Claude Usage" Foreground="#CDD6F4"
                                   FontSize="14" FontWeight="Bold" FontFamily="Segoe UI"/>
                        <TextBlock Text="$subDisplay" Foreground="#6C7086"
                                   FontSize="10" FontFamily="Segoe UI"/>
                    </StackPanel>
                </StackPanel>
                <TextBlock Grid.Column="1" Text="ESC to close" Foreground="#45475A"
                           FontSize="9" FontFamily="Segoe UI" VerticalAlignment="Top"/>
            </Grid>

            $contentXaml

        </StackPanel>
    </Border>
</Window>
"@

# ── Show window ───────────────────────────────────────────────────────────────
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$window.Add_KeyDown({ param($s, $e); if ($e.Key -eq 'Escape') { $window.Close() } })
$window.Add_MouseLeftButtonDown({ $window.Close() })

$timer          = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(10)
$timer.Add_Tick({ $window.Close(); $timer.Stop() })
$timer.Start()

[void]$window.ShowDialog()
