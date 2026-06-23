# --- パラメータ ---
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json"
)

# --- OUI データベースの読み込み ---
$ouiPath = "$PSScriptRoot\..\config\oui.json"
$ouiDB = @{}

if (Test-Path $ouiPath) {
    $json = Get-Content $ouiPath -Raw | ConvertFrom-Json
    foreach ($key in $json.PSObject.Properties.Name) {
        $ouiDB[$key] = $json.$key
    }
}

function Get-VendorFromMac($mac) {
    if ($mac -match "^([0-9A-F]{2})[:-]([0-9A-F]{2})[:-]([0-9A-F]{2})") {
        $key = "$($Matches[1])-$($Matches[2])-$($Matches[3])"
        if ($ouiDB.ContainsKey($key)) {
            return $ouiDB[$key]
        }
    }
    return ""
}

function Get-HostNameFromIP {
    param(
        [string]$IpAddress
    )

    # 1. DNS 逆引き（Resolve-DnsName があれば最優先）
    try {
        $dns = Resolve-DnsName -Name $IpAddress -ErrorAction Stop
        if ($dns.NameHost) {
            return $dns.NameHost
        }
    }
    catch {
        # DNSで取れなければ次へ
    }

    # 2. .NET の GetHostEntry を使う
    try {
        $entry = [System.Net.Dns]::GetHostEntry($IpAddress)
        if ($entry.HostName) {
            return $entry.HostName
        }
    }
    catch {
        # これもダメなら空文字
    }

    return ""  # どれも取れなければ空
}

# --- 設定読込 ---
if (Test-Path $ConfigPath) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $subnet   = $config.Subnet
    $start    = $config.StartHost
    $end      = $config.EndHost
}
else {
    Write-Warning "設定ファイルが見つかりません。デフォルト値を使用します。"
    $subnet   = "192.168.1"
    $start    = 1
    $end      = 254
}

# --- ログフォルダ ---
$rootDir  = Split-Path -Parent $PSScriptRoot
$logDir   = Join-Path $rootDir "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$csvPath   = Join-Path $logDir "LanScan_$timestamp.csv"

Write-Host "==== LAN スキャン開始 ====" -ForegroundColor Green

$results = @()

for ($i = $start; $i -le $end; $i++) {

    $ip = "$subnet.$i"
    Write-Host ("Ping -> {0}" -f $ip) -ForegroundColor Cyan

    # Windows PowerShell 5.1 用 Ping
    $alive = Test-Connection -ComputerName $ip -Count 1 -Quiet

    if ($alive) {

        # ホスト名取得
        try {
            $hostname = ([System.Net.Dns]::GetHostEntry($ip)).HostName
        }
        catch { $hostname = "" }

        # ② できるだけ正確にホスト名を取得（DNS逆引き＋既存情報）
        # 先に DNS から取りにいき、取れなければ従来の $hostname を使う
        $resolvedHost = Get-HostNameFromIP -IpAddress $ip
        if ([string]::IsNullOrWhiteSpace($resolvedHost)) {
            # すでにどこかで $hostname を計算している場合は、それをフォールバックに使う
            $resolvedHost = $hostname
        }
        $hostname = $resolvedHost

        # MACアドレス取得
        arp -a | Out-Null
        $arpEntry = arp -a | Select-String " $ip "
        $mac = ""
        if ($arpEntry) {
            $tok = ($arpEntry.ToString() -replace "\s+", " ").Trim().Split(" ")
            if ($tok.Count -ge 2) { $mac = $tok[1].ToUpper() }
        }

        # ベンダー名（Vendor）取得
        $vendor = ""
        if (-not [string]::IsNullOrWhiteSpace($mac)) {
            $vendor = Get-VendorFromMac $mac   # ← 先に作った関数を使う
        }

        # ③ ログ整形：Timestamp を ISO8601 形式に（後でグラフ化・解析しやすい）
        $timestamp = (Get-Date).ToString("o")  # 例: 2025-11-24T19:22:33.1234567+09:00

        $results += [pscustomobject]@{
            Timestamp = $timestamp;
            IP        = $ip;
            HostName  = $hostname;
            MAC       = $mac;
            Vendor    = $vendor;
        }
    }
}

# CSV 保存
$results | Sort-Object IP | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# JSON 保存（同じフォルダに）
$jsonPath = [System.IO.Path]::ChangeExtension($csvPath, ".json")
$results | Sort-Object IP | ConvertTo-Json -Depth 4 | Out-File $jsonPath -Encoding UTF8

Write-Host "スキャン完了。CSV と JSON を保存しました。" -ForegroundColor Green
Write-Host "CSV : $csvPath"
Write-Host "JSON: $jsonPath"
Write-Host "==========================" -ForegroundColor Green