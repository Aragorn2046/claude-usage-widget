# claude-usage-widget.ps1
# Persistent desktop widget — retro-terminal aesthetic
# REQUIRES: Windows PowerShell 5.1+ (WPF — not supported in PowerShell Core/pwsh)
# REQUIRES: Claude Code CLI authenticated (creates ~/.claude/.credentials.json)
# OPTIONAL: outage-alert.mp3 in same folder for audible outage alerts
# LAUNCH:   powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File usage-widget.ps1
#
# Right-click: context menu (Lock/Unlock, Refresh, Close). ESC to close.
# Resizable when unlocked — content scales via ViewBox. Position/size/lock persists.
# System metrics refresh every 3s; usage + outage status refresh every 60s.

#Requires -Version 5.1
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

# ── Credentials & Token ──────────────────────────────────────────────────────
$credPath = "$env:USERPROFILE\.claude\.credentials.json"
# WSL credentials path (Claude Code /login writes here; widget reads Windows path)
# Auto-detect WSL distro name
$wslCredPath = $null
try {
    $wslDistros = @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() -replace "`0","" } | Where-Object { $_ -ne "" })
    foreach ($distro in $wslDistros) {
        $candidate = "\\wsl.localhost\$distro\home\$($env:USERNAME.ToLower())\.claude\.credentials.json"
        if (Test-Path $candidate) { $wslCredPath = $candidate; break }
    }
} catch {}
# Claude Code's public OAuth client ID (ships with every Claude Code install)
$clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

function Sync-WslCreds {
    # If WSL credentials are newer than Windows, copy them over
    if (Test-Path $script:wslCredPath) {
        $wslTime = (Get-Item $script:wslCredPath).LastWriteTimeUtc
        $winExists = Test-Path $script:credPath
        if (-not $winExists -or $wslTime -gt (Get-Item $script:credPath).LastWriteTimeUtc) {
            try {
                Copy-Item $script:wslCredPath $script:credPath -Force
            } catch {}
        }
    }
}

function Load-Creds {
    Sync-WslCreds
    if (-not (Test-Path $script:credPath)) { return $null }
    return Get-Content $script:credPath -Raw | ConvertFrom-Json
}

