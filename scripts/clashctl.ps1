#Requires -Version 5.1
<#
.SYNOPSIS
    Clash for Windows controller - lets an LLM start/stop/diagnose/switch proxy
    when connectivity to overseas servers is unstable.

.DESCRIPTION
    Read-only actions (status/nodes/test/auto/delay) are always safe, no side effects.
    Lifecycle actions (start/stop) have an anti-footgun guard:
      - start only writes an "opened by agent" marker when Clash was NOT running.
      - stop only really stops it when that marker exists, so it will never kill a
        Clash instance the user launched manually. Use -Force to override.

    NOTE: this file is intentionally pure ASCII. Windows PowerShell 5.1 reads
    files as ANSI(GBK) when there is no BOM, which corrupts non-ASCII literals.

.EXAMPLE
    .\clashctl.ps1 status
    .\clashctl.ps1 auto
    .\clashctl.ps1 start
    .\clashctl.ps1 nodes
    .\clashctl.ps1 switch GROUP NODE
    .\clashctl.ps1 test https://github.com
    .\clashctl.ps1 stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'start', 'stop', 'restart', 'nodes', 'switch', 'test', 'delay', 'auto',
                 'sysproxy', 'mode', 'run', 'explain')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$Target,

    [Parameter(Position = 2)]
    [string]$Node,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [switch]$Force,
    [switch]$AsJson,
    [int]$TimeoutSec = 10
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Proxy/node names are UTF-8. Without this, PS5.1 writes console output in the
# ANSI codepage (GBK here) and non-ASCII names come out mangled, which would make
# them unusable as arguments to the "switch" action.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

# ============================================================================
# Local Clash environment
# Loaded from ../clash-config.json (read as UTF-8 so non-ASCII paths survive on
# Windows PowerShell 5.1, which would otherwise decode them as ANSI/GBK).
# The in-code values below are ASCII-only fallbacks.
# ============================================================================
$cfgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'clash-config.json'
if (-not (Test-Path $cfgPath)) {
    throw "Config not found: $cfgPath"
}
$raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8
$script:Cfg = $raw | ConvertFrom-Json

# Expand %USERPROFILE% style tokens in MarkerFile
$script:Cfg.MarkerFile = [Environment]::ExpandEnvironmentVariables($script:Cfg.MarkerFile)

# ---------------------------------------------------------------------------
# CRITICAL: Clash for Windows regenerates the external-controller port on every
# launch (observed: 51490 -> 51428 -> ... after restarts) while keeping the
# secret stable. Two consequences:
#   1. A hard-coded port will always go stale, so live values are read from
#      Clash's own config.yaml and override the JSON snapshot.
#   2. During "start" the config.yaml still holds the PREVIOUS run's port until
#      Clash rewrites it, so the readiness loop must re-read the file every tick,
#      otherwise it polls a dead port forever and reports a false timeout.
# ---------------------------------------------------------------------------
$script:RuntimeSource = 'clash-config.json (fallback)'
$script:RuntimeYaml   = Join-Path $env:USERPROFILE '.config\clash\config.yaml'

