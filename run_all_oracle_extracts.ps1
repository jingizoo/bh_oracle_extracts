param(
  [Parameter(Mandatory = $true)]
  [string]$PythonExe,

  [Parameter(Mandatory = $true)]
  [string]$OracleExtractPy,

  [Parameter(Mandatory = $true)]
  [string]$OracleUser,

  [Parameter(Mandatory = $true)]
  [string]$OraclePassword,

  [Parameter(Mandatory = $true)]
  [string]$OracleConnect,

  [Parameter(Mandatory = $true)]
  [string]$DuckDB,

  [Parameter(Mandatory = $true)]
  [string]$ManifestCsv,

  [int]$ArraySize = 10000,
  [int]$FetchSize = 10000,

  [switch]$QuoteAll,
  [switch]$ExcelBom,

  # If set, the script stops on the first failure (recommended).
  [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  try { return (Resolve-Path -LiteralPath $p).Path } catch { return $p }
}

$PythonExe = Resolve-AbsPath $PythonExe
$OracleExtractPy = Resolve-AbsPath $OracleExtractPy
$ManifestCsv = Resolve-AbsPath $ManifestCsv
$DuckDB = Resolve-AbsPath $DuckDB

if (-not (Test-Path -LiteralPath $PythonExe)) { throw "Python exe not found: $PythonExe" }
if (-not (Test-Path -LiteralPath $OracleExtractPy)) { throw "oracle_extract.py not found: $OracleExtractPy" }
if (-not (Test-Path -LiteralPath $ManifestCsv)) { throw "Manifest CSV not found: $ManifestCsv" }

$rows = Import-Csv -LiteralPath $ManifestCsv
if (-not $rows -or $rows.Count -eq 0) { throw "Manifest has no rows: $ManifestCsv" }

Write-Host "Manifest: $ManifestCsv"
Write-Host "DuckDB:   $DuckDB"
Write-Host "Oracle:   $OracleConnect"
Write-Host ""

$idx = 0
foreach ($r in $rows) {
  $idx++
  $enabled = ($r.enabled -as [string]).Trim()
  if ($enabled -eq '0' -or $enabled -eq '' -or $enabled.ToLower() -eq 'false') {
    Write-Host "[$idx/$($rows.Count)] SKIP (enabled=$enabled)"
    continue
  }

  $sqlPath = ($r.sql_path -as [string]).Trim()
  $fileType = ($r.file_type -as [string]).Trim()
  $duckTable = ($r.duckdb_table -as [string]).Trim()
  $outCsv = ($r.output_csv -as [string]).Trim()

  if ([string]::IsNullOrWhiteSpace($sqlPath)) { throw "Row $idx missing sql_path" }
  if ([string]::IsNullOrWhiteSpace($fileType)) { throw "Row $idx missing file_type" }
  if (-not (Test-Path -LiteralPath $sqlPath)) { throw "Row $idx sql_path not found: $sqlPath" }

  $args = @(
    $OracleExtractPy,
    $sqlPath,
    '-u', $OracleUser,
    '-p', $OraclePassword,
    '-c', $OracleConnect,
    '--file-type', $fileType,
    '--duckdb', $DuckDB,
    '--arraysize', "$ArraySize",
    '--fetch-size', "$FetchSize"
  )

  if (-not [string]::IsNullOrWhiteSpace($duckTable)) {
    $args += @('--duckdb-table', $duckTable)
  }
  if (-not [string]::IsNullOrWhiteSpace($outCsv)) {
    $args += @('-o', $outCsv)
  }
  if ($QuoteAll) { $args += '--quote-all' }
  if ($ExcelBom) { $args += '--excel-bom' }

  Write-Host "[$idx/$($rows.Count)] RUN: $fileType"
  Write-Host "  SQL:   $sqlPath"
  Write-Host "  Table: $duckTable"
  if ($outCsv) { Write-Host "  CSV:   $outCsv" }

  & $PythonExe @args
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "✗ FAILED: exit code $code (row $idx, file_type=$fileType)" -ForegroundColor Red
    if ($StopOnError) { exit $code }
  } else {
    Write-Host "✓ OK" -ForegroundColor Green
  }

  Write-Host ""
}

Write-Host "Done."
exit 0