function Refresh-Token($creds) {
    $refreshToken = $creds.claudeAiOauth.refreshToken
    if (-not $refreshToken) { return $null }
    try {
        $body = @{
            grant_type    = "refresh_token"
            refresh_token = $refreshToken
            client_id     = $script:clientId
        }
        $resp = Invoke-RestMethod `
            -Uri         "https://console.anthropic.com/v1/oauth/token" `
            -Method      POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body        $body `
            -ErrorAction Stop

        $creds.claudeAiOauth.accessToken  = $resp.access_token
        $creds.claudeAiOauth.refreshToken = $resp.refresh_token
        $creds.claudeAiOauth.expiresAt    = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeMilliseconds()
        $creds | ConvertTo-Json -Depth 10 | Set-Content $script:credPath -Encoding UTF8
        return $resp.access_token
    } catch { return $null }
}

function Get-Token {
    $creds = Load-Creds
    if (-not $creds) { return @{ token = $null; sub = "UNKNOWN"; error = "NO CREDENTIALS FOUND" } }
    $token   = $creds.claudeAiOauth.accessToken
    $subType = if ($creds.claudeAiOauth.subscriptionType) { $creds.claudeAiOauth.subscriptionType } else { "UNKNOWN" }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($creds.claudeAiOauth.expiresAt -and $nowMs -ge $creds.claudeAiOauth.expiresAt) {
        $token = Refresh-Token $creds
        if (-not $token) { return @{ token = $null; sub = $subType; error = "TOKEN EXPIRED" } }
    }
    return @{ token = $token; sub = $subType; error = $null }
}

function Fetch-Usage($accessToken) {
    $headers = @{
        "Authorization"  = "Bearer $accessToken"
        "Accept"         = "application/json"
        "User-Agent"     = "claude-usage-widget/1.0"
    }
    return Invoke-RestMethod `
        -Uri     "https://api.anthropic.com/api/oauth/usage" `
        -Headers $headers -Method GET -TimeoutSec 15 -ErrorAction Stop
}

function Get-UsageData {
    $tokenInfo = Get-Token
    if ($tokenInfo.error) { return @{ error = $tokenInfo.error; sub = $tokenInfo.sub } }
    try {
        $resp = Fetch-Usage $tokenInfo.token
    } catch {
        $sc = 0; try { $sc = $_.Exception.Response.StatusCode.value__ } catch {}
        if ($sc -eq 401 -or $sc -eq 429) {
            if ($sc -eq 429) { Start-Sleep -Seconds 3 }
            $creds = Load-Creds
            $newToken = Refresh-Token $creds
            if ($newToken) {
                try { $resp = Fetch-Usage $newToken }
                catch { return @{ error = "LINK FAILURE"; sub = $tokenInfo.sub } }
            } elseif ($sc -eq 429) {
                Start-Sleep -Seconds 3
                try { $resp = Fetch-Usage $tokenInfo.token }
                catch { return @{ error = "RATE LIMITED"; sub = $tokenInfo.sub } }
            } else { return @{ error = "AUTH FAILURE"; sub = $tokenInfo.sub } }
        } else { return @{ error = "LINK FAILURE"; sub = $tokenInfo.sub } }
    }
    try {
        $now = [DateTime]::Now
        $fiveHourPct = [math]::Round($resp.five_hour.utilization, 1)
        $sevenDayPct = [math]::Round($resp.seven_day.utilization, 1)

        $fiveReset = [DateTimeOffset]::Parse($resp.five_hour.resets_at).LocalDateTime
        $fiveDiff  = $fiveReset - $now
        $fiveResetStr = if ($fiveDiff.TotalSeconds -le 0) { "NOW" }
                        elseif ($fiveDiff.TotalMinutes -lt 60) { "$([math]::Round($fiveDiff.TotalMinutes))M" }
                        else { "$([math]::Round($fiveDiff.TotalHours, 1))H" }

        $sevenResetStr = ""
        if ($resp.seven_day) {
            $sevenReset = [DateTimeOffset]::Parse($resp.seven_day.resets_at).LocalDateTime
            $sevenDiff  = $sevenReset - $now
            $sevenResetStr = if ($sevenDiff.TotalSeconds -le 0) { "NOW" }
                             elseif ($sevenDiff.TotalMinutes -lt 60) { "$([math]::Round($sevenDiff.TotalMinutes))M" }
                             elseif ($sevenDiff.TotalHours -lt 24) { "$([math]::Round($sevenDiff.TotalHours, 1))H" }
                             else { "$([math]::Round($sevenDiff.TotalDays, 1))D" }
        }
        return @{
            error = $null; sub = $tokenInfo.sub
            fivePct = $fiveHourPct; sevenPct = $sevenDayPct
            fiveReset = $fiveResetStr; sevenReset = $sevenResetStr
        }
    } catch {
        return @{ error = "PARSE ERROR"; sub = $tokenInfo.sub }
    }
}

# ── Settings persistence ─────────────────────────────────────────────────────
$settingsPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "usage-widget-settings.json"

function Load-Settings {
    $defaults = @{ Left = $null; Top = $null; Width = 520; Height = 580; Locked = $false; BgOpacity = 50; ShowBorder = $true; RetroLook = $false }
    if (Test-Path $script:settingsPath) {
        try {
            $saved = Get-Content $script:settingsPath -Raw | ConvertFrom-Json
            if ($null -ne $saved.Left)   { $defaults.Left   = $saved.Left }
            if ($null -ne $saved.Top)    { $defaults.Top    = $saved.Top }
            if ($null -ne $saved.Width)  { $defaults.Width  = $saved.Width }
            if ($null -ne $saved.Height) { $defaults.Height = $saved.Height }
            if ($null -ne $saved.Locked) { $defaults.Locked = $saved.Locked }
            if ($null -ne $saved.BgOpacity) { $defaults.BgOpacity = $saved.BgOpacity }
            if ($null -ne $saved.ShowBorder) { $defaults.ShowBorder = $saved.ShowBorder }
            if ($null -ne $saved.RetroLook) { $defaults.RetroLook = $saved.RetroLook }
        } catch {}
    }
    return $defaults
}

function Save-Settings {
    $s = @{
        Left   = [math]::Round($window.Left, 0)
        Top    = [math]::Round($window.Top, 0)
        Width  = [math]::Round($window.Width, 0)
        Height = [math]::Round($window.Height, 0)
        Locked = $script:isLocked
        BgOpacity = $script:bgOpacity
        ShowBorder = $script:showBorder
        RetroLook = $script:retroLook
    }
    $s | ConvertTo-Json | Set-Content $script:settingsPath -Encoding UTF8
}

$settings = Load-Settings

# ── Build WPF Window ─────────────────────────────────────────────────────────
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" Height="580" MinWidth="320" MinHeight="200"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="False"
        ShowInTaskbar="False" ResizeMode="CanResizeWithGrip"
        Left="20" Top="20">
    <Border x:Name="OuterBorder" Background="#80080C10" CornerRadius="2" Margin="6"
            BorderBrush="#8830D158" BorderThickness="1.5">
        <Border.Effect>
            <DropShadowEffect BlurRadius="20" Opacity="0.5" ShadowDepth="2" Color="#0A1A0A"/>
        </Border.Effect>
        <Grid>
            <Viewbox x:Name="ContentViewbox" Stretch="Uniform" StretchDirection="Both">
            <StackPanel Margin="24 18 24 20" Width="900">

                <!-- ═══ HEADER BAR ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <!-- Logo/Brand -->
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="&#x25C8;" Foreground="#30D158" FontSize="28"
                                   FontFamily="Consolas" Margin="0 0 8 0" VerticalAlignment="Center"/>
                        <TextBlock Text="ANTHROPIC" Foreground="#30D158" FontSize="32"
                                   FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"
                                   />
                    </StackPanel>

                    <!-- Classification -->
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Background="#1830D158" BorderBrush="#4430D158" BorderThickness="1"
                                CornerRadius="1" Padding="8 2">
                            <TextBlock x:Name="SubLabel" Text="MAX" Foreground="#30D158"
                                       FontSize="22" FontWeight="Bold" FontFamily="Consolas"
                                       />
                        </Border>
                    </StackPanel>
                </Grid>

                <!-- Divider -->
                <Border Height="1" Background="#3330D158" Margin="0 8 0 14"/>

                <!-- ═══ SYSTEM LABEL ═══ -->
                <TextBlock Text="RESOURCE UTILIZATION MONITOR" Foreground="#AA30D158"
                           FontSize="20" FontFamily="Consolas" Margin="0 0 0 14"
                           />

                <!-- ═══ 5-HOUR READOUT ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <TextBlock Text="5H CYCLE" Foreground="#CC30D158" FontSize="26"
                               FontFamily="Consolas" FontWeight="Bold" Width="200"
                               VerticalAlignment="Center"/>

                    <!-- Bar track -->
                    <Border Background="#15309958" CornerRadius="1" Height="28"
                            Margin="8 0 12 0" Grid.Column="1" VerticalAlignment="Center"
                            BorderBrush="#3330D158" BorderThickness="1">
                        <Border x:Name="FiveBar" Background="#30D158" Width="0"
                                CornerRadius="0" HorizontalAlignment="Left"/>
                    </Border>

                    <TextBlock x:Name="FiveLabel" Text="0.0%" Foreground="#30D158"
                               FontSize="18" FontWeight="Bold" FontFamily="Consolas"
                               Grid.Column="2" Width="100" TextAlignment="Right"
                               VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="FiveReset" Text="RESET: --" Foreground="#8830D158"
                           FontSize="22" FontFamily="Consolas" Margin="200 0 0 16"/>

                <!-- ═══ 7-DAY READOUT ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <TextBlock Text="7D CYCLE" Foreground="#CC30D158" FontSize="26"
                               FontFamily="Consolas" FontWeight="Bold" Width="200"
                               VerticalAlignment="Center"/>

                    <Border Background="#15309958" CornerRadius="1" Height="16"
                            Margin="8 0 12 0" Grid.Column="1" VerticalAlignment="Center"
                            BorderBrush="#3330D158" BorderThickness="1">
                        <Border x:Name="SevenBar" Background="#30D158" Width="0"
                                CornerRadius="0" HorizontalAlignment="Left"/>
                    </Border>

                    <TextBlock x:Name="SevenLabel" Text="0.0%" Foreground="#30D158"
                               FontSize="18" FontWeight="Bold" FontFamily="Consolas"
                               Grid.Column="2" Width="80" TextAlignment="Right"
                               VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="SevenReset" Text="RESET: --" Foreground="#8830D158"
                           FontSize="22" FontFamily="Consolas" Margin="200 0 0 12"/>

                <!-- ═══ SYSTEM METRICS DIVIDER ═══ -->
                <Border Height="1" Background="#2230D158" Margin="0 4 0 10"/>
                <TextBlock Text="SYSTEM METRICS" Foreground="#AA30D158"
                           FontSize="20" FontFamily="Consolas" Margin="0 0 0 12"/>

                <!-- ═══ CPU READOUT ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="CPU" Foreground="#CC30D158" FontSize="26"
                               FontFamily="Consolas" FontWeight="Bold" Width="200"
                               VerticalAlignment="Center"/>
                    <Border Background="#15309958" CornerRadius="1" Height="28"
                            Margin="8 0 12 0" Grid.Column="1" VerticalAlignment="Center"
                            BorderBrush="#3330D158" BorderThickness="1">
                        <Border x:Name="CpuBar" Background="#30D158" Width="0"
                                CornerRadius="0" HorizontalAlignment="Left"/>
                    </Border>
                    <TextBlock x:Name="CpuLabel" Text="--%" Foreground="#30D158"
                               FontSize="18" FontWeight="Bold" FontFamily="Consolas"
                               Grid.Column="2" Width="100" TextAlignment="Right"
                               VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="CpuDetail" Text="TEMP: --" Foreground="#8830D158"
                           FontSize="22" FontFamily="Consolas" Margin="200 0 0 10"/>

                <!-- ═══ RAM READOUT ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="RAM" Foreground="#CC30D158" FontSize="26"
                               FontFamily="Consolas" FontWeight="Bold" Width="200"
                               VerticalAlignment="Center"/>
                    <Border Background="#15309958" CornerRadius="1" Height="28"
                            Margin="8 0 12 0" Grid.Column="1" VerticalAlignment="Center"
                            BorderBrush="#3330D158" BorderThickness="1">
                        <Border x:Name="RamBar" Background="#30D158" Width="0"
                                CornerRadius="0" HorizontalAlignment="Left"/>
                    </Border>
                    <TextBlock x:Name="RamLabel" Text="--%" Foreground="#30D158"
                               FontSize="18" FontWeight="Bold" FontFamily="Consolas"
                               Grid.Column="2" Width="100" TextAlignment="Right"
                               VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="RamDetail" Text="0/0 GB" Foreground="#8830D158"
                           FontSize="22" FontFamily="Consolas" Margin="200 0 0 10"/>

                <!-- ═══ GPU READOUT ═══ -->
                <Grid Margin="0 0 0 4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="GPU" Foreground="#CC30D158" FontSize="26"
                               FontFamily="Consolas" FontWeight="Bold" Width="200"
                               VerticalAlignment="Center"/>
                    <Border Background="#15309958" CornerRadius="1" Height="28"
                            Margin="8 0 12 0" Grid.Column="1" VerticalAlignment="Center"
                            BorderBrush="#3330D158" BorderThickness="1">
                        <Border x:Name="GpuBar" Background="#30D158" Width="0"
                                CornerRadius="0" HorizontalAlignment="Left"/>
                    </Border>
                    <TextBlock x:Name="GpuLabel" Text="--%" Foreground="#30D158"
                               FontSize="18" FontWeight="Bold" FontFamily="Consolas"
                               Grid.Column="2" Width="100" TextAlignment="Right"
                               VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="GpuDetail" Text="TEMP: --" Foreground="#8830D158"
                           FontSize="22" FontFamily="Consolas" Margin="200 0 0 12"/>

                <!-- ═══ DISK READOUTS (dynamic — one bar per fixed drive) ═══ -->
                <StackPanel x:Name="DiskPanel" Margin="0 0 0 0"/>

                <!-- ═══ OUTAGE STATUS DIVIDER ═══ -->
                <Border Height="1" Background="#2230D158" Margin="0 4 0 10"/>
                <TextBlock Text="OUTAGE STATUS" Foreground="#AA30D158"
                           FontSize="20" FontFamily="Consolas" Margin="0 0 0 10"/>

                <!-- ═══ OUTAGE STATUS INDICATORS ═══ -->
                <Grid Margin="0 0 0 12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- AI (claude.ai) -->
                    <Border Grid.Column="0" Background="#10309958" BorderBrush="#3330D158"
                            BorderThickness="1" CornerRadius="1" Padding="8 6" Margin="0 0 6 0">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Border x:Name="StatusAi" Background="#5530D158" Width="12" Height="12"
                                    CornerRadius="0" Margin="0 0 8 0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="StatusAiLabel" Text="AI" Foreground="#CC30D158"
                                       FontSize="20" FontWeight="Bold" FontFamily="Consolas"
                                       VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>

                    <!-- PLATFORM -->
                    <Border Grid.Column="1" Background="#10309958" BorderBrush="#3330D158"
                            BorderThickness="1" CornerRadius="1" Padding="8 6" Margin="0 0 6 0">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Border x:Name="StatusPlatform" Background="#5530D158" Width="12" Height="12"
                                    CornerRadius="0" Margin="0 0 8 0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="StatusPlatformLabel" Text="PLATFORM" Foreground="#CC30D158"
                                       FontSize="20" FontWeight="Bold" FontFamily="Consolas"
                                       VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>

                    <!-- API -->
                    <Border Grid.Column="2" Background="#10309958" BorderBrush="#3330D158"
                            BorderThickness="1" CornerRadius="1" Padding="8 6" Margin="0 0 6 0">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Border x:Name="StatusApi" Background="#5530D158" Width="12" Height="12"
                                    CornerRadius="0" Margin="0 0 8 0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="StatusApiLabel" Text="API" Foreground="#CC30D158"
                                       FontSize="20" FontWeight="Bold" FontFamily="Consolas"
                                       VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>

                    <!-- CODE -->
                    <Border Grid.Column="3" Background="#10309958" BorderBrush="#3330D158"
                            BorderThickness="1" CornerRadius="1" Padding="8 6">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Border x:Name="StatusCode" Background="#5530D158" Width="12" Height="12"
                                    CornerRadius="0" Margin="0 0 8 0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="StatusCodeLabel" Text="CODE" Foreground="#CC30D158"
                                       FontSize="20" FontWeight="Bold" FontFamily="Consolas"
                                       VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- Divider -->
                <Border Height="1" Background="#2230D158" Margin="0 4 0 10"/>

                <!-- ═══ STATUS BAR ═══ -->
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal">
                        <Border x:Name="StatusDot" Background="#30D158" Width="14" Height="14"
                                CornerRadius="0" Margin="0 0 8 0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="StatusText" Text="LINK ACTIVE" Foreground="#AA30D158"
                                   FontSize="20" FontFamily="Consolas" VerticalAlignment="Center"/>
                    </StackPanel>

                    <TextBlock x:Name="TimeStamp" Text="" Foreground="#7730D158"
                               FontSize="20" FontFamily="Consolas" Grid.Column="2"
                               VerticalAlignment="Center"/>
                </Grid>

                <!-- Error -->
                <TextBlock x:Name="ErrorLabel" Text="" Foreground="#D14030"
                           FontSize="22" FontWeight="Bold" FontFamily="Consolas"
                           TextWrapping="Wrap" Margin="0 8 0 0" Visibility="Collapsed"/>

                <!-- Motto -->
                <TextBlock Text="Building better worlds." Foreground="#4430D158"
                           FontSize="16" FontStyle="Italic" FontFamily="Consolas"
                           HorizontalAlignment="Center" Margin="0 12 0 0"/>

            </StackPanel>
            </Viewbox>

            <!-- Scanline overlay (must be AFTER Viewbox for correct Z-order) -->
            <Border x:Name="ScanlineOverlay" Opacity="0.03" IsHitTestVisible="False">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,3" SpreadMethod="Repeat"
                                         MappingMode="Absolute">
                        <GradientStop Color="#00000000" Offset="0"/>
                        <GradientStop Color="#00000000" Offset="0.5"/>
                        <GradientStop Color="#20000000" Offset="0.5"/>
                        <GradientStop Color="#20000000" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
        </Grid>
    </Border>
</Window>
"@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Named elements
$statusDot  = $window.FindName("StatusDot")
$statusText = $window.FindName("StatusText")
$timeStamp  = $window.FindName("TimeStamp")
$subLabel   = $window.FindName("SubLabel")
$fiveBar    = $window.FindName("FiveBar")
$fiveLabel  = $window.FindName("FiveLabel")
$fiveReset  = $window.FindName("FiveReset")
$sevenBar   = $window.FindName("SevenBar")
$sevenLabel = $window.FindName("SevenLabel")
$sevenReset = $window.FindName("SevenReset")
$errorLabel = $window.FindName("ErrorLabel")
$cpuBar     = $window.FindName("CpuBar")
$cpuLabel   = $window.FindName("CpuLabel")
$cpuDetail  = $window.FindName("CpuDetail")
$ramBar     = $window.FindName("RamBar")
$ramLabel   = $window.FindName("RamLabel")
$ramDetail  = $window.FindName("RamDetail")
$gpuBar     = $window.FindName("GpuBar")
$gpuLabel   = $window.FindName("GpuLabel")
$gpuDetail  = $window.FindName("GpuDetail")
$statusAi           = $window.FindName("StatusAi")
$statusAiLabel      = $window.FindName("StatusAiLabel")
$statusPlatform     = $window.FindName("StatusPlatform")
$statusPlatformLabel = $window.FindName("StatusPlatformLabel")
$statusApi          = $window.FindName("StatusApi")
$statusApiLabel     = $window.FindName("StatusApiLabel")
$statusCode         = $window.FindName("StatusCode")
$statusCodeLabel    = $window.FindName("StatusCodeLabel")
$diskPanel          = $window.FindName("DiskPanel")
$outerBorder        = $window.FindName("OuterBorder")
$scanlineOverlay    = $window.FindName("ScanlineOverlay")
$contentViewbox     = $window.FindName("ContentViewbox")

$barMaxWidth = 520

# ── Appearance state ─────────────────────────────────────────────────────────
$script:bgOpacity  = $settings.BgOpacity
$script:showBorder = $settings.ShowBorder
$script:retroLook  = $settings.RetroLook

function Apply-Appearance {
    $bc = [System.Windows.Media.BrushConverter]::new()
    # Background: #080C10 with variable alpha (0-100% → 0x00-0xFF)
    $alpha = [math]::Round($script:bgOpacity * 255 / 100)
    $alphaHex = '{0:X2}' -f [int][math]::Min(255, [math]::Max(0, $alpha))
    $outerBorder.Background = $bc.ConvertFrom("#${alphaHex}080C10")
    # Border
    if ($script:showBorder) {
        $outerBorder.BorderBrush = $bc.ConvertFrom("#8830D158")
        $outerBorder.BorderThickness = [System.Windows.Thickness]::new(1.5)
    } else {
        $outerBorder.BorderBrush = $bc.ConvertFrom("#00000000")
        $outerBorder.BorderThickness = [System.Windows.Thickness]::new(0)
    }
    # Retro Look — phosphor glow + visible CRT scanlines
    if ($script:retroLook) {
        # Scanlines: 3px repeat — top half transparent, bottom half dark.
        # Overlay at full opacity; scanline darkness controlled by gradient alpha.
        $scanlineOverlay.Opacity = 1.0
        $grad = New-Object System.Windows.Media.LinearGradientBrush
        $grad.StartPoint = [System.Windows.Point]::new(0, 0)
        $grad.EndPoint   = [System.Windows.Point]::new(0, 3)
        $grad.SpreadMethod  = [System.Windows.Media.GradientSpreadMethod]::Repeat
        $grad.MappingMode   = [System.Windows.Media.BrushMappingMode]::Absolute
        $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
            [System.Windows.Media.Color]::FromArgb(0, 0, 0, 0), 0.0))
        $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
            [System.Windows.Media.Color]::FromArgb(0, 0, 0, 0), 0.5))
        $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
            [System.Windows.Media.Color]::FromArgb(50, 0, 0, 0), 0.5))
        $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
            [System.Windows.Media.Color]::FromArgb(50, 0, 0, 0), 1.0))
        $scanlineOverlay.Background = $grad
        # Phosphor glow
        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.ShadowDepth = 0
        $glow.BlurRadius = 8
        $glow.Color = [System.Windows.Media.Color]::FromRgb(0x30, 0xD1, 0x58)
        $glow.Opacity = 0.45
        $contentViewbox.Effect = $glow
    } else {
        # Restore subtle default scanlines
        $scanlineOverlay.Opacity = 0.03
        $contentViewbox.Effect = $null
    }
}

# ── Outage alert sound ───────────────────────────────────────────────────────
$script:alertSoundPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "outage-alert.mp3"
$script:prevOutage = @{ ai = "operational"; platform = "operational"; api = "operational"; code = "operational" }
$script:lastGoodUsage = $null
$script:alertPlayer = New-Object System.Windows.Media.MediaPlayer

function Get-WYColor($pct) {
    if ($pct -lt 50)  { return @{ bar = "#30D158"; text = "#30D158" } }  # green
    elseif ($pct -lt 80) { return @{ bar = "#D1A830"; text = "#D1A830" } }  # amber
    else { return @{ bar = "#D14030"; text = "#D14030" } }  # red
}

function Get-TempColor($temp) {
    if ($null -eq $temp -or $temp -eq "N/A") { return "#8830D158" }
    if ($temp -lt 60) { return "#30D158" }
    elseif ($temp -le 80) { return "#D1A830" }
    else { return "#D14030" }
}

function Get-SystemMetrics {
    $metrics = @{
        cpuPct = 0; cpuTemp = "N/A"
        ramPct = 0; ramUsedGB = 0; ramTotalGB = 0
        gpuPct = 0; gpuTemp = "N/A"
    }

    # CPU Usage (true all-core average via performance counter)
    try {
        $sample = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue
        $metrics.cpuPct = [math]::Round($sample, 0)
    } catch {
        try {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -ExpandProperty LoadPercentage
            if ($cpu -is [array]) { $cpu = ($cpu | Measure-Object -Average).Average }
            $metrics.cpuPct = [math]::Round($cpu, 0)
        } catch { $metrics.cpuPct = 0 }
    }

    # CPU Temperature (4 methods: Performance Counter → WMI ACPI → LHM WMI → LHM DLL)
    try {
        $samples = (Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop).CounterSamples
        $temps = $samples | Where-Object { $_.CookedValue -gt 200 } | ForEach-Object { $_.CookedValue - 273.15 }
        if ($temps) {
            $avgTemp = ($temps | Measure-Object -Average).Average
            $metrics.cpuTemp = [math]::Round($avgTemp, 0)
        }
    } catch {
        try {
            $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
            if ($tz) {
                $kelvin = if ($tz -is [array]) { ($tz | Measure-Object -Property CurrentTemperature -Average).Average } else { $tz.CurrentTemperature }
                $metrics.cpuTemp = [math]::Round(($kelvin / 10) - 273.15, 0)
            }
        } catch {
            try {
                $lhm = Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -ErrorAction Stop |
                    Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Core' -and $_.Value -gt 0 }
                if ($lhm) {
                    $avgTemp = ($lhm | Measure-Object -Property Value -Average).Average
                    $metrics.cpuTemp = [math]::Round($avgTemp, 0)
                }
            } catch {
                try {
                    $lhmDll = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitorLib.dll'
                    if (Test-Path $lhmDll) {
                        Add-Type -Path $lhmDll -ErrorAction Stop
                        $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
                        $computer.IsCpuEnabled = $true
                        $computer.Open()
                        $cpuTemps = @()
                        foreach ($hw in $computer.Hardware) {
                            $hw.Update()
                            foreach ($sensor in $hw.Sensors) {
                                if ($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $sensor.Value) {
                                    $cpuTemps += $sensor.Value
                                }
                            }
                        }
                        if ($cpuTemps.Count -gt 0) { $metrics.cpuTemp = [math]::Round(($cpuTemps | Measure-Object -Average).Average, 0) }
                        $computer.Close()
                    }
                } catch { $metrics.cpuTemp = "N/A" }
            }
        }
    }

    # RAM Usage
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalKB = $os.TotalVisibleMemorySize
        $freeKB  = $os.FreePhysicalMemory
        $usedKB  = $totalKB - $freeKB
        $metrics.ramTotalGB = [math]::Round($totalKB / 1MB, 0)
        $metrics.ramUsedGB  = [math]::Round($usedKB / 1MB, 0)
        $metrics.ramPct     = [math]::Round(($usedKB / $totalKB) * 100, 0)
    } catch {}

    # GPU Usage + Temperature (NVIDIA)
    try {
        $nvsmi = & nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($nvsmi) {
            $parts = $nvsmi.Trim().Split(',')
            $metrics.gpuPct  = [math]::Round([double]$parts[0].Trim(), 0)
            $metrics.gpuTemp = [math]::Round([double]$parts[1].Trim(), 0)
        }
    } catch { $metrics.gpuPct = 0; $metrics.gpuTemp = "N/A" }

    # Disk Usage (all fixed local drives)
    $metrics.disks = @()
    try {
        $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
        foreach ($d in $drives) {
            $totalGB = [math]::Round($d.Size / 1GB, 0)
            $freeGB  = [math]::Round($d.FreeSpace / 1GB, 0)
            $usedGB  = $totalGB - $freeGB
            $pct     = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
            $metrics.disks += @{ letter = $d.DeviceID.TrimEnd(':'); pct = $pct; usedGB = $usedGB; totalGB = $totalGB }
        }
    } catch { $metrics.disks = @() }

    return $metrics
}

function Get-OutageStatus {
    $result = @{ ai = "unknown"; platform = "unknown"; api = "unknown"; code = "unknown" }
    # Component IDs from https://status.claude.com/api/v2/components.json
    $idMap = @{
        "rwppv331jlwc" = "ai"        # claude.ai
        "0qbwn08sd68x" = "platform"  # platform.claude.com
        "k8w3r06qmzrp" = "api"       # Claude API
        "yyzkbfz2thpt" = "code"      # Claude Code
    }
    try {
        $resp = Invoke-RestMethod -Uri "https://status.claude.com/api/v2/components.json" `
            -Method GET -ErrorAction Stop -TimeoutSec 10
        foreach ($comp in $resp.components) {
            if ($idMap.ContainsKey($comp.id)) {
                $result[$idMap[$comp.id]] = $comp.status
            }
        }
    } catch {}
    return $result
}