function Update-RuntimeConfig {
    if (-not (Test-Path $script:RuntimeYaml)) { return }
    $ec = ''; $sc = ''; $mp = ''
    foreach ($line in (Get-Content -Path $script:RuntimeYaml -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if     ($line -match '^\s*external-controller\s*:\s*[''"]?([^\s''"]+)') { $ec = $Matches[1] }
        elseif ($line -match '^\s*secret\s*:\s*[''"]?([^\s''"]+)')             { $sc = $Matches[1] }
        elseif ($line -match '^\s*mixed-port\s*:\s*(\d+)')                     { $mp = $Matches[1] }
    }
    if ($ec) { $script:Cfg.ApiBase = "http://$ec"; $script:RuntimeSource = 'config.yaml (live)' }
    if ($sc) { $script:Cfg.ApiSecret = $sc }
    if ($mp) { $script:Cfg.MixedPort = [int]$mp }
    $script:ProxyUrl = "http://127.0.0.1:$($script:Cfg.MixedPort)"
}

Update-RuntimeConfig

$script:ProxyBackupFile = Join-Path $env:USERPROFILE '.config\clash\.agent-sysproxy'
$script:NoProxyList     = 'localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.cn'

# Resolve GUI path from the live process if the configured one is missing
if (-not (Test-Path $script:Cfg.GuiExe)) {
    $live = Get-Process -Name $script:Cfg.GuiProcess -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($live -and $live.Path) { $script:Cfg.GuiExe = $live.Path }
}

$ProxyUrl = "http://127.0.0.1:$($script:Cfg.MixedPort)"

# ============================================================================
# Helpers
# ============================================================================
function Write-Out {
    param($Data, [string]$Kind = 'object')
    if ($AsJson) { $Data | ConvertTo-Json -Depth 6; return }
    if ($Kind -eq 'lines') { $Data | ForEach-Object { Write-Output $_ }; return }
    $Data | Format-List | Out-String | Write-Output
}

function Test-CoreRunning {
    [bool](Get-Process -Name $script:Cfg.CoreProcess -ErrorAction SilentlyContinue)
}

# Plain TcpClient probe. Deliberately avoids Get-NetTCPConnection, which failed
# parameter validation in this environment (LocalPort bound as null).
function Test-PortOpen {
    param([int]$Port, [int]$WaitMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne($WaitMs)
        if ($ok) { $client.EndConnect($iar) }
        return [bool]$ok
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ApiAlive {
    param([int]$Timeout = 3)
    try {
        $null = Invoke-RestMethod -Uri "$($script:Cfg.ApiBase)/version" -Headers @{
            Authorization = "Bearer $($script:Cfg.ApiSecret)"
        } -TimeoutSec $Timeout -ErrorAction Stop
        return $true
    } catch { return $false }
}

# NOTE: deliberately not Invoke-RestMethod. In PS5.1 it decodes a response as
# ISO-8859-1 when the server omits charset, which turns UTF-8 node names into
# mojibake and makes them unusable as arguments to "switch". Reading raw bytes
# and decoding as UTF-8 keeps names intact.
function Invoke-ClashApi {
    param(
        [string]$Path,
        [string]$Method = 'Get',
        $Body,
        [int]$Timeout = 6
    )
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false          # never route the local control API via a proxy
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Authorization', "Bearer $($script:Cfg.ApiSecret)")
    $uri = "$($script:Cfg.ApiBase)$Path"
    try {
        if ($Method -eq 'Get') {
            $resp = $client.GetAsync($uri).GetAwaiter().GetResult()
        } elseif ($Method -eq 'Put') {
            $json = '{}'
            if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Compress) }
            $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $client.PutAsync($uri, $content).GetAwaiter().GetResult()
        } elseif ($Method -eq 'Patch') {
            $json = '{}'
            if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Compress) }
            $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
            # NOTE: [System.Net.Http.HttpMethod]::Patch resolves to $null on this
            # box's System.Net.Http, so the ctor throws "参数名: method". Build the
            # method from its string ctor instead - that always works.
            $pm = [System.Net.Http.HttpMethod]::new('PATCH')
            $req = [System.Net.Http.HttpRequestMessage]::new($pm, [uri]$uri)
            $req.Content = $content
            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        } else {
            throw "Unsupported method: $Method"
        }
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
        $resp.Dispose()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } finally {
        $client.Dispose(); $handler.Dispose()
    }
}

# HttpClient instead of Invoke-WebRequest: PS5.1 IWR cannot reliably bypass the
# system proxy, which is exactly what we need for the "direct" measurement.
function Measure-Url {
    param([string]$Url, [string]$Proxy)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($Proxy) {
        $handler.Proxy    = New-Object System.Net.WebProxy($Proxy, $true)
        $handler.UseProxy = $true
    } else {
        $handler.UseProxy = $false
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        $sw.Stop()
        return [PSCustomObject]@{
            ok = $true; code = [int]$resp.StatusCode; ms = [int]$sw.ElapsedMilliseconds; err = ''
        }
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{
            ok = $false; code = 0; ms = [int]$sw.ElapsedMilliseconds; err = $_.Exception.Message
        }
    } finally {
        $client.Dispose(); $handler.Dispose()
    }
}

function Wait-ApiReady {
    param([int]$Seconds = 35)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Update-RuntimeConfig          # port changes as soon as Clash rewrites config.yaml
        if (Test-ApiAlive -Timeout 2) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# ============================================================================
# System proxy (WinINet) control
# Enabling the system proxy is what makes GUI apps (browsers, Electron, IDE)
# actually use Clash. Combined with mode=rule it does NOT hurt domestic traffic:
# Clash sends CN domains/IPs direct and only overseas traffic goes to a node.
# ============================================================================
function Get-SysProxyState {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        enabled          = ($p.ProxyEnable -eq 1)
        server           = $p.ProxyServer
        managed_by_agent = (Test-Path $script:ProxyBackupFile)
    }
}

