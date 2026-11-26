[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir = Join-Path $env:TEMP ("agy_share_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

try {
    $ZipFile = Join-Path $WorkDir "public_bundle.zip"
    $ExtractDir = Join-Path $WorkDir "bundle"

    Write-Host "[1/2] 正在下载 Antigravity 深度汉化与中文规范公开套件..." -ForegroundColor Cyan
    $ProxyUri = $null
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($ie -and $ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
            $ps = $ie.ProxyServer
            if ($ps -notmatch '^https?://') { $ps = "http://$ps" }
            $ProxyUri = $ps
        }
    } catch {}

    $Urls = @(
        "https://fastly.jsdelivr.net/gh/ZHANGKK-Z/Antigravity-Sync@main/public_bundle.zip",
        "https://cdn.jsdelivr.net/gh/ZHANGKK-Z/Antigravity-Sync@main/public_bundle.zip",
        "https://raw.githubusercontent.com/ZHANGKK-Z/Antigravity-Sync/main/public_bundle.zip"
    )

    $Downloaded = $false
    foreach ($u in $Urls) {
        try {
            if ($ProxyUri -and $u -like "*githubusercontent*") {
                Invoke-WebRequest -Uri $u -OutFile $ZipFile -Proxy $ProxyUri -UseBasicParsing -TimeoutSec 20
            } else {
                Invoke-WebRequest -Uri $u -OutFile $ZipFile -UseBasicParsing -TimeoutSec 15
            }
            if ((Test-Path $ZipFile) -and (Get-Item $ZipFile).Length -gt 1024) {
                Write-Host "  -> 下载成功 ($([Math]::Round((Get-Item $ZipFile).Length / 1024, 1)) KB)" -ForegroundColor Green
                $Downloaded = $true
                break
            }
        } catch {
            Write-Host "  -> 自动切换备用下载节点..." -ForegroundColor Gray
        }
    }

    if (-not $Downloaded) {
        throw "下载失败，请检查网络连接后重试。"
    }

    Write-Host "[2/2] 正在解压并安装..." -ForegroundColor Cyan
    Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force
    $DeployScript = Join-Path $ExtractDir "scripts\deploy_share.ps1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $DeployScript -SkipPause
} finally {
    if (Test-Path $WorkDir) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