function Get-OutageColor($status) {
    switch ($status) {
        "operational"           { return "#30D158" }
        "degraded_performance"  { return "#D1A830" }
        "partial_outage"        { return "#D14030" }
        "major_outage"          { return "#D14030" }
        default                 { return "#5530D158" }
    }
}

function Update-SysMetrics($precomputed) {
    $bc = [System.Windows.Media.BrushConverter]::new()
    $sys = if ($precomputed) { $precomputed } else { Get-SystemMetrics }

    # CPU
    $cc = Get-WYColor $sys.cpuPct
    $cpuBar.Background   = $bc.ConvertFrom($cc.bar)
    $cpuBar.Width        = [math]::Max(2, [math]::Round($barMaxWidth * [math]::Min($sys.cpuPct, 100) / 100))
    $cpuLabel.Text       = "$($sys.cpuPct)%"
    $cpuLabel.Foreground = $bc.ConvertFrom($cc.text)
    $cpuTempStr = if ($sys.cpuTemp -eq "N/A") { "N/A" } else { "$($sys.cpuTemp)$([char]176)C" }
    $cpuDetail.Text       = "TEMP: $cpuTempStr"
    $cpuDetail.Foreground = $bc.ConvertFrom((Get-TempColor $sys.cpuTemp))

    # RAM
    $rc = Get-WYColor $sys.ramPct
    $ramBar.Background   = $bc.ConvertFrom($rc.bar)
    $ramBar.Width        = [math]::Max(2, [math]::Round($barMaxWidth * [math]::Min($sys.ramPct, 100) / 100))
    $ramLabel.Text       = "$($sys.ramPct)%"
    $ramLabel.Foreground = $bc.ConvertFrom($rc.text)
    $ramDetail.Text       = "$($sys.ramUsedGB)/$($sys.ramTotalGB) GB"
    $ramDetail.Foreground = $bc.ConvertFrom($rc.text)

    # GPU
    $gc = Get-WYColor $sys.gpuPct
    $gpuBar.Background   = $bc.ConvertFrom($gc.bar)
    $gpuBar.Width        = [math]::Max(2, [math]::Round($barMaxWidth * [math]::Min($sys.gpuPct, 100) / 100))
    $gpuLabel.Text       = "$($sys.gpuPct)%"
    $gpuLabel.Foreground = $bc.ConvertFrom($gc.text)
    $gpuTempStr = if ($sys.gpuTemp -eq "N/A") { "N/A" } else { "$($sys.gpuTemp)$([char]176)C" }
    $gpuDetail.Text       = "TEMP: $gpuTempStr"
    $gpuDetail.Foreground = $bc.ConvertFrom((Get-TempColor $sys.gpuTemp))

    # Disks (dynamic — one bar per fixed drive)
    $diskPanel.Children.Clear()
    foreach ($disk in $sys.disks) {
        $dc = Get-WYColor $disk.pct

        # Bar row: 3-column Grid (label | bar track | percentage)
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = [System.Windows.Thickness]::new(0,0,0,4)
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = "Auto"
        $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = "*"
        $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = "Auto"
        $grid.ColumnDefinitions.Add($col1)
        $grid.ColumnDefinitions.Add($col2)
        $grid.ColumnDefinitions.Add($col3)

        # Drive letter label
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "$($disk.letter):"
        $lbl.Foreground = $bc.ConvertFrom("#CC30D158")
        $lbl.FontSize = 26; $lbl.FontFamily = "Consolas"; $lbl.FontWeight = "Bold"
        $lbl.Width = 200; $lbl.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $grid.Children.Add($lbl) | Out-Null

        # Bar track + fill
        $track = New-Object System.Windows.Controls.Border
        $track.Background = $bc.ConvertFrom("#15309958")
        $track.CornerRadius = [System.Windows.CornerRadius]::new(1)
        $track.Height = 28
        $track.Margin = [System.Windows.Thickness]::new(8,0,12,0)
        $track.VerticalAlignment = "Center"
        $track.BorderBrush = $bc.ConvertFrom("#3330D158")
        $track.BorderThickness = [System.Windows.Thickness]::new(1)
        [System.Windows.Controls.Grid]::SetColumn($track, 1)
        $bar = New-Object System.Windows.Controls.Border
        $bar.Background = $bc.ConvertFrom($dc.bar)
        $bar.Width = [math]::Max(2, [math]::Round($barMaxWidth * [math]::Min($disk.pct, 100) / 100))
        $bar.CornerRadius = [System.Windows.CornerRadius]::new(0)
        $bar.HorizontalAlignment = "Left"
        $track.Child = $bar
        $grid.Children.Add($track) | Out-Null

        # Percentage label
        $pctLbl = New-Object System.Windows.Controls.TextBlock
        $pctLbl.Text = "$($disk.pct)%"
        $pctLbl.Foreground = $bc.ConvertFrom($dc.text)
        $pctLbl.FontSize = 18; $pctLbl.FontWeight = "Bold"; $pctLbl.FontFamily = "Consolas"
        $pctLbl.Width = 100; $pctLbl.TextAlignment = "Right"; $pctLbl.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($pctLbl, 2)
        $grid.Children.Add($pctLbl) | Out-Null

        $diskPanel.Children.Add($grid) | Out-Null

        # Detail line: used/total GB
        $detail = New-Object System.Windows.Controls.TextBlock
        $detail.Text = "$($disk.usedGB)/$($disk.totalGB) GB"
        $detail.Foreground = $bc.ConvertFrom($dc.text)
        $detail.FontSize = 22; $detail.FontFamily = "Consolas"
        $detail.Margin = [System.Windows.Thickness]::new(200,0,0,10)
        $diskPanel.Children.Add($detail) | Out-Null
    }
}