# WinINet caches proxy settings per-process; without this refresh, already-running
# apps (e.g. a browser) keep using the old setting until restarted.
function Invoke-SysProxyRefresh {
    $sig = @'
[DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
    try {
        $t = Add-Type -MemberDefinition $sig -Name 'WinInetRefresh' -Namespace 'ClashSkill' -PassThru -ErrorAction Stop
    } catch {
        $t = [ClashSkill.WinInetRefresh]
    }
    $null = $t::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # SETTINGS_CHANGED
    $null = $t::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # REFRESH
}

function Set-SysProxyState {
    param([switch]$On)
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($On) {
        if (-not (Test-Path $script:ProxyBackupFile)) {
            $cur = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
            $dir = Split-Path $script:ProxyBackupFile
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [PSCustomObject]@{
                ProxyEnable = [int]$cur.ProxyEnable
                ProxyServer = [string]$cur.ProxyServer
            } | ConvertTo-Json | Set-Content -Path $script:ProxyBackupFile -Encoding UTF8
        }
        $server = "127.0.0.1:$($script:Cfg.MixedPort)"
        Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1
        Set-ItemProperty -Path $reg -Name ProxyServer -Value $server
        Invoke-SysProxyRefresh
        return [PSCustomObject]@{
            sysproxy      = 'on'
            server        = $server
            note          = 'GUI apps now use Clash. With mode=rule, CN traffic still goes direct.'
        }
    }
    if (Test-Path $script:ProxyBackupFile) {
        $b = Get-Content -Path $script:ProxyBackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Set-ItemProperty -Path $reg -Name ProxyEnable -Value ([int]$b.ProxyEnable)
        if ($b.ProxyServer) { Set-ItemProperty -Path $reg -Name ProxyServer -Value ([string]$b.ProxyServer) }
        Remove-Item $script:ProxyBackupFile -Force -ErrorAction SilentlyContinue
        Invoke-SysProxyRefresh
        return [PSCustomObject]@{
            sysproxy    = 'off'
            restored    = $true
            proxy_enable= [int]$b.ProxyEnable
            note        = 'Restored the settings that existed before the agent enabled it.'
        }
    }
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0
    Invoke-SysProxyRefresh
    return [PSCustomObject]@{
        sysproxy = 'off'; restored = $false
        note     = 'No agent backup found; simply disabled. Your original state is unknown.'
    }
}

# ============================================================================
# Clash routing mode
#   rule   = split by rules: CN direct / overseas via node  <- what we want
#   global = everything through one node (hurts domestic sites)
#   direct = everything direct (proxy effectively off)
# ============================================================================
function Set-ClashMode {
    param([string]$Mode)
    $Mode = $Mode.ToLower()
    if (@('rule', 'global', 'direct') -notcontains $Mode) {
        throw "mode must be rule|global|direct"
    }
    Invoke-ClashApi -Path '/configs' -Method Patch -Body @{ mode = $Mode } | Out-Null
    $note = 'Split routing active: CN direct, overseas via node.'
    if ($Mode -eq 'global') { $note = 'ALL traffic goes through the node, including domestic sites.' }
    if ($Mode -eq 'direct') { $note = 'Clash forwards nothing; proxy effectively disabled.' }
    [PSCustomObject]@{ mode = $Mode; note = $note }
}

# ============================================================================
# Run one command line with proxy env vars (precise, zero leakage).
# Takes the WHOLE command line as a single string and hands it to cmd /c:
#   - a CmdletBinding script cannot forward args starting with "-" (they get
#     bound to its own parameters and blow up with "ambiguous parameter"),
#   - cmd /c inherits our environment, so the injected proxy vars are visible.
# Usage:  clashctl.ps1 run "curl -sS https://www.google.com"
# ============================================================================
function Invoke-WithProxy {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { throw 'Nothing to run.' }

    $keys = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
              'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
    $saved = @{}
    foreach ($k in $keys) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if ($null -ne $v) { $saved[$k] = $v }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exit = 0
    try {
        [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $ProxyUrl)
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $ProxyUrl)
        [Environment]::SetEnvironmentVariable('ALL_PROXY',   $ProxyUrl)
        [Environment]::SetEnvironmentVariable('http_proxy',  $ProxyUrl)
        [Environment]::SetEnvironmentVariable('https_proxy', $ProxyUrl)
        [Environment]::SetEnvironmentVariable('all_proxy',   $ProxyUrl)
        [Environment]::SetEnvironmentVariable('NO_PROXY',    $script:NoProxyList)
        [Environment]::SetEnvironmentVariable('no_proxy',    $script:NoProxyList)
        & $env:ComSpec /c $CommandLine
        $exit = $LASTEXITCODE
        if ($null -eq $exit) { $exit = 0 }
    } finally {
        foreach ($k in $keys) {
            if ($saved.ContainsKey($k)) {
                [Environment]::SetEnvironmentVariable($k, $saved[$k])
            } else {
                [Environment]::SetEnvironmentVariable($k, $null)
            }
        }
        $sw.Stop()
    }
    [PSCustomObject]@{
        command    = $CommandLine
        proxy      = $ProxyUrl
        exit_code  = $exit
        elapsed_ms = [int]$sw.ElapsedMilliseconds
    }
}

