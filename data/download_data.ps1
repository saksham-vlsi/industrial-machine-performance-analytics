<#
  Downloads both raw sensor feeds. Run once from the repository root:
      powershell -ExecutionPolicy Bypass -File .\data\download_data.ps1

  TELEMETRY FEED  Azure Predictive Maintenance (MIT licence)
                  876,100 hourly readings, 100 machines, 2015
  PROCESS FEED    AI4I 2020 -- UCI ML Repository (CC BY 4.0)
                  https://archive.ics.uci.edu/dataset/601/ai4i+2020+predictive+maintenance+dataset

  ~77 MB total. The CSVs are gitignored so the repository stays small.
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $PSScriptRoot "raw"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$wc = New-Object System.Net.WebClient

# ---- 1. Azure Predictive Maintenance -----------------------------------------
# PdM_telemetry is stored with Git LFS in its mirror, so it is fetched through
# the media endpoint; the four smaller tables come from raw.githubusercontent.
$files = @{
    "PdM_telemetry.csv" = "https://media.githubusercontent.com/media/Ravikumar10593-hub/dbt-snowfalkes-project/master/seeds/PdM_telemetry.csv"
    "PdM_errors.csv"    = "https://raw.githubusercontent.com/aryawiandra/asset-health-monitoring/main/data/raw/PdM_errors.csv"
    "PdM_failures.csv"  = "https://raw.githubusercontent.com/aryawiandra/asset-health-monitoring/main/data/raw/PdM_failures.csv"
    "PdM_maint.csv"     = "https://raw.githubusercontent.com/aryawiandra/asset-health-monitoring/main/data/raw/PdM_maint.csv"
    "PdM_machines.csv"  = "https://raw.githubusercontent.com/aryawiandra/asset-health-monitoring/main/data/raw/PdM_machines.csv"
}
foreach ($name in $files.Keys) {
    Write-Host ("  downloading {0} ..." -f $name) -NoNewline
    $wc.DownloadFile($files[$name], (Join-Path $dest $name))
    Write-Host (" {0:N0} KB" -f ((Get-Item (Join-Path $dest $name)).Length / 1KB))
}

# ---- 2. AI4I 2020 (UCI) --------------------------------------------------------
Write-Host "  downloading ai4i2020.csv ..." -NoNewline
$zip = Join-Path $env:TEMP "ai4i2020.zip"
$wc.DownloadFile("https://archive.ics.uci.edu/static/public/601/ai4i+2020+predictive+maintenance+dataset.zip", $zip)
Expand-Archive $zip -DestinationPath (Join-Path $env:TEMP "ai4i") -Force
Copy-Item (Join-Path $env:TEMP "ai4i\ai4i2020.csv") $dest -Force
Remove-Item $zip -Force
Write-Host (" {0:N0} KB" -f ((Get-Item (Join-Path $dest "ai4i2020.csv")).Length / 1KB))
$wc.Dispose()

Write-Host ""
Get-ChildItem $dest -Filter *.csv | ForEach-Object { "   {0,-26} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "Raw data ready. Next: .\run_pipeline.ps1" -ForegroundColor Green