function Update-Widget($preUsage, $preOutage) {
    $bc = [System.Windows.Media.BrushConverter]::new()
    $data = if ($preUsage) { $preUsage } else { Get-UsageData }

    $subDisplay = switch -Wildcard ($data.sub.ToLower()) {
        "*max*"  { "MAX" }
        "*pro*"  { "PRO" }
        "*team*" { "TEAM" }
        default  { $data.sub.ToUpper() }
    }
    $subLabel.Text = $subDisplay
    $timeStamp.Text = [DateTime]::Now.ToString("HH:mm:ss")

    $displayData = $null
    if ($data.error) {
        if ($script:lastGoodUsage) {
            $displayData = $script:lastGoodUsage
            $statusDot.Background  = $bc.ConvertFrom("#D1A830")
            $statusText.Text = "RETRYING"
            $statusText.Foreground = $bc.ConvertFrom("#AAD1A830")
            $errorLabel.Visibility = "Collapsed"
        } else {
            $errorLabel.Text = ">> ERROR: $($data.error)"
            $errorLabel.Visibility = "Visible"
            $statusDot.Background  = $bc.ConvertFrom("#D14030")
            $statusText.Text = "LINK FAILURE"
            $statusText.Foreground = $bc.ConvertFrom("#AAD14030")
        }
    } else {
        $displayData = $data
        $script:lastGoodUsage = $data
        $errorLabel.Visibility = "Collapsed"
        $statusDot.Background  = $bc.ConvertFrom("#30D158")
        $statusText.Text = "LINK ACTIVE"
        $statusText.Foreground = $bc.ConvertFrom("#AA30D158")
    }

    if ($displayData) {
        # 5-hour
        $fc = Get-WYColor $displayData.fivePct
        $fiveBrush = $bc.ConvertFrom($fc.bar)
        $fiveBar.Background   = $fiveBrush
        $fiveBar.Width        = [math]::Max(2, [math]::Round($barMaxWidth * [math]::Min($displayData.fivePct, 100) / 100))
        $fiveLabel.Text       = "$($displayData.fivePct)%"
        $fiveLabel.Foreground = $bc.ConvertFrom($fc.text)
        $fiveReset.Text       = "RESET: $($displayData.fiveReset)"

        # 7-day
        $sc = Get-WYColor $displayData.sevenPct
        $sevenBrush = $bc.ConvertFrom($sc.bar)
        $sevenBar.Background   = $sevenBrush
        $sevenBar.Width        = [math]::Max(0, [math]::Round($barMaxWidth * [math]::Min($displayData.sevenPct, 100) / 100))
        $sevenLabel.Text       = "$($displayData.sevenPct)%"
        $sevenLabel.Foreground = $bc.ConvertFrom($sc.text)
        $sevenReset.Text       = "RESET: $($displayData.sevenReset)"
    }

    # ── Outage Status ──
    $outage = if ($preOutage) { $preOutage } else { Get-OutageStatus }
    $statusAi.Background       = $bc.ConvertFrom((Get-OutageColor $outage.ai))
    $statusPlatform.Background = $bc.ConvertFrom((Get-OutageColor $outage.platform))
    $statusApi.Background      = $bc.ConvertFrom((Get-OutageColor $outage.api))
    $statusCode.Background     = $bc.ConvertFrom((Get-OutageColor $outage.code))

    # Play alert on new outage (transition from operational/unknown to degraded/outage)
    $badStates = @("degraded_performance", "partial_outage", "major_outage")
    $newOutage = $false
    foreach ($key in @("ai", "platform", "api", "code")) {
        $prev = $script:prevOutage[$key]
        $curr = $outage[$key]
        if ($curr -in $badStates -and $prev -notin $badStates) {
            $newOutage = $true
        }
    }
    $script:prevOutage = $outage
    if ($newOutage -and (Test-Path $script:alertSoundPath)) {
        $script:alertPlayer.Open([Uri]::new($script:alertSoundPath))
        $script:alertPlayer.Volume = 1.0
        $script:alertPlayer.Play()
    }
}