# ============================================================================
# Actions
# ============================================================================
function Get-Status {
    $core   = Test-CoreRunning
    $api    = Test-ApiAlive
    $marker = Test-Path $script:Cfg.MarkerFile
    $mode   = ''
    $sel    = ''
    if ($api) {
        try {
            $cfg = Invoke-ClashApi -Path '/configs'
            $mode = $cfg.mode
            $proxies = Invoke-ClashApi -Path '/proxies'
            foreach ($k in $proxies.proxies.PSObject.Properties.Name) {
                $n = $proxies.proxies.$k
                if ($n.type -eq 'Selector' -and -not $sel) { $sel = "$k => $($n.now)" }
            }
        } catch {}
    }
    $sp = Get-SysProxyState
    [PSCustomObject]@{
        core_running     = $core
        api_reachable    = $api
        api_source       = $script:RuntimeSource
        api_base         = $script:Cfg.ApiBase
        mixed_port       = [int]$script:Cfg.MixedPort
        port_listening   = (Test-PortOpen -Port ([int]$script:Cfg.MixedPort))
        mode             = $mode
        mode_is_split    = ($mode -eq 'rule')
        sysproxy_on      = $sp.enabled
        sysproxy_server  = $sp.server
        sysproxy_managed = $sp.managed_by_agent
        selected         = $sel
        opened_by_agent  = $marker
        usable           = ($core -and $api)
    }
}

function Assert-RuleMode {
    param([int]$Seconds = 15, [int]$MinWatch = 5)
    # The CfW GUI keeps its own persisted mode (often 'global') and writes it
    # back a few seconds AFTER the API first answers. Setting mode once right
    # after Wait-ApiReady therefore loses the race: 'start' claimed rule, then
    # the GUI flipped it back to global and every CN site got dragged abroad.
    # Re-assert rule until it has stayed put for two consecutive checks and we
    # have watched long enough to be past the GUI's restore window.
    $start = Get-Date
    $deadline = $start.AddSeconds($Seconds)
    $stable = 0
    $last = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $last = (Invoke-ClashApi -Path '/configs').mode
            if ($last -ne 'rule') {
                Invoke-ClashApi -Path '/configs' -Method Patch -Body @{ mode = 'rule' } | Out-Null
                $last = 'rule'
                $stable = 0
            } else {
                $stable++
                if (($stable -ge 2) -and (((Get-Date) - $start).TotalSeconds -ge $MinWatch)) { break }
            }
        } catch { }
        Start-Sleep -Milliseconds 1200
    }
    return $last
}

function Start-Clash {
    if ((Test-CoreRunning) -and (Test-ApiAlive)) {
        return [PSCustomObject]@{
            started = $false
            reason  = 'already_running'
            note    = 'Clash was already running; nothing changed and no marker was written.'
            usable  = $true
        }
    }
    $hasGui = [bool](Get-Process -Name $script:Cfg.GuiProcess -ErrorAction SilentlyContinue)
    if (-not $hasGui) {
        if (-not (Test-Path $script:Cfg.GuiExe)) {
            throw "Clash executable not found: $($script:Cfg.GuiExe)"
        }
        # Start-Process cannot launch this Electron GUI from a non-interactive /
        # sandboxed session: the process dies immediately. Routing through
        # explorer.exe hands it to the interactive user session, which works.
        $quoted = '"' + $script:Cfg.GuiExe + '"'
        Start-Process -FilePath 'explorer.exe' -ArgumentList $quoted | Out-Null
    }
    $ready = Wait-ApiReady -Seconds 35
    $modeNow = ''
    if ($ready) {
        # Split routing is the whole point of this skill: force rule mode so
        # domestic traffic keeps going direct instead of being dragged through
        # an overseas node (global mode does exactly that and slows CN sites).
        $modeNow = Assert-RuleMode
        $dir = Split-Path $script:Cfg.MarkerFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        (Get-Date).ToString('s') | Set-Content -Path $script:Cfg.MarkerFile -Encoding UTF8
    }
    $noteText = 'Started by agent, marker written, mode=rule. Run "stop" when finished.'
    if (-not $ready) { $noteText = 'Launch timed out; API not ready.' }
    [PSCustomObject]@{
        started = $ready
        reason  = 'launched'
        mode    = $modeNow
        note    = $noteText
        usable  = $ready
    }
}

