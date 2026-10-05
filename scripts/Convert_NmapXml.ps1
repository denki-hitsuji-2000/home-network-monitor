param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --------------------------------------------------
# XML属性を取得する関数
#
# 属性が存在しない、または空文字列の場合は
# $nullを返す
# --------------------------------------------------
function Get-XmlAttributeOrNull {
    param(
        [AllowNull()]
        [System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Element) {
        return $null
    }

    $value = $Element.GetAttribute($Name)

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

try {
    # --------------------------------------------------
    # 入力XMLファイル確認
    # --------------------------------------------------
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "入力XMLファイルが存在しません: $InputPath"
    }

    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path

    # --------------------------------------------------
    # 設定ファイル確認
    # --------------------------------------------------
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "設定ファイルが存在しません: $ConfigPath"
    }

    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

    # --------------------------------------------------
    # 設定ファイル読込
    # --------------------------------------------------
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    # ルートディレクトリの設定
    $rootDir = $config.Paths.RootDirectory

    # --------------------------------------------------
    # 必要な設定項目を確認
    # --------------------------------------------------
    if ($config.Paths.PSObject.Properties.Name -notContains "Nmap") {
        throw "settings.jsonにNmapセクションがありません。"
    }

    if ($config.Paths.Nmap.PSObject.Properties.Name -notcontains "JsonDirectory") {
        throw "settings.jsonのNmapセクションにJsonDirectoryがありません。"
    }

    $outputDirectory = Join-Path -Path $rootDir -ChildPath ([string]$config.Paths.Nmap.JsonDirectory)

    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw "JsonDirectoryが空です。"
    }

    # --------------------------------------------------
    # JSON出力フォルダ作成
    # --------------------------------------------------
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    $resolvedOutputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path

    # --------------------------------------------------
    # XML読込
    # --------------------------------------------------
    $scan = New-Object System.Xml.XmlDocument

    # 外部リソースを読み込まない
    $scan.XmlResolver = $null

    $scan.Load($resolvedInputPath)

    # --------------------------------------------------
    # nmaprun要素確認
    # --------------------------------------------------
    $nmapRunMode = $scan.SelectSingleNode("/nmaprun")

    if ($null -eq $nmapRunMode) {
        throw "Nmap XMLとして認識できません。nmaprun要素が存在しません。"
    }

    # --------------------------------------------------
    # スキャン開始時刻取得
    #
    # Nmap XMLのstart属性はUNIX時刻
    # --------------------------------------------------
    $scanTime = $null

    $startText = Get-XmlAttributeOrNull -Element $nmapRunMode -Name "start"
    $unixTime = 0

    if ($null -ne $startText -and [long]::TryParse($startText, [ref]$unixTime)) {
        $scanTime = [DateTimeOffset]::FromUnixTimeSeconds($unixTime).ToLocalTime().ToString("o")
    }

    # --------------------------------------------------
    # ホスト情報抽出
    # --------------------------------------------------
    $hostResults = [System.Collections.Generic.List[object]]::new()
    $hostNodes = @($scan.SelectNodes("/nmaprun/host"))

    foreach ($hostNode in $hostNodes) {
        # ----------------------------------------------
        # ホスト状態
        # ----------------------------------------------
        $statusNode = $hostNode.SelectSingleNode("./status")
        $status = Get-XmlAttributeOrNull -Element $statusNode -Name "state"

        # ----------------------------------------------
        # IPv4アドレス
        # ----------------------------------------------
        $ipv4Node = $hostNode.SelectSingleNode("./address[@addrtype='ipv4']")
        $ipAddress = Get-XmlAttributeOrNull -Element $ipv4Node -Name "addr"

        # ----------------------------------------------
        # MACアドレス・ベンダー
        # ----------------------------------------------
        $macNode = $hostNode.SelectSingleNode("./address[@addrtype='mac']")
        $macAddress = Get-XmlAttributeOrNull -Element $macNode -Name "addr"
        $vendor = Get-XmlAttributeOrNull -Element $macNode -Name "vendor"

        # ----------------------------------------------
        # ホスト名
        #
        # 複数ある場合は最初のホスト名を使用
        # ----------------------------------------------
        $hostNameNode = $hostNode.SelectSingleNode("./hostnames/hostname[1]")
        $hostName = Get-XmlAttributeOrNull -Element $hostNameNode -Name "name"

        # ----------------------------------------------
        # ポート情報抽出
        # ----------------------------------------------
        $portResults = [System.Collections.Generic.List[object]]::new()
        $portNodes = @($hostNode.SelectNodes("./ports/port"))

        foreach ($portNode in $portNodes) {
            $protocol = Get-XmlAttributeOrNull -Element $portNode -Name "protocol"
            $portIdText = Get-XmlAttributeOrNull -Element $portNode -Name "portid"

            if ($null -eq $portIdText) {
                throw "port要素にportid属性がありません。入力XMLを確認してください。"
            }

            $portNumber = 0

            if (-not [int]::TryParse($portIdText, [ref]$portNumber)) {
                throw ("ポート番号を整数に変換できません。", $portIdText)
            }

            # ------------------------------------------
            # ポート状態
            # ------------------------------------------
            $stateNode = $portNode.SelectSingleNode("./state")
            $portState = Get-XmlAttributeOrNull -Element $stateNode -Name "state"

            # ------------------------------------------
            # サービス情報
            # ------------------------------------------
            $serviceNode = $portNode.SelectSingleNode("./service")
            $serviceName = Get-XmlAttributeOrNull -Element $serviceNode -Name "name"
            $product = Get-XmlAttributeOrNull -Element $serviceNode -Name "product"
            $version = Get-XmlAttributeOrNull -Element $serviceNode -Name "version"

            # ------------------------------------------
            # ポートオブジェクト作成
            # ------------------------------------------
            $portObject = [PSCustomObject]@{
                Protocol = $protocol
                Port     = $portNumber
                State    = $portState
                Service  = $serviceName
                Product  = $product
                Version  = $version
            }

            $portResults.Add($portObject)
        }

        # ----------------------------------------------
        # ホストオブジェクト作成
        # ----------------------------------------------
        $hostObject = [PSCustomObject]@{
            ScanTime  = $scanTime
            Status    = $status
            IpAddress = $ipAddress
            MacAddress = $macAddress
            Vendor    = $vendor
            HostName  = $hostName
            Ports     = $portResults.ToArray()
        }

        $hostResults.Add($hostObject)
    }

    # --------------------------------------------------
    # JSONファイル名生成
    #
    # nmap_yyyyMMdd_HHmmss.xml
    #              ↓
    # nmap_yyyyMMdd_HHmmss.json
    # --------------------------------------------------
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInputPath)
    $outputPath = Join-Path $resolvedOutputDirectory "$baseName.json"

    # --------------------------------------------------
    # JSON変換
    #
    # -InputObjectを使うことで、ホストが1台の場合でも
    # JSON配列として出力する
    # --------------------------------------------------
    $json = ConvertTo-Json -InputObject $hostResults.ToArray() -Depth 8

    # --------------------------------------------------
    # UTF-8 BOMなしでJSON保存
    # --------------------------------------------------
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText($outputPath, $json + [Environment]::NewLine, $utf8NoBom)

    # --------------------------------------------------
    # 完了表示
    # --------------------------------------------------
    Write-Host ""
    Write-Host "Nmap XML conversion completed."
    Write-Host "Input     : $resolvedInputPath"
    Write-Host "Output    : $outputPath"
    Write-Host "HostCount : $($hostResults.Count)"

    # 後の統括スクリプトから利用できるように
    # JSONファイルのパスを出力する
    Write-Output $outputPath
}
catch {
    Write-Error $_
    exit 1
}