# ── Lock state ───────────────────────────────────────────────────────────────
$script:isLocked = $settings.Locked

function Apply-LockState {
    if ($script:isLocked) {
        $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $lockMenuItem.Header = "UNLOCK"
    } else {
        $window.ResizeMode = [System.Windows.ResizeMode]::CanResizeWithGrip
        $lockMenuItem.Header = "LOCK"
    }
}

# ── Context Menu ─────────────────────────────────────────────────────────────
$menuStyle = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       TargetType="ContextMenu">
    <Setter Property="Background" Value="#F0080C10"/>
    <Setter Property="BorderBrush" Value="#8830D158"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="#30D158"/>
    <Setter Property="FontFamily" Value="Consolas"/>
    <Setter Property="FontSize" Value="13"/>
</Style>
"@
$menuItemStyle = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       TargetType="MenuItem">
    <Setter Property="Foreground" Value="#30D158"/>
    <Setter Property="FontFamily" Value="Consolas"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Padding" Value="12 6"/>
</Style>
"@

$ctxMenuStyleObj = [System.Windows.Markup.XamlReader]::Parse($menuStyle)
$ctxItemStyleObj = [System.Windows.Markup.XamlReader]::Parse($menuItemStyle)

$ctxMenu = New-Object System.Windows.Controls.ContextMenu
$ctxMenu.Style = $ctxMenuStyleObj

