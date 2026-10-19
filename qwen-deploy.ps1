<#
.SYNOPSIS
    Qwen3.5-9B (UD-Q4_K_XL) 一键部署 + 本地 OpenAI 兼容 API

.DESCRIPTION
    幂等：已下载的运行时和模型不会重复下载。第一次跑 = 装环境 + 拉模型 + 起服务；
    以后跑 = 直接拉起服务。所有路径/端口/参数都可以用参数覆盖。

    装出来的东西全部落在脚本自己所在的文件夹里，整个文件夹拷走即用：
      <脚本目录>\llama.cpp\              运行时（exe + 全部 dll）
      <脚本目录>\llama.cpp\models\       模型缓存（LLAMA_CACHE，约 6 GB）
      <脚本目录>\llama.cpp\logs\         服务日志
      <脚本目录>\llama.cpp\cache\        临时下载（VC 运行库，装完即删）
      <脚本目录>\llama.cpp\api-info.txt  API 参数与调用示例

.PARAMETER Root
    运行时与日志的落地目录。默认 = 脚本所在目录下的 llama.cpp，整个文件夹搬到哪都能跑；
    想装到别处就显式传 -Root 'E:\models\llama.cpp'

.PARAMETER KeepZips
    保留下载的两个 zip 安装包（551 MB）。默认解压成功后就删，省空间

.PARAMETER Listen
    监听地址。默认 127.0.0.1 仅本机；改成 0.0.0.0 可让手机/局域网访问（需放行防火墙）

.PARAMETER ModelPath
    已有本地 .gguf 时改用这个参数指定路径，就不走 -hf 下载了

.PARAMETER ApiKey
    本地 API 的密钥。优先级：命令行 -ApiKey > 脚本同目录的 api-key.txt > 默认 sk-local-qwen。
    传空字符串 '' 表示不校验（任何人只要连得上端口就能用，仅建议本机临时用）。
    改 Key 更推荐改 api-key.txt，不用动这个 ps1（它带 BOM，用记事本另存容易弄坏）

.EXAMPLE
    .\qwen-deploy.ps1 -Background -ApiTest
    装好并以后台方式启动，启动完自测一次 API

.EXAMPLE
    .\qwen-deploy.ps1 -Status
    看服务是否在跑、模型名叫什么

.EXAMPLE
    .\qwen-deploy.ps1 -Stop
    停止后台服务

.EXAMPLE
    .\qwen-deploy.ps1 -Cuda cuda-12.4 -Force
    CUDA 13 版跑不起来时，换 CUDA 12.4 版重装
