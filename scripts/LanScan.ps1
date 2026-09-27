# --- パラメータ ---
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json",
    # 指定された場合だけsettings.jsonより優先する
    [string]$Cidr
)

Write-Host "設定ファイルの読み込み中: $ConfigPath"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "設定ファイルが見つかりません: $ConfigPath"
    exit 1
}

# JSON設定ファイルを読み込み
$config = Get-Content $ConfigPath -Encoding UTF8 | ConvertFrom-Json
# ルートディレクトリの設定
$rootDir = $config.Paths.RootDirectory

# --- OUI データベースの読み込み ---
$ouiPath = Join-Path $rootDir $config.Paths.Config.OuiJson
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

function Convert-IPv4ToUInt32 {
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress
    )

    $parsedAddress = [System.Net.IPAddress]::Parse($IpAddress)
    $bytes = $parsedAddress.GetAddressBytes()

    if ($bytes.Length -ne 4) {
        throw "IPv4アドレスではありません: $IpAddress"
    }

    $value = 
        ([UInt64]$bytes[0] * 16777216) +
        ([UInt64]$bytes[1] * 65536) +
        ([UInt64]$bytes[2] * 256) +
        ([UInt64]$bytes[3])
    
    return [UInt32]$value
}

function Convert-UInt32ToIPv4 {
    param (
        [Parameter(Mandatory)]
        [UInt32]$Value
    )

    return "{0}.{1}.{2}.{3}" -f `
        (([UInt64]$Value -shr 24) -band 255),
        (([UInt64]$Value -shr 16) -band 255),
        (([UInt64]$Value -shr 8) -band 255),
        ([UInt64]$Value -band 255)    
}

function Get-IPv4HostAddress {
    param (
        [Parameter(Mandatory)]
        [string]$Cidr,

        # 誤って非常に大きなネットワークを指定することを防止する
        [int]$MaximumHosts = 4096
    )
    
    $parts = $Cidr.Trim().Split('/')

    if ($parts.Count -ne 2) {
        throw "CIDRの形式が正しくありません: $Cidr"
    }

    $baseAddress = $parts[0]

    try {
        $prefixLength = [int]$parts[1]
    }
    catch {
        throw "プレフィックス長が正しくありません: $Cidr"
    }

    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "プレフィックス長は0~32で指定してください: $Cidr"
    }

    $ipValue = Convert-IPv4ToUInt32 -IpAddress $baseAddress
    $blockSize = [UInt64][System.Math]::Pow(2, (32 - $prefixLength))

    # 入力が192.168.0.15/24でも192.168.0.0を求める
    $networkValue = [UInt64]$ipValue - ([UInt64]$ipValue % $blockSize)

    if ($prefixLength -eq 32) {
        $firstHost = $networkValue
        $hostCount = [UInt64]1
    }
    elseif ($prefixLength -eq 31) {
        $firstHost = $networkValue
        $hostCount = [UInt64]2
    }
    else {
        # ネットワークアドレスとブロードキャストアドレスを除外
        $firstHost = $networkValue + 1
        $hostCount = $blockSize - 2
    }

    if ($hostCount -gt $MaximumHosts) {
        throw "スキャン対象が上限を超えています。CIDR=$Cidr 対象数=$hostCount 上限=$MaximumHosts"
    }

    for ([UInt64]$offset = 0; $offset -lt $hostCount; $offset++) {
        $currentAddress = [UInt32]($firstHost + $offset)
        Convert-UInt32ToIPv4 -Value $currentAddress
    }
}

# --- 設定読込 ---
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "設定ファイルが見つかりません: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# CIDRを決定する
if ($PSBoundParameters.ContainsKey('Cidr')) {
    $scanCidr = $Cidr
    Write-Host "パラメータ指定のCIDRを使用します: $scanCidr"
}
else {
    $scanCidr = [string]$config.Network.Cidr
    Write-Host "settings.jsonのCIDRを使用します: $scanCidr"
}

if ([string]::IsNullOrWhiteSpace($scanCidr)) {
    throw "Network.Cidrが設定されていません。"
}

$targetAddress = @(Get-IPv4HostAddress -Cidr $scanCidr -MaximumHosts 4096)

Write-Host "スキャン対象数: $($targetAddress.Count)"

# --- ログフォルダ ---
$logDir   = Join-Path $rootDir $config.Paths.LanScan.OutputDirectory
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$csvPath   = Join-Path $logDir "LanScan_$timestamp.csv"

Write-Host "==== LAN スキャン開始 ====" -ForegroundColor Green

$results = @()

foreach ($ip in $targetAddress) {
    Write-Host "確認中: $ip" -ForegroundColor Cyan

    # Windows PowerShell 5.1 用 Ping
    $alive = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue

    if (-not $alive) {
        continue
    }

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