$lockMenuItem = New-Object System.Windows.Controls.MenuItem
$lockMenuItem.Header = if ($script:isLocked) { "UNLOCK" } else { "LOCK" }
$lockMenuItem.Style = $ctxItemStyleObj
$lockMenuItem.Add_Click({
    $script:isLocked = -not $script:isLocked
    Apply-LockState
    Save-Settings
})

$restartMenuItem = New-Object System.Windows.Controls.MenuItem
$restartMenuItem.Header = "REFRESH"
$restartMenuItem.Style = $ctxItemStyleObj
$restartMenuItem.Add_Click({ Update-SysMetrics; Update-Widget })

$relinkMenuItem = New-Object System.Windows.Controls.MenuItem
$relinkMenuItem.Header = "RELINK"
$relinkMenuItem.Style = $ctxItemStyleObj
$relinkMenuItem.Add_Click({
    $bc = [System.Windows.Media.BrushConverter]::new()
    $statusText.Text = "RELINKING"
    $statusText.Foreground = $bc.ConvertFrom("#AAD1A830")
    $statusDot.Background  = $bc.ConvertFrom("#D1A830")
    # Force sync from WSL
    Sync-WslCreds
    # Force token refresh with the new credentials
    $creds = Load-Creds
    if ($creds) {
        $newToken = Refresh-Token $creds
    }
    # Now fetch — run in background to avoid blocking UI
    $script:usageTicks = 60
})

$restartWidgetMenuItem = New-Object System.Windows.Controls.MenuItem
$restartWidgetMenuItem.Header = "RESTART"
$restartWidgetMenuItem.Style = $ctxItemStyleObj
$restartWidgetMenuItem.Add_Click({
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) { $scriptPath = Join-Path (Split-Path -Parent $script:settingsPath) "usage-widget.ps1" }
    Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $window.Close()
})

$closeMenuItem = New-Object System.Windows.Controls.MenuItem
$closeMenuItem.Header = "CLOSE"
$closeMenuItem.Style = $ctxItemStyleObj
$closeMenuItem.Add_Click({ $window.Close() })

# Opacity slider menu item
$opacityMenuItem = New-Object System.Windows.Controls.MenuItem
$opacityMenuItem.Style = $ctxItemStyleObj
$opacityMenuItem.Header = "OPACITY"
$opacityMenuItem.StaysOpenOnClick = $true
$opacityPanel = New-Object System.Windows.Controls.StackPanel
$opacityPanel.Orientation = "Horizontal"
$opacityPanel.Margin = [System.Windows.Thickness]::new(0,4,0,4)
$opacitySlider = New-Object System.Windows.Controls.Slider
$opacitySlider.Minimum = 0
$opacitySlider.Maximum = 100
$opacitySlider.Value = $script:bgOpacity
$opacitySlider.Width = 140
$opacitySlider.VerticalAlignment = "Center"
$opacitySlider.IsSnapToTickEnabled = $true
$opacitySlider.TickFrequency = 1
$script:opacityValueLabel = New-Object System.Windows.Controls.TextBlock
$script:opacityValueLabel.Text = "$($script:bgOpacity)%"
$script:opacityValueLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#30D158")
$script:opacityValueLabel.FontFamily = "Consolas"
$script:opacityValueLabel.FontSize = 12
$script:opacityValueLabel.Width = 36
$script:opacityValueLabel.TextAlignment = "Right"
$script:opacityValueLabel.VerticalAlignment = "Center"
$script:opacityValueLabel.Margin = [System.Windows.Thickness]::new(6,0,0,0)
$opacitySlider.Add_ValueChanged({
    $script:bgOpacity = [math]::Round($opacitySlider.Value)
    $script:opacityValueLabel.Text = "$($script:bgOpacity)%"
    Apply-Appearance
    Save-Settings
})
$opacityPanel.Children.Add($opacitySlider) | Out-Null
$opacityPanel.Children.Add($script:opacityValueLabel) | Out-Null
$opacitySubItem = New-Object System.Windows.Controls.MenuItem
$opacitySubItem.Header = $opacityPanel
$opacitySubItem.StaysOpenOnClick = $true
$opacityMenuItem.Items.Add($opacitySubItem) | Out-Null

