param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json",
    # 指定された場合だけsettings.jsonより優先する
    [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {

    # --------------------------------------------------
    # 設定ファイル確認
    # --------------------------------------------------
    if (-not (Test-Path $ConfigPath)) {
        throw "設定ファイルが存在しません: $ConfigPath"
    }

    # JSON設定ファイルを読み込む
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # ルートディレクトリの設定
    $rootDir = $config.Paths.RootDirectory
    
    # --------------------------------------------------
    # 設定値取得
    # --------------------------------------------------
    $nmapPath = $config.Nmap.ExecutablePath

    if ([string]::IsNullOrWhiteSpace($Target)) {
        $scanTarget = [string]$config.Network.Cidr
    }
    else {
        $scanTarget = $Target
    }

    if ([string]::IsNullOrWhiteSpace($scanTarget)) {
        throw "Nmapのスキャン対象が設定されていません。"
    }

    $xmlDirectory = Join-Path $rootDir $config.Paths.Nmap.XmlDirectory
    $runLogDirectory = Join-Path $rootDir $config.Paths.Nmap.RunLogDirectory

    # --------------------------------------------------
    # Nmap存在確認
    # --------------------------------------------------
    if (-not (Test-Path $nmapPath)) {
        throw "nmap.exe が見つかりません: $nmapPath"
    }

    # --------------------------------------------------
    # 出力フォルダ作成
    # --------------------------------------------------
    foreach ($directory in @($xmlDirectory, $runLogDirectory)) {
        if (-not (Test-Path $directory)) {
            New-Item `
            -Path $directory `
            -ItemType Directory `
            -Force |
            Out-Null
        }
    }

    # --------------------------------------------------
    # ファイル名生成
    # --------------------------------------------------
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    $xmlPath = Join-Path $xmlDirectory "nmap_$timestamp.xml"
    
    $logPath = Join-Path $runLogDirectory "nmap_$timestamp.log"

    # --------------------------------------------------
    # Nmap引数
    # --------------------------------------------------
    $nmapArguments = @("-sV", "-oX", $xmlPath, $scanTarget)

    # --------------------------------------------------
    # Nmap実行
    # --------------------------------------------------
    Write-Host "==== Nmap scan start ====" -ForegroundColor Green
    Write-Host "Target : $scanTarget"
    Write-Host "XML    : $xmlPath"

    & $nmapPath @nmapArguments *> $logPath

    $exitCode = $LASTEXITCODE

    # --------------------------------------------------
    # 終了コード確認
    # --------------------------------------------------
    if ($exitCode -ne 0) {
        throw "Nmapが異常終了しました。 ExitCode=$exitCode"
    }

    # --------------------------------------------------
    # XML生成確認
    # --------------------------------------------------
    if (-not (Test-Path $xmlPath)) {
        throw "Nmapは終了しましたが、XMLファイルが生成されていません。"
    }

    Write-Host ""
    Write-Host "Nmap scan completed." -ForegroundColor Green
    Write-Host "XML : $xmlPath"
    Write-Host "Log : $logPath"
    Write-Host "==========================" -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}