<#
  Industrial Machine Performance Analytics -- SQL pipeline.

      .\run_pipeline.ps1

  build model -> quality gate -> health & reliability -> root cause analysis
  Output: outputs\*.csv

  Then run the Python layer for the degradation curve, detection scoring and charts:
      pip install -r requirements.txt
      python python\predictive_maintenance.py
#>
param(
    [switch]$SkipDownload,
    [string]$DuckDb = ".\tools\duckdb.exe"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# ---- 0. dependencies ---------------------------------------------------------
if (-not (Test-Path $DuckDb)) {
    Write-Host "DuckDB CLI not found - fetching portable binary..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path ".\tools" | Out-Null
    (New-Object System.Net.WebClient).DownloadFile(
        "https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-windows-amd64.zip",
        ".\tools\duckdb.zip")
    Expand-Archive ".\tools\duckdb.zip" -DestinationPath ".\tools" -Force
    Remove-Item ".\tools\duckdb.zip" -Force
}

if (-not $SkipDownload -and -not (Test-Path ".\data\raw\PdM_telemetry.csv")) {
    Write-Host "Raw data missing - downloading (~77 MB)..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File ".\data\download_data.ps1"
}

New-Item -ItemType Directory -Force -Path ".\outputs", ".\assets" | Out-Null
$db = ".\outputs\machines.duckdb"
if (Test-Path $db) { Remove-Item $db -Force }

# ---- 1..4 --------------------------------------------------------------------
$steps = @(
    @{ n = "1/4  Building model from both sensor feeds"; f = "sql/01_build_model.sql"        },
    @{ n = "2/4  Data-quality gate";                     f = "sql/02_data_quality.sql"       },
    @{ n = "3/4  Health, reliability and fault mix";     f = "sql/03_machine_health.sql"     },
    @{ n = "4/4  Root cause analysis";                   f = "sql/04_root_cause_analysis.sql"}
)
foreach ($s in $steps) {
    Write-Host ""
    Write-Host ("[{0}]" -f $s.n) -ForegroundColor Cyan
    & $DuckDb $db -c (".read {0}" -f $s.f)
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $($s.f)" }
}

Write-Host ""
Write-Host "SQL pipeline complete. Published marts:" -ForegroundColor Green
Get-ChildItem ".\outputs" -Filter *.csv | Sort-Object Name |
    ForEach-Object { "   {0,-42} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "Next (Python layer):" -ForegroundColor Green
Write-Host "   pip install -r requirements.txt"
Write-Host "   python python\predictive_maintenance.py"