# Border toggle menu item
$borderMenuItem = New-Object System.Windows.Controls.MenuItem
$borderMenuItem.Header = if ($script:showBorder) { "BORDER: ON" } else { "BORDER: OFF" }
$borderMenuItem.Style = $ctxItemStyleObj
$borderMenuItem.Add_Click({
    $script:showBorder = -not $script:showBorder
    $borderMenuItem.Header = if ($script:showBorder) { "BORDER: ON" } else { "BORDER: OFF" }
    Apply-Appearance
    Save-Settings
})

# Retro Look toggle menu item
$retroMenuItem = New-Object System.Windows.Controls.MenuItem
$retroMenuItem.Header = if ($script:retroLook) { "RETRO: ON" } else { "RETRO: OFF" }
$retroMenuItem.Style = $ctxItemStyleObj
$retroMenuItem.Add_Click({
    $script:retroLook = -not $script:retroLook
    $retroMenuItem.Header = if ($script:retroLook) { "RETRO: ON" } else { "RETRO: OFF" }
    Apply-Appearance
    Save-Settings
})

$ctxMenu.Items.Add($lockMenuItem) | Out-Null
$ctxMenu.Items.Add($restartMenuItem) | Out-Null
$ctxMenu.Items.Add($relinkMenuItem) | Out-Null
$ctxMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null
$ctxMenu.Items.Add($opacityMenuItem) | Out-Null
$ctxMenu.Items.Add($borderMenuItem) | Out-Null
$ctxMenu.Items.Add($retroMenuItem) | Out-Null
$ctxMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null
$ctxMenu.Items.Add($restartWidgetMenuItem) | Out-Null
$ctxMenu.Items.Add($closeMenuItem) | Out-Null

# ── Window behavior ──────────────────────────────────────────────────────────
$window.Add_MouseLeftButtonDown({
    if (-not $script:isLocked) { $window.DragMove() }
})
$window.Add_KeyDown({ param($s, $e); if ($e.Key -eq 'Escape') { $window.Close() } })
$window.Add_MouseRightButtonDown({
    param($s, $e)
    $ctxMenu.IsOpen = $true
    $e.Handled = $true
})
$window.Add_Loaded({
    Apply-LockState
    Apply-Appearance
    Update-SysMetrics
    Update-Widget
})

# ── Background runspace pool (keeps UI thread free) ──────────────────────────
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 4)
$runspacePool.Open()

# Self-contained script for system metrics (runs in background runspace)
$script:sysMetricsScript = @'
$metrics = @{
    cpuPct = 0; cpuTemp = "N/A"
    ramPct = 0; ramUsedGB = 0; ramTotalGB = 0
    gpuPct = 0; gpuTemp = "N/A"
    disks = @()
}
try {
    $sample = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue
    $metrics.cpuPct = [math]::Round($sample, 0)
} catch {
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -ExpandProperty LoadPercentage
        if ($cpu -is [array]) { $cpu = ($cpu | Measure-Object -Average).Average }
        $metrics.cpuPct = [math]::Round($cpu, 0)
    } catch { $metrics.cpuPct = 0 }
}
try {
    $samples = (Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop).CounterSamples
    $temps = $samples | Where-Object { $_.CookedValue -gt 200 } | ForEach-Object { $_.CookedValue - 273.15 }
    if ($temps) { $metrics.cpuTemp = [math]::Round(($temps | Measure-Object -Average).Average, 0) }
} catch {
    try {
        $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        if ($tz) {
            $kelvin = if ($tz -is [array]) { ($tz | Measure-Object -Property CurrentTemperature -Average).Average } else { $tz.CurrentTemperature }
            $metrics.cpuTemp = [math]::Round(($kelvin / 10) - 273.15, 0)
        }
    } catch {
        try {
            $lhm = Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -ErrorAction Stop |
                Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Core' -and $_.Value -gt 0 }
            if ($lhm) { $metrics.cpuTemp = [math]::Round(($lhm | Measure-Object -Property Value -Average).Average, 0) }
        } catch {
            try {
                $lhmDll = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitorLib.dll'
                if (Test-Path $lhmDll) {
                    Add-Type -Path $lhmDll -ErrorAction Stop
                    $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
                    $computer.IsCpuEnabled = $true
                    $computer.Open()
                    $cpuTemps = @()
                    foreach ($hw in $computer.Hardware) {
                        $hw.Update()
                        foreach ($sensor in $hw.Sensors) {
                            if ($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $sensor.Value) {
                                $cpuTemps += $sensor.Value
                            }
                        }
                    }
                    if ($cpuTemps.Count -gt 0) { $metrics.cpuTemp = [math]::Round(($cpuTemps | Measure-Object -Average).Average, 0) }
                    $computer.Close()
                }
            } catch { $metrics.cpuTemp = "N/A" }
        }
    }
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalKB = $os.TotalVisibleMemorySize; $freeKB = $os.FreePhysicalMemory; $usedKB = $totalKB - $freeKB
    $metrics.ramTotalGB = [math]::Round($totalKB / 1MB, 0)
    $metrics.ramUsedGB  = [math]::Round($usedKB / 1MB, 0)
    $metrics.ramPct     = [math]::Round(($usedKB / $totalKB) * 100, 0)
} catch {}
try {
    $nvsmi = & nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null
    if ($nvsmi) {
        $parts = $nvsmi.Trim().Split(',')
        $metrics.gpuPct  = [math]::Round([double]$parts[0].Trim(), 0)
        $metrics.gpuTemp = [math]::Round([double]$parts[1].Trim(), 0)
    }
} catch { $metrics.gpuPct = 0; $metrics.gpuTemp = "N/A" }
try {
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    foreach ($d in $drives) {
        $totalGB = [math]::Round($d.Size / 1GB, 0); $freeGB = [math]::Round($d.FreeSpace / 1GB, 0)
        $usedGB = $totalGB - $freeGB
        $pct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
        $metrics.disks += @{ letter = $d.DeviceID.TrimEnd(':'); pct = $pct; usedGB = $usedGB; totalGB = $totalGB }
    }
} catch { $metrics.disks = @() }
return $metrics
'@

# Self-contained script for usage + outage (runs in background runspace)
$script:usageOutageScript = @'
param($credPath, $clientId, $wslCredPath)
function Refresh-TokenBg($creds) {
    $rt = $creds.claudeAiOauth.refreshToken; if (-not $rt) { return $null }
    try {
        $body = @{ grant_type = "refresh_token"; refresh_token = $rt; client_id = $clientId }
        $resp = Invoke-RestMethod -Uri "https://console.anthropic.com/v1/oauth/token" -Method POST -ContentType "application/x-www-form-urlencoded" -Body $body -ErrorAction Stop
        $creds.claudeAiOauth.accessToken = $resp.access_token
        $creds.claudeAiOauth.refreshToken = $resp.refresh_token
        $creds.claudeAiOauth.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeMilliseconds()
        $creds | ConvertTo-Json -Depth 10 | Set-Content $credPath -Encoding UTF8
        return $resp.access_token
    } catch { return $null }
}
# Sync WSL credentials if newer
if ($wslCredPath -and (Test-Path $wslCredPath)) {
    $wslTime = (Get-Item $wslCredPath).LastWriteTimeUtc
    if (-not (Test-Path $credPath) -or $wslTime -gt (Get-Item $credPath).LastWriteTimeUtc) {
        try { Copy-Item $wslCredPath $credPath -Force } catch {}
    }
}
$unknownOutage = @{ ai = "unknown"; platform = "unknown"; api = "unknown"; code = "unknown" }
if (-not (Test-Path $credPath)) {
    return @{ usage = @{ error = "NO CREDENTIALS FOUND"; sub = "UNKNOWN" }; outage = $unknownOutage }
}
$creds = Get-Content $credPath -Raw | ConvertFrom-Json
$token = $creds.claudeAiOauth.accessToken
$subType = if ($creds.claudeAiOauth.subscriptionType) { $creds.claudeAiOauth.subscriptionType } else { "UNKNOWN" }
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($creds.claudeAiOauth.expiresAt -and $nowMs -ge $creds.claudeAiOauth.expiresAt) {
    $token = Refresh-TokenBg $creds
    if (-not $token) { return @{ usage = @{ error = "TOKEN EXPIRED"; sub = $subType }; outage = $unknownOutage } }
}
$headers = @{ "Authorization" = "Bearer $token"; "Accept" = "application/json"; "User-Agent" = "claude-usage-widget/1.0" }
$usageData = $null
try {
    $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method GET -TimeoutSec 15 -ErrorAction Stop
} catch {
    $sc = 0; try { $sc = $_.Exception.Response.StatusCode.value__ } catch {}
    if ($sc -eq 401 -or $sc -eq 429) {
        if ($sc -eq 429) { Start-Sleep -Seconds 3 }
        $newToken = Refresh-TokenBg $creds
        if ($newToken) {
            $headers["Authorization"] = "Bearer $newToken"
            try { $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method GET -TimeoutSec 15 -ErrorAction Stop }
            catch { $usageData = @{ error = "LINK FAILURE"; sub = $subType } }
        } elseif ($sc -eq 429) {
            Start-Sleep -Seconds 3
            try { $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method GET -TimeoutSec 15 -ErrorAction Stop }
            catch { $usageData = @{ error = "RATE LIMITED"; sub = $subType } }
        } else { $usageData = @{ error = "AUTH FAILURE"; sub = $subType } }
    } else { $usageData = @{ error = "LINK FAILURE"; sub = $subType } }
}
if (-not $usageData) {
    try {
        $now = [DateTime]::Now
        $fiveHourPct = [math]::Round($resp.five_hour.utilization, 1)
        $sevenDayPct = [math]::Round($resp.seven_day.utilization, 1)
        $fiveReset = [DateTimeOffset]::Parse($resp.five_hour.resets_at).LocalDateTime
        $fiveDiff = $fiveReset - $now
        $fiveResetStr = if ($fiveDiff.TotalSeconds -le 0) { "NOW" } elseif ($fiveDiff.TotalMinutes -lt 60) { "$([math]::Round($fiveDiff.TotalMinutes))M" } else { "$([math]::Round($fiveDiff.TotalHours, 1))H" }
        $sevenResetStr = ""
        if ($resp.seven_day) {
            $sevenReset = [DateTimeOffset]::Parse($resp.seven_day.resets_at).LocalDateTime
            $sevenDiff = $sevenReset - $now
            $sevenResetStr = if ($sevenDiff.TotalSeconds -le 0) { "NOW" } elseif ($sevenDiff.TotalMinutes -lt 60) { "$([math]::Round($sevenDiff.TotalMinutes))M" } elseif ($sevenDiff.TotalHours -lt 24) { "$([math]::Round($sevenDiff.TotalHours, 1))H" } else { "$([math]::Round($sevenDiff.TotalDays, 1))D" }
        }
        $usageData = @{ error = $null; sub = $subType; fivePct = $fiveHourPct; sevenPct = $sevenDayPct; fiveReset = $fiveResetStr; sevenReset = $sevenResetStr }
    } catch {
        $usageData = @{ error = "PARSE ERROR"; sub = $subType }
    }
}
$outageData = @{ ai = "unknown"; platform = "unknown"; api = "unknown"; code = "unknown" }
$idMap = @{ "rwppv331jlwc" = "ai"; "0qbwn08sd68x" = "platform"; "k8w3r06qmzrp" = "api"; "yyzkbfz2thpt" = "code" }
try {
    $statusResp = Invoke-RestMethod -Uri "https://status.claude.com/api/v2/components.json" -Method GET -ErrorAction Stop -TimeoutSec 10
    foreach ($comp in $statusResp.components) {
        if ($idMap.ContainsKey($comp.id)) { $outageData[$idMap[$comp.id]] = $comp.status }
    }
} catch {}
return @{ usage = $usageData; outage = $outageData }
'@

# Background job tracking
$script:sysJob = $null
$script:usageJob = $null
$script:sysTicks = 0
$script:usageTicks = 0

# Save settings on close + cleanup runspaces
$window.Add_Closing({
    Save-Settings
    $pollTimer.Stop()
    if ($script:sysJob)   { try { $script:sysJob.PS.Stop(); $script:sysJob.PS.Dispose() } catch {} }
    if ($script:usageJob) { try { $script:usageJob.PS.Stop(); $script:usageJob.PS.Dispose() } catch {} }
    $runspacePool.Close()
})

# Debounced save on move/resize (avoids disk thrash during drag)
$saveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$saveTimer.Add_Tick({ $saveTimer.Stop(); Save-Settings })
$window.Add_LocationChanged({ $saveTimer.Stop(); $saveTimer.Start() })
$window.Add_SizeChanged({ $saveTimer.Stop(); $saveTimer.Start() })

# ── Async poll timer — checks for completed background jobs (every 1s) ──────
$pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pollTimer.Interval = [TimeSpan]::FromSeconds(1)
$pollTimer.Add_Tick({
    $script:sysTicks++
    $script:usageTicks++

    # Check sys metrics job completion
    if ($script:sysJob -and $script:sysJob.Handle.IsCompleted) {
        try {
            $result = $script:sysJob.PS.EndInvoke($script:sysJob.Handle)
            if ($result -and $result.Count -gt 0) { Update-SysMetrics $result[0] }
        } catch {} finally {
            $script:sysJob.PS.Dispose()
            $script:sysJob = $null
        }
    }

    # Check usage+outage job completion
    if ($script:usageJob -and $script:usageJob.Handle.IsCompleted) {
        try {
            $result = $script:usageJob.PS.EndInvoke($script:usageJob.Handle)
            if ($result -and $result.Count -gt 0) {
                Update-Widget $result[0].usage $result[0].outage
            }
        } catch {} finally {
            $script:usageJob.PS.Dispose()
            $script:usageJob = $null
        }
    }

    # Start sys metrics job every 3s (if not already running)
    if ($script:sysTicks -ge 3 -and -not $script:sysJob) {
        $script:sysTicks = 0
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        $ps.AddScript($script:sysMetricsScript) | Out-Null
        $script:sysJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    # Start usage+outage job every 60s (if not already running)
    if ($script:usageTicks -ge 60 -and -not $script:usageJob) {
        $script:usageTicks = 0
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        $ps.AddScript($script:usageOutageScript).AddArgument($credPath).AddArgument($clientId).AddArgument($wslCredPath) | Out-Null
        $script:usageJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
})
$pollTimer.Start()

# Position: load saved or default to bottom-right
$window.Add_ContentRendered({
    if ($null -ne $settings.Left -and $null -ne $settings.Top) {
        $window.Left = $settings.Left
        $window.Top  = $settings.Top
        if ($settings.Width -gt 0) { $window.Width = $settings.Width }
        if ($settings.Height -gt 0) { $window.Height = $settings.Height }
    } else {
        $screen = [System.Windows.SystemParameters]::WorkArea
        $window.Left = $screen.Right - $window.ActualWidth - 10
        $window.Top  = $screen.Bottom - $window.ActualHeight - 10
    }
})

[void]$window.ShowDialog()