#>
[CmdletBinding()]
param(
    [string]$Root      = '',
    [string]$Model     = 'unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL',
    [string]$ModelPath = '',
    [string]$Alias     = 'qwen3.5-9b',
    [int]   $Port    = 8080,
    [int]   $Ctx     = 131072,
    [string]$ApiKey  = 'sk-local-qwen',
    [string]$Listen  = '127.0.0.1',
    [string]$Build   = 'b11669',
    [ValidateSet('cuda-13.4', 'cuda-12.4')]
    [string]$Cuda    = 'cuda-13.4',
    [int]   $Timeout = 900,
    [switch]$Background,
    [switch]$ApiTest,
    [switch]$Force,
    [switch]$Stop,
    [switch]$Status,
    [switch]$KeepZips,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

# 兜底：任何没预料到的异常都不要让窗口一闪而过（$ErrorActionPreference='Stop' 下
# 这类错误会直接终止脚本，只剩 bat 的两行提示，看不出发生了什么）。
trap {
    $where = if ($_.InvocationInfo) { "  (第 $($_.InvocationInfo.ScriptLineNumber) 行)" } else { '' }
    Write-Host "[x] 脚本异常: $($_.Exception.Message)$where" -ForegroundColor Red
    try {
        if ($PidFile -and (Test-Path $PidFile)) {
            $id2 = 0
            [void][int]::TryParse((Get-Content $PidFile -Raw).Trim(), [ref]$id2)
            if ($id2 -and (Get-Process -Id $id2 -ErrorAction SilentlyContinue)) { Stop-Process -Id $id2 -Force }
            Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    exit 1
}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# 默认把运行时装到"脚本自己所在目录\llama.cpp"，这样整个文件夹搬到哪都能跑
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
if (-not $Root) { $Root = Join-Path $scriptDir 'llama.cpp' }

# API Key 取值优先级：命令行 -ApiKey > 脚本目录下的 api-key.txt > 内置默认值。
# 单独放一个 txt 是为了让你改 Key 时不用去动这个带 BOM 的 ps1——用记事本另存会把 BOM 弄丢，
# PS 5.1 就会按 ANSI 读中文注释，整个脚本几十个语法错。
$KeyFile = Join-Path $scriptDir 'api-key.txt'
$KeyFromFile = $false
if (-not $PSBoundParameters.ContainsKey('ApiKey') -and (Test-Path -LiteralPath $KeyFile)) {
    try {
        $k = (Get-Content -LiteralPath $KeyFile -Raw -ErrorAction Stop)
        if ($null -ne $k) { $k = $k.Trim() }
        if ($k) { $ApiKey = $k; $KeyFromFile = $true }
    } catch { }
}

function Write-Line([string]$tag, [string]$m, [string]$color) {
    $line = "[$tag] $m"
    Write-Host $line -ForegroundColor $color
    # 同时落一份日志：窗口一关就什么都看不见了，出问题只能靠这个文件复盘
    if ($script:RunLog) {
        try { [IO.File]::AppendAllText($script:RunLog, ((Get-Date -Format 'HH:mm:ss') + '  ' + $line + "`r`n"), (New-Object Text.UTF8Encoding($true))) } catch { }
    }
}
function Info($m) { Write-Line '*' $m 'Cyan' }
function Ok  ($m) { Write-Line '+' $m 'Green' }
function Warn($m) { Write-Line '!' $m 'Yellow' }
function Die ($m) { Write-Line 'x' $m 'Red'; exit 1 }

# curl 的退出码翻译成人话，不然只会看到一串数字
function Curl-Why($code) {
    switch ($code) {
        7  { '连不上（网络断了 / 代理没开）' }
        22 { 'HTTP 错误（多半是 429 限流，或 403/404）' }
        28 { '超时，或速度太低被判定为卡死' }
        35 { 'TLS 握手失败（中间设备干扰 / 代理不支持 HTTPS）' }
        56 { '连接被重置' }
        default { "curl exit $code" }
    }
}

# 原生 exe 往 stderr 写东西时，$ErrorActionPreference='Stop' 会把它当成终止错误、直接掐死脚本
# （curl 报一行错、llama-server 打启动日志都会触发）。所以所有外部程序统一走这个壳：
# 临时把 EAP 降级，返回退出码 + stdout，绝不抛异常。
function Invoke-Native([string]$Exe, [string[]]$NativeArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @NativeArgs 2>$null | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        [pscustomobject]@{ Code = $code; Out = "$out" }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ===== 下载进度条（被下面的 Invoke-DownloadWithBar 使用）=====
# 为什么不用 curl 自带的进度表：它往 stderr 写、只在真控制台好看，重定向日志里全是乱码，
# 而且没法在进度上叠自己的信息。这里改成"curl 静默下载 + 自己量文件大小画条"。
function Get-RemoteSize([string]$Url) {
    # 先试 HEAD
    $r = Invoke-Native 'curl.exe' @('-sIL', '--connect-timeout', '10', '--max-time', '20', $Url)
    $len = 0
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^\s*content-length:\s*(\d+)\s*$') { $len = [int64]$Matches[1] }
    }
    if ($len -gt 0) { return $len }
    # HEAD 拿不到（部分 CDN 不回 content-length）时，用 1 字节的 Range 请求从 Content-Range 里抠总长
    $r2 = Invoke-Native 'curl.exe' @('-sL', '--connect-timeout', '10', '--max-time', '20',
                                    '-r', '0-0', '-D', '-', '-o', 'NUL', $Url)
    foreach ($line in ($r2.Out -split "`r?`n")) {
        if ($line -match 'content-range:\s*bytes\s+\d+-\d+/(\d+)') { return [int64]$Matches[1] }
    }
    return 0
}

function Format-Bytes([double]$mb) {
    if ($mb -ge 1024) { "{0:N2} GB" -f ($mb / 1024) } else { "{0:N0} MB" -f $mb }
}

# 一行能写多宽：按真实控制台宽度来，超宽会折行、把原来的 \r 覆盖刷新搞成刷屏
function Get-BarWidth {
    $w = 0
    try { $w = [int][Console]::WindowWidth } catch { }
    if ($w -le 0) { $w = 80 }
    if ($w -gt 100) { $w = 100 }
    $w = $w - 1
    if ($w -lt 44) { $w = 44 }
    $w
}

# 拼一行进度：    [######------]  54.1%  3.01 GB / 5.56 GB  13.5 MB/s  剩 03:14
# 返回 { Line; Width }，交给 Show-DownloadBar 去原地刷；单独拆出来是为了能离线验宽度
function Format-DownloadLine([int64]$Cur, [int64]$Total, [timespan]$Elapsed) {
    $max   = Get-BarWidth
    $curMb = $Cur / 1MB
    $known = ($Total -gt 0)
    $pct   = 0.0
    if ($known) { $pct = [math]::Min(100.0, $Cur / $Total * 100.0) }
    $pctText = if ($known) { '{0,5:N1}%' -f $pct } else { '' }
    $size    = if ($known) { "$(Format-Bytes $curMb) / $(Format-Bytes ($Total / 1MB))" } else { "已下 $(Format-Bytes $curMb)" }

    $sec  = $Elapsed.TotalSeconds
    $rate = if ($sec -gt 0.5) { $curMb / $sec } else { 0 }
    $speed = ''
    if ($rate -gt 0.05) {
        $speed = '{0:N1} MB/s' -f $rate
        if ($known -and $Cur -lt $Total) {
            $speed += ' 剩 ' + [timespan]::FromSeconds(($Total - $Cur) / 1MB / $rate).ToString('mm\:ss')
        }
    }

    # 窗口窄时按优先级从右往左砍：先砍"速度/剩余"，再砍"已下/总大小"，最后只剩百分比，
    # 保证任何宽度下都不折行（一旦折行，\r 原地刷新就会变成刷屏）
    $extras = @()
    if ($known) { $extras += $pctText }
    $extras += $size
    if ($speed) { $extras += $speed }

    $barW = 8
    while ($true) {
        $used = 4 + 2 + (($extras -join '  ').Length) + 2
        $barW = $max - $used
        if ($barW -ge 10 -or $extras.Count -le 1) { break }
        $extras = $extras[0..($extras.Count - 2)]
    }
    if ($barW -gt 26) { $barW = 26 }
    if ($barW -lt 8)  { $barW = 8 }

    $fill = if ($known) { [int][math]::Round($barW * $pct / 100) } else { 0 }
    $bar  = if ($known) { ('#' * $fill) + ('-' * ($barW - $fill)) } else { ('.' * $barW) }

    $line = "    [$bar]  " + ($extras -join '  ')
    if ($line.Length -gt $max) { $line = $line.Substring(0, $max) }
    [pscustomobject]@{ Line = $line; Width = $max }
}

function Show-DownloadBar([int64]$Cur, [int64]$Total, [timespan]$Elapsed) {
    $o = Format-DownloadLine $Cur $Total $Elapsed
    Write-Host $o.Line
}

# 静默跑 curl，同时每秒量一次目标文件大小画进度条；返回 curl 的退出码
function Invoke-DownloadWithBar([string]$Url, [string]$Dest, [switch]$NoRevoke) {
    $total = 0
    try { $total = Get-RemoteSize $Url } catch { }

    # 用 .NET 起进程而不是 Start-Process -PassThru：后者拿到的 .ExitCode 经常是 $null，
    # 会把"下载成功"误判成失败（实测踩过，两个 zip 都下完了还报下载失败）
    $cArgs = @('-L', '--fail', '-sS')
    if ($NoRevoke) { $cArgs += '--ssl-no-revoke' }   # 拦截式代理/校园网常让吊销列表检查失败
    $cArgs += @('--retry', '6', '--retry-delay', '5',
                '--connect-timeout', '15', '--speed-limit', '20480', '--speed-time', '60',
                '-C', '-', '-o', "`"$Dest`"", "`"$Url`"")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'curl.exe'
    $psi.Arguments = ($cArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return 127 }

    # 不再用 \r 原地覆盖：不同终端/控制台下覆盖刷新会把每一帧堆成一行行（实测踩过两次），
    # 改成"按进度分档打印整行"——每涨 5% 打一行，拿不到总大小时每 5 秒打一行。
    $lastPct     = -999
    $lastPrint   = -999.0
    $lastFileLog = -999.0
    while (-not $proc.HasExited) {
        $cur = 0
        if (Test-Path -LiteralPath $Dest) {
            try { $fi = New-Object IO.FileInfo($Dest); $fi.Refresh(); $cur = $fi.Length } catch { }
        }
        $el = $sw.Elapsed.TotalSeconds

        $pct = if ($total -gt 0) { [int][math]::Floor($cur * 100.0 / $total) } else { -1 }
        $due = if ($pct -ge 0) {
            ($pct - $lastPct) -ge 5 -or ($el - $lastPrint) -ge 30
        } else {
            ($el - $lastPrint) -ge 5
        }
        if ($due) {
            $lastPct   = $pct
            $lastPrint = $el
            try { Show-DownloadBar $cur $total $sw.Elapsed } catch { }
        }

        # 每 30 秒往 run 日志落一条，事后能复盘速率变化
        if ($el - $lastFileLog -ge 30) {
            $lastFileLog = $el
            if ($script:RunLog) {
                $mb = [math]::Round($cur / 1MB)
                try { [IO.File]::AppendAllText($script:RunLog, ((Get-Date -Format 'HH:mm:ss') + "  [*] 下载中 $mb MB / $(Format-Bytes ($total / 1MB))`r`n"), (New-Object Text.UTF8Encoding($true))) } catch { }
            }
        }
        Start-Sleep -Milliseconds 400
    }
    $proc.WaitForExit()

    $errText = ''
    try { $errText = $proc.StandardError.ReadToEnd() } catch { }
    $code = 0
    try { $code = [int]$proc.ExitCode } catch { $code = 0 }
    [pscustomobject]@{ Code = $code; Out = "$errText" }
}

# 证书吊销列表检查失败时（curl 退出码 35 + schannel 报错，拦截式代理/校园网很常见）
# 自动带 --ssl-no-revoke 再来一次，不然用户只看到"下载失败"却不知道是 TLS 的问题
function Invoke-DownloadRetry([string]$Url, [string]$Dest) {
    $r = Invoke-DownloadWithBar -Url $Url -Dest $Dest
    if ($r.Code -eq 35 -and $r.Out -match 'schannel|REVOCATION|CERT') {
        Warn '  TLS 证书吊销检查失败（代理/校园网常见），改用 --ssl-no-revoke 重试…'
        $r = Invoke-DownloadWithBar -Url $Url -Dest $Dest -NoRevoke
    }
    $r
}

$Root    = [IO.Path]::GetFullPath($Root)
$PidFile = Join-Path $Root 'server.pid'
$LogDir  = Join-Path $Root 'logs'
$BaseUrl = "http://127.0.0.1:$Port"

# 模型走 -hf 下到 llama.cpp 的缓存目录，默认在 %USERPROFILE%\.cache\llama.cpp，
# 那样"只搬文件夹"就会丢 6 GB 模型。指回 Root 下，让整个目录自包含。
if (-not $env:LLAMA_CACHE) { $env:LLAMA_CACHE = Join-Path $Root 'models' }
$ModelCache = $env:LLAMA_CACHE

# 整轮运行都记到 logs\run-<时间>.log，卡住/闪退时才有据可查
New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
$script:RunLog = Join-Path $LogDir ("run-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
try {
    $banner = "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  PS=$($PSVersionTable.PSVersion)  Root=$Root  Model=$Model ====="
    [IO.File]::AppendAllText($script:RunLog, $banner + "`r`n", (New-Object Text.UTF8Encoding($false)))
} catch { $script:RunLog = $null }

function Find-Exe {
    if (-not (Test-Path $Root)) { return $null }
    $f = Get-ChildItem -Path $Root -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { $f.FullName } else { $null }
}

function Get-Health {
    # curl 失败时 Out 可能是 $null；Out-String 还会补一个换行，所以必须 Trim。
    # 不 Trim 的话跟 '200' 永远比不相等，会一路白等到超时——这是个真坑。
    "$((Invoke-Native 'curl.exe' @('-s', '--noproxy', '*', '-o', 'NUL', '-w', '%{http_code}', "$BaseUrl/health")).Out)".Trim()
}

function Get-LogTail($path, $n) {
    if (-not (Test-Path $path)) { return @() }
    try { return @(Get-Content $path -Tail $n -ErrorAction SilentlyContinue) } catch { return @() }
}

# 等 /health 变 200。同时盯三件事：服务起来了 / 进程提前死了 / 模型下到哪了。
function Wait-Ready($seconds, $proc, $errLog) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $nextPeek = 0
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
        if ((Get-Health) -eq '200') { return 'ok' }
        if ($proc -and $proc.HasExited) { return 'exited' }
        if ($errLog -and $sw.Elapsed.TotalSeconds -ge $nextPeek) {
            # 下载进度不一定进日志（llama.cpp 的进度条往 TTY 写、重定向后基本是空的），
            # 所以直接量缓存目录涨了多少 —— 这是唯一能证明"它没死、还在下"的数据。
            $cacheMb = 0
            if ($ModelCache -and (Test-Path $ModelCache)) {
                $sz = (Get-ChildItem $ModelCache -Recurse -File -ErrorAction SilentlyContinue |
                       Measure-Object Length -Sum).Sum
                if ($sz) { $cacheMb = [math]::Round($sz / 1MB) }
            }
            # 注意：函数返回 @(单元素) 会被 PowerShell 展开成字符串，
            # 于是 $tail[-1] 取到的是 Char，.Trim() 直接炸（曾因此开跑 1 秒即死）。用 @() 兜住。
            $tail = @(Get-LogTail $errLog 1)
            $last = if ($tail.Count -gt 0) { "$($tail[-1])".Trim() } else { '' }
            $msg = if ($last) { $last } else { '正在下载模型（没有新日志是正常的）' }
            Info ("…{0:N0}s  已下 {1} MB  {2}" -f $sw.Elapsed.TotalSeconds, $cacheMb, $msg)
            $nextPeek = $sw.Elapsed.TotalSeconds + 10
        }
        Start-Sleep -Seconds 3
    }
    'timeout'
}

# ---------------------------------------------------------------- 状态 / 停止
if ($Status) {
    if (-not (Find-Exe)) { Warn "还没有安装：$Root 下找不到 llama-server.exe"; exit 1 }
    if ((Get-Health).Trim() -eq '200') {
        Ok "服务在运行：$BaseUrl"
        $h = @(); if ($ApiKey) { $h = @('-H', "Authorization: Bearer $ApiKey") }
        try {
            $m = (Invoke-Native 'curl.exe' (@('-s', '--noproxy', '*') + $h + @("$BaseUrl/v1/models"))).Out | ConvertFrom-Json
            if ($m -and $m.data -and @($m.data).Count -gt 0 -and $m.data[0].id) {
                $m.data | ForEach-Object { "    可用模型: $($_.id)" }
            } else {
                Warn '拿不到模型列表：多半是 API Key 不对（401）'
            }
        } catch { Warn "取模型列表失败: $($_.Exception.Message)" }
        if (Test-Path $PidFile) { "    PID: $((Get-Content $PidFile -Raw).Trim())" }
    } else {
        Warn "服务未响应（/health 返回 $((Get-Health).Trim())）"
    }
    exit 0
}

if ($Stop) {
    if (Test-Path $PidFile) {
        $procId = 0
        [void][int]::TryParse((Get-Content $PidFile -Raw).Trim(), [ref]$procId)
        if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $procId -Force
            Ok "已停止 PID $procId"
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force
    Ok '已清理所有 llama-server 进程'
    exit 0
}

# ---------------------------------------------------------------- 0. 目录与空间
New-Item -ItemType Directory -Force -Path $Root, $LogDir, $ModelCache | Out-Null
Info "工作目录: $Root"
Info "所有东西（运行时、模型、日志）都会落在这个目录里"

# 目录必须可写：放进 Program Files、只读盘、或只读的云盘同步目录会一路报错
$probe = Join-Path $Root '.write-test'
try {
    Set-Content -Path $probe -Value 'ok' -Encoding ascii -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
} catch {
    Die "这个目录写不进去: $Root`n    别放在 Program Files / 只读盘 / C:\ 根目录，换个可写的文件夹再跑"
}
try {
    $free = (Get-Item $Root).PSDrive.Free
    if ($free -and $free -lt 10GB) {
        Warn ("D 盘剩余 {0:N1} GB，装完大约要 7 GB，建议先腾点空间" -f ($free / 1GB))
    }
} catch { }

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Die '找不到 curl.exe（Windows 10 1803+ 自带）' }

# ---------------------------------------------------------------- 0.5 裸机前置条件
# llama.cpp 的 exe/DLL 硬依赖 MSVC 运行库（VCRUNTIME140.dll / VCRUNTIME140_1.dll / MSVCP140.dll）。
# 重装系统后的干净 Windows 经常没有，缺了会以"找不到 DLL"的方式崩，报错完全指不到根因。
$sys32 = Join-Path $env:SystemRoot 'System32'
$needVc = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') |
          Where-Object { -not (Test-Path (Join-Path $sys32 $_)) }
if ($needVc) {
    Warn "缺 VC++ 运行库: $($needVc -join ', ')（重装系统后很常见，llama.cpp 离不开它）"
    $cacheDir = Join-Path $Root 'cache'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $vc = Join-Path $cacheDir 'vc_redist.x64.exe'
    Info '下载 VC++ 2015-2022 x64 运行库（约 25 MB）…'
    $r = Invoke-Native 'curl.exe' @('-L', '--fail', '--connect-timeout', '15', '--retry', '2',
                                    '-o', $vc, 'https://aka.ms/vs/17/release/vc_redist.x64.exe')
    if ($r.Code -ne 0 -or -not (Test-Path $vc)) {
        Die 'VC++ 运行库下载失败。手动装一次再重跑：https://aka.ms/vs/17/release/vc_redist.x64.exe'
    }
    Info '安装（会弹一次 UAC 提权，点"是"）…'
    $vcExit = -1
    try {
        $p = Start-Process -FilePath $vc -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
        $vcExit = $p.ExitCode
    } catch {
        Die 'VC++ 运行库安装被取消（UAC 被拒）。可手动装：https://aka.ms/vs/17/release/vc_redist.x64.exe'
    }
    # 0=成功 1638=已装过别的版本 3010=成功但需重启
    if ($vcExit -ne 0 -and $vcExit -ne 1638 -and $vcExit -ne 3010) {
        Die "VC++ 运行库安装失败（exit $vcExit）。手动装：https://aka.ms/vs/17/release/vc_redist.x64.exe"
    }
    Ok 'VC++ 运行库已就绪'
    Remove-Item $vc -Force -ErrorAction SilentlyContinue
}

# 显卡驱动：没有 nvcuda.dll 时 CUDA 后端加载不了，再好的脚本也白搭
$hasDriver = (Test-Path (Join-Path $sys32 'nvcuda.dll')) -or (Test-Path (Join-Path $sys32 'nvidia-smi.exe'))
if (-not $hasDriver) {
    Warn '系统里没有 NVIDIA 驱动（nvcuda.dll / nvidia-smi.exe 都不存在）'
    Die '先装显卡驱动（RTX 50 系要用较新的版本）：https://www.nvidia.cn/drivers/ ，装完重跑本脚本'
}


# ---------------------------------------------------------------- 1. 运行时
$exe = Find-Exe
if ($exe -and -not $Force) {
    Ok "运行时已存在: $exe"
} else {
    $base      = "https://github.com/ggml-org/llama.cpp/releases/download/$Build"
    $zipBin    = "llama-$Build-bin-win-$Cuda-x64.zip"
    $zipCudart = "cudart-llama-bin-win-$Cuda-x64.zip"

    # GitHub 直连在国内经常被限速/中断，依次尝试直连 → 几个公共加速前缀
    $mirrors = @('', 'https://ghfast.top/', 'https://gh-proxy.com/', 'https://ghproxy.net/')
    foreach ($z in @($zipBin, $zipCudart)) {
        $dest = Join-Path $Root $z
        if ((Test-Path $dest) -and -not $Force) { Ok "$z 已下载，跳过"; continue }
        Info "下载 $z"
        $got = $false
        foreach ($m in $mirrors) {
            if ($m) { Info "  直连失败，试镜像 $m" }
            $url = "$m$base/$z"
            $r = Invoke-DownloadRetry -Url $url -Dest $dest
            if ($r.Code -eq 0 -and (Test-Path $dest) -and (Get-Item $dest).Length -gt 1MB) { $got = $true; break }
            $why = (($r.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($why) { Warn "    $why" }
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
        if (-not $got) {
            Die "下载失败: $base/$z`n    直连和几个公共镜像都没成功。开代理再跑，或加 -Cuda cuda-12.4 换一套。"
        }
        Ok ("{0}  {1:N0} MB" -f $z, ((Get-Item $dest).Length / 1MB))
    }

    Info '解压…'
    foreach ($z in @($zipBin, $zipCudart)) {
        $zipPath = Join-Path $Root $z
        if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            $t = Invoke-Native 'tar.exe' @('-xf', $zipPath, '-C', $Root)
            if ($t.Code -ne 0) {
                Warn "tar 解压 $z 失败（返回 $($t.Code)），改用 Expand-Archive"
                Expand-Archive -Path $zipPath -DestinationPath $Root -Force
            }
        } else {
            Expand-Archive -Path $zipPath -DestinationPath $Root -Force
        }
    }

    $exe = Find-Exe
    if (-not $exe) { Die '解压后仍找不到 llama-server.exe，可能包结构变了' }
    Ok "已解压: $exe"

    # 解压成功就没必要留着 551 MB 安装包；想留着以后离线装就加 -KeepZips
    if (-not $KeepZips) {
        foreach ($z in @($zipBin, $zipCudart)) {
            Remove-Item (Join-Path $Root $z) -Force -ErrorAction SilentlyContinue
        }
        Info '安装包已清理（要保留加 -KeepZips）'
    }
}

# DLL 必须和 exe 同目录（cudart 包解出来的运行库要收过来）
$binDir = Split-Path $exe -Parent
Get-ChildItem -Path $Root -Recurse -Filter *.dll -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -ne $binDir } |
    ForEach-Object { Copy-Item $_.FullName -Destination $binDir -Force }

# ---------------------------------------------------------------- 2. 验 CUDA
Info '检查 CUDA 后端…'
$dev = ''
$dev = (Invoke-Native $exe @('--list-devices')).Out
($dev -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { "    $($_.Trim())" }
if ($dev -match 'CUDA0') {
    Ok 'CUDA 后端可用，模型会整体上卡'
} elseif ($dev.Trim()) {
    Warn '没有列出 CUDA0：多半是显卡驱动版本太旧，或这套 CUDA 构建不被驱动接受'
    Warn '先确认驱动是最新（RTX 50 系需要较新驱动）；仍不行就 -Cuda cuda-12.4 -Force 重装一套'
} else {
    Warn '这个构建不认 --list-devices，改为在启动日志里确认 CUDA0'
}

# ---------------------------------------------------------------- 3. 模型
# llama-server 自带的 -hf 下载器不重试、不续传，hf-mirror 一限流（429）就得从头再来。
# 所以这里自己用 curl 下：支持 -C - 断点续传 + 429/5xx 自动重试，进度还能被心跳量出来。
$modelFile = $null
if ($ModelPath) {
    if (-not (Test-Path $ModelPath)) { Die "找不到模型文件: $ModelPath" }
    $modelFile = (Resolve-Path $ModelPath).Path
} elseif ($Model -match '^([^/:]+)/([^/:]+):(.+)$') {
    $owner    = $Matches[1]
    $repo     = $Matches[2]
    $quant    = $Matches[3]
    $fileName = "$($repo -replace '-GGUF$', '')-$quant.gguf"
    $modelFile = Join-Path $ModelCache $fileName
    if ((Test-Path $modelFile) -and (Get-Item $modelFile).Length -lt 1MB) {
        Remove-Item $modelFile -Force -ErrorAction SilentlyContinue   # 上次卡死留下的 0 字节残骸
    }
    if ((Test-Path $modelFile) -and (Get-Item $modelFile).Length -gt 2GB) {
        Ok ("模型已就绪: {0:N1} GB" -f ((Get-Item $modelFile).Length / 1GB))
    } else {
        $relPath = "$owner/$repo/resolve/main/$fileName"
        # 注意：这里必须全程用 @() 包着，否则只有一个元素时 $hosts 会是字符串，
        # += 就变成字符串拼接（之前真的拼出过 "https://hf-mirror.comhttps://huggingface.co"）
        $hosts = @()
        if ($env:HF_ENDPOINT) { $hosts += "$($env:HF_ENDPOINT)".TrimEnd('/') }
        $hosts += 'https://hf-mirror.com'
        # huggingface.co 在国内直连基本不通；只有配了代理才值得多试一轮，否则纯属干等
        if ($env:HTTPS_PROXY -or $env:HTTP_PROXY) { $hosts += 'https://huggingface.co' }
        Info "下载模型 $fileName（约 5.6 GB）"
        $got = $false
        foreach ($h in $hosts) {
            $url = "$h/$relPath"
            Info "  来源: $h"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            # --speed-limit/--speed-time：连上了但一个字节都不给（hf-mirror 常见）时，60 秒就掐掉重试，
            # 否则 curl 会无限期挂着，表现就是"卡住不动"。
            $r = Invoke-DownloadRetry -Url $url -Dest $modelFile
            $mb = if (Test-Path $modelFile) { [math]::Round((Get-Item $modelFile).Length / 1MB, 1) } else { 0 }
            if ($r.Code -eq 0 -and $mb -gt 2000) { $got = $true; break }
            Warn ("  这个源没成（{0}），用了 {1:N0}s，已下 {2} MB" -f (Curl-Why $r.Code), $sw.Elapsed.TotalSeconds, $mb)
            $detail = ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / '
            if ($detail) { Warn "    $detail" }
            if ($mb -gt 0) { Warn '    已下的是真字节，换源/重跑都会从断点接着来' }
        }
        if (-not $got) {
            Warn "三条路都没成。别跟它耗了，手动下更快："
            Warn "    1) 浏览器打开 https://hf-mirror.com/$owner/$repo/tree/main"
            Warn "    2) 下 $fileName"
            Warn "    3) 存到哪都行，然后：start-qwen.bat -ModelPath `"D:\下载\$fileName`""
            Die "模型没下成（详细过程见 $script:RunLog）"
        }
        Ok ("模型就绪: {0:N1} GB" -f ((Get-Item $modelFile).Length / 1GB))
    }
} else {
    Warn "模型名 '$Model' 不是 owner/repo:quant 形式，退回 llama-server 自带下载（不续传）"
}

# ---------------------------------------------------------------- 4. 启动
# 16 GB 内存下不要用 --mlock / --no-mmap，会把 6 GB 模型钉死在内存里
$srcArgs = if ($modelFile) { @('--model', $modelFile) } else { @('-hf', $Model) }
$argList = $srcArgs + @(
    '--alias', $Alias,
    '--host', $Listen,
    '--port', "$Port",
    '--ctx-size', "$Ctx",
    '--cache-type-k', 'q8_0',
    '--cache-type-v', 'q8_0',
    '--flash-attn', 'on',
    '--n-gpu-layers', '99',
    '--jinja',
    '--metrics'
)
if ($ApiKey) { $argList += @('--api-key', $ApiKey) }
if ($env:HF_ENDPOINT -ne 'https://hf-mirror.com') { $env:HF_ENDPOINT = 'https://hf-mirror.com' }

# 已经有一个在跑就别再起第二个：端口会冲突，然后白等 15 分钟
if ((Get-Health) -eq '200' -and -not $Force) {
    Ok "服务已经在运行：$BaseUrl"
    if (Test-Path $PidFile) { "    PID: $((Get-Content $PidFile -Raw).Trim())" }
    if (-not $NoBrowser) { Start-Process $BaseUrl }
    exit 0
}

if (-not $Background) {
    Info '前台启动（Ctrl+C 退出；首次会先下 6 GB 模型）'
    Info "地址 $BaseUrl   Web UI $BaseUrl"
    # llama-server 会把启动日志写到 stderr，EAP=Stop 下必须放开，否则一启动就被掐
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @argList
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    exit $code
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $LogDir "server-$stamp.out.log"
$errLog = Join-Path $LogDir "server-$stamp.err.log"

# PS 5.1 的 -ArgumentList 只是把数组拼成字符串，带空格的参数得自己补引号，
# 否则 -ModelPath 'D:\my models\x.gguf' 会被拆成两个参数。
$argString = (@($argList) | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } }) -join ' '

$proc = Start-Process -FilePath $exe -ArgumentList $argString -WorkingDirectory $binDir `
                      -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
Ok "已后台启动，PID $($proc.Id)"
Info "日志: $errLog"

$waitDesc = if ($Timeout -ge 120) { "$([math]::Ceiling($Timeout / 60)) 分钟" } else { "$Timeout 秒" }
Warn '从现在起这个窗口不要关、不要按 Ctrl+C —— 关掉会连 llama-server 一起杀掉，下载当场中断。'
Info "等待服务就绪（首次要下 6 GB 模型，最多等 $waitDesc；每 10 秒回显已下多少 MB）…"
$state = Wait-Ready $Timeout $proc $errLog
if ($state -ne 'ok') {
    if ($state -eq 'exited') {
        $ec = $null
        try { [void]$proc.WaitForExit(2000); $ec = $proc.ExitCode } catch { }
        $codeText = if ("$ec" -ne '') { "（exit $ec）" } else { '' }
        Warn "llama-server 起来了又立刻退出$codeText"
    } else { Warn "等了 $waitDesc 还没就绪" }
    Warn '日志尾部：'
    Get-LogTail $errLog 25 | ForEach-Object { "    $_" }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Die "排查后重跑，或 .\qwen-deploy.ps1 -Stop 清理"
}
Ok '服务已就绪'

# 兜底核对：模型到底落在本文件夹里没有。
# LLAMA_CACHE 指向 $Root\models，绝大多数构建都认；万一不认，模型会跑到用户缓存，
# 结果只是"文件夹不自包含"，功能不受影响，所以这里只提醒不动手。
if (-not $ModelPath) {
    $localGguf = @(Get-ChildItem (Join-Path $Root 'models') -Recurse -Filter *.gguf -ErrorAction SilentlyContinue)
    if (-not $localGguf) {
        $userCache = Join-Path $env:USERPROFILE '.cache\llama.cpp'
        if (Test-Path $userCache) {
            Warn "模型没落在 $Root\models，而是被放到了 $userCache"
            Warn '功能不受影响，只是整个文件夹不再自包含；要搬走就连那个目录一起搬'
        }
    }
}

# ---------------------------------------------------------------- 4. API 自测
if ($ApiTest) {
    Info '调用 /v1/chat/completions 自测…'
    $body = @{
        model      = $Alias
        messages   = @(@{ role = 'user'; content = '用一句话自我介绍，并说明你能做什么' })
        max_tokens = 96
    } | ConvertTo-Json -Depth 6

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "qwen-api-test-$PID.json"
    [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($false)))
    $hdr = @('-H', 'Content-Type: application/json')
    if ($ApiKey) { $hdr += @('-H', "Authorization: Bearer $ApiKey") }

    $raw = (Invoke-Native 'curl.exe' (@('-s', '--noproxy', '*', '-X', 'POST', "$BaseUrl/v1/chat/completions") + $hdr + @('--data-binary', "@$tmp"))).Out
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    try {
        $o = $raw | ConvertFrom-Json
        if ($o.choices) {
            Ok '模型回复:'
            ($o.choices[0].message.content -split "`r?`n") | ForEach-Object { "    $_" }
            if ($o.timings -and $o.timings.predicted_per_second) {
                "    生成速度: {0:N1} tok/s" -f $o.timings.predicted_per_second
            }
        } else {
            Warn "返回里没有 choices: $raw"
        }
    } catch {
        Warn "返回无法解析: $raw"
    }
}

# ---------------------------------------------------------------- 5. 交付信息
$info = @(
    '============================================================',
    ' Qwen3.5-9B 本地 API 已就绪（OpenAI 兼容）',
    '------------------------------------------------------------',
    "  Base URL : $BaseUrl/v1",
    "  API Key  : $(if ($ApiKey) { $ApiKey } else { '(未启用校验)' })$(if ($KeyFromFile) { '   ← 来自 api-key.txt' } else { '' })",
    "  模型名   : $Alias",
    "  Web UI   : $BaseUrl",
    "  健康检查 : $BaseUrl/health",
    "  日志     : $errLog",
    '------------------------------------------------------------',
    '  停止: start-qwen.bat -Stop        状态: start-qwen.bat -Status',
    '============================================================'
)
$info | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

$apiInfo = @"
# Qwen3.5-9B 本地 API

BASE_URL = $BaseUrl/v1
API_KEY  = $ApiKey
MODEL    = $Alias

## Python (openai>=1.0)
from openai import OpenAI

client = OpenAI(base_url="$BaseUrl/v1", api_key="$ApiKey")
r = client.chat.completions.create(
    model="$Alias",
    messages=[{"role": "user", "content": "你好"}],
)
print(r.choices[0].message.content)

## 任意 OpenAI 兼容客户端
# 在新版 OpenAI SDK / LangChain / Dify / Cherry Studio 里，
# 把 base_url 填 $BaseUrl/v1，api_key 填 $ApiKey，模型名填 $Alias 即可。

## 其他端点
# GET  /v1/models          列出模型
# GET  /health             存活检查（启动探针用这个）
# GET  /props              当前上下文长度等运行时参数
# POST /v1/chat/completions 对话
# POST /v1/completions      补全
# GET  /metrics            Prometheus 指标
"@
Set-Content -Path (Join-Path $Root 'api-info.txt') -Value $apiInfo -Encoding utf8

if (-not $NoBrowser) { Start-Process "$BaseUrl" }
