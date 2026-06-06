# 変換元ファイル
$inputCsv  = "C:\NetworkMonitor\config\oui_raw.csv"      # 実際のファイルパスに合わせる
# 出力先ファイル
$outputJson = "C:\NetworkMonitor\config\oui.json"

Write-Host "OUI データベースの読み込み中..."

if (-not (Test-Path $inputCsv)) {
    Write-Error "入力CSVが見つかりません: $inputCsv"
    exit 1
}

# CSV 読み込み
$csv = Import-Csv $inputCsv

Write-Host "MAC ベンダー辞書を作成中..."

# 辞書（ハッシュテーブル）
$dict = @{}

foreach ($row in $csv) {

    # 列名は 'Assignment' と 'Organization Name' になっている想定
    $assignment = $row.Assignment
    $orgName    = $row.'Organization Name'

    # どちらかが空ならスキップ
    if ([string]::IsNullOrWhiteSpace($assignment) -or
        [string]::IsNullOrWhiteSpace($orgName)) {
        continue
    }

    # OUIを正規化：
    # 例: "FCA13E" / "FC-A1-3E" / "fc:a1:3e" などを "FC-A1-3E" に統一
    $clean = ($assignment -replace '[^0-9A-Fa-f]', '')
    if ($clean.Length -lt 6) { continue }

    $clean = $clean.Substring(0,6).ToUpper()
    $key   = "{0}-{1}-{2}" -f $clean.Substring(0,2), $clean.Substring(2,2), $clean.Substring(4,2)

    # 既に登録済みなら上書きしない（先勝ち）
    if (-not $dict.ContainsKey($key)) {
        $dict[$key] = $orgName.Trim()
    }
}

Write-Host "JSON に書き出し中…"
$dict | ConvertTo-Json -Depth 3 | Out-File $outputJson -Encoding UTF8

Write-Host "完了！ → $outputJson"
Write-Host ("登録件数: {0}" -f $dict.Count)