function Stop-Clash {
    $marker  = Test-Path $script:Cfg.MarkerFile
    $running = (Test-CoreRunning) -or [bool](Get-Process -Name $script:Cfg.GuiProcess -ErrorAction SilentlyContinue)
    if (-not $running) {
        if ($marker) { Remove-Item $script:Cfg.MarkerFile -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ stopped = $false; reason = 'not_running'; note = 'It was not running.'; usable = $false }
    }
    if (-not $marker -and -not $Force) {
        return [PSCustomObject]@{
            stopped = $false
            reason  = 'not_opened_by_agent'
            note    = 'Clash was launched by the user, not by the agent. Not stopped. Add -Force only if the user explicitly asked.'
            usable  = $true
        }
    }
    # Ask the main window to close first so CFW can persist its settings.
    $gui = Get-Process -Name $script:Cfg.GuiProcess -ErrorAction SilentlyContinue
    if ($gui) {
        foreach ($g in $gui) { try { $null = $g.CloseMainWindow() } catch {} }
        Start-Sleep -Seconds 3
    }
    Get-Process -Name $script:Cfg.GuiProcess, $script:Cfg.CoreProcess -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $still = (Test-CoreRunning) -or [bool](Get-Process -Name $script:Cfg.GuiProcess -ErrorAction SilentlyContinue)
    if (-not $still) { Remove-Item $script:Cfg.MarkerFile -Force -ErrorAction SilentlyContinue }
    $noteText = 'Stopped and marker cleared.'
    if ($still) { $noteText = 'Residual processes remain; inspect manually.' }
    [PSCustomObject]@{
        stopped = (-not $still)
        reason  = 'closed'
        note    = $noteText
        usable  = $false
    }
}

function Get-Nodes {
    $proxies = Invoke-ClashApi -Path '/proxies'
    $out = @()
    foreach ($k in $proxies.proxies.PSObject.Properties.Name) {
        $n = $proxies.proxies.$k
        if (@('Selector', 'URLTest', 'Fallback', 'LoadBalance') -contains $n.type) {
            $out += [PSCustomObject]@{
                group = $k
                type  = $n.type
                now   = $n.now
                count = @($n.all).Count
            }
        }
    }
    $out
}

function Get-Delay {
    param([string]$NodeName)
    $enc = [uri]::EscapeDataString($NodeName)
    $url = "$($script:Cfg.ApiBase)/proxies/$enc/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $($script:Cfg.ApiSecret)" } -TimeoutSec 8 -ErrorAction Stop
        return [PSCustomObject]@{ node = $NodeName; delay_ms = $r.delay; ok = $true }
    } catch {
        return [PSCustomObject]@{ node = $NodeName; delay_ms = -1; ok = $false }
    }
}

function Switch-Node {
    param([string]$Group, [string]$NodeName)
    Invoke-ClashApi -Path "/proxies/$([uri]::EscapeDataString($Group))" -Method Put -Body @{ name = $NodeName } | Out-Null
    [PSCustomObject]@{ switched = $true; group = $Group; now = $NodeName }
}

function Invoke-Auto {
    param([string]$Url)
    $core   = Test-CoreRunning
    $api    = Test-ApiAlive
    $direct = Measure-Url -Url $Url
    $proxied = $null
    if ($api) { $proxied = Measure-Url -Url $Url -Proxy $ProxyUrl }

    $verdict = ''
    $reason  = ''
    if (-not $core) {
        if ($direct.ok -and $direct.ms -lt 3000) {
            $verdict = 'use_direct'; $reason = 'Clash not running, direct is fine.'
        } else {
            $verdict = 'start_clash'; $reason = 'Clash not running and direct is slow/failing.'
        }
    } elseif ($proxied -and $proxied.ok -and ((-not $direct.ok) -or ($proxied.ms -lt ($direct.ms * 0.6)))) {
        $verdict = 'use_proxy'
        $reason  = "Proxy clearly faster (direct=$($direct.ms)ms proxy=$($proxied.ms)ms)."
    } elseif ($direct.ok -and $direct.ms -lt 3000) {
        $verdict = 'use_direct'; $reason = "Direct already fast enough (direct=$($direct.ms)ms)."
    } elseif ($proxied -and $proxied.ok) {
        $verdict = 'use_proxy'; $reason = 'Direct is slow, use proxy.'
    } else {
        $verdict = 'trouble'; $reason = 'Neither direct nor proxy is healthy; check nodes.'
    }

    [PSCustomObject]@{
        url             = $Url
        clash_running   = $core
        api_reachable   = $api
        opened_by_agent = (Test-Path $script:Cfg.MarkerFile)
        direct_ok       = $direct.ok
        direct_ms       = $direct.ms
        direct_err      = $direct.err
        proxy_ok        = $(if ($proxied) { $proxied.ok } else { $null })
        proxy_ms        = $(if ($proxied) { $proxied.ms } else { $null })
        proxy_env       = $(if ($verdict -eq 'use_proxy') { $ProxyUrl } else { '' })
        verdict         = $verdict
        reason          = $reason
    }
}

# ============================================================================
# Dispatch
# ============================================================================
switch ($Action) {
    'status'  { Write-Out -Data (Get-Status) }
    'start'   { Write-Out -Data (Start-Clash) }
    'stop'    { Write-Out -Data (Stop-Clash) }
    'restart' {
        $s = Stop-Clash
        Start-Sleep -Seconds 2
        $t = Start-Clash
        Write-Out -Data ([PSCustomObject]@{ stop = $s; start = $t })
    }
    'nodes'   {
        $n = Get-Nodes
        if ($AsJson) {
            $n | ConvertTo-Json -Depth 5
        } else {
            $n | Format-Table -AutoSize | Out-String | Write-Output
            Write-Output ''
            Write-Output 'Use "delay <NODE>" to measure one node, "switch <GROUP> <NODE>" to select.'
        }
    }
    'delay'   {
        if (-not $Target) { throw 'Usage: clashctl.ps1 delay <NODE_NAME>' }
        Write-Out -Data (Get-Delay -NodeName $Target)
    }
    'switch'  {
        if (-not $Target -or -not $Node) {
            throw 'Usage: clashctl.ps1 switch <GROUP> <NODE>  (see "nodes" for group names)'
        }
        Write-Out -Data (Switch-Node -Group $Target -NodeName $Node)
    }
    'sysproxy' {
        switch ($Target) {
            'on'     { Write-Out -Data (Set-SysProxyState -On) }
            'off'    { Write-Out -Data (Set-SysProxyState) }
            default  { Write-Out -Data (Get-SysProxyState) }
        }
    }
    'mode' {
        if ($Target) {
            Write-Out -Data (Set-ClashMode -Mode $Target)
        } else {
            $cfg = Invoke-ClashApi -Path '/configs'
            Write-Out -Data ([PSCustomObject]@{ mode = $cfg.mode })
        }
    }
    'run' {
        if (-not $Target) { throw 'Usage: clashctl.ps1 run "COMMAND LINE"  (quote the whole command)' }
        $line = $Target
        if ($Node) { $line = "$line $Node" }
        if ($Rest) { $line = "$line " + ($Rest -join ' ') }
        Write-Out -Data (Invoke-WithProxy -CommandLine $line)
    }
    'test'    {
        $u = $script:Cfg.DefaultUrl
        if ($Target) { $u = $Target }
        $direct  = Measure-Url -Url $u
        $proxied = $null
        if (Test-ApiAlive) { $proxied = Measure-Url -Url $u -Proxy $ProxyUrl }
        Write-Out -Data ([PSCustomObject]@{
            url        = $u
            direct_ok  = $direct.ok
            direct_ms  = $direct.ms
            direct_err = $direct.err
            proxy_ok   = $(if ($proxied) { $proxied.ok } else { $null })
            proxy_ms   = $(if ($proxied) { $proxied.ms } else { $null })
        })
    }
    'auto'    {
        $u = $script:Cfg.DefaultUrl
        if ($Target) { $u = $Target }
        Write-Out -Data (Invoke-Auto -Url $u)
    }
}
