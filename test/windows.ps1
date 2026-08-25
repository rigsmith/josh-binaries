<#
.SYNOPSIS
Run the josh functional suites on Windows.

.DESCRIPTION
Locates Git Bash and runs the proxy round-trip suite and the CLI suite against
binaries you built, then prints a verdict. Both suites are hermetic: a local
git http server, no network, fresh temp dirs.

.PARAMETER BinDir
Directory holding josh-proxy.exe / josh.exe / josh-filter.exe
(e.g. C:\src\josh-master\target\release).

.PARAMETER PathForms
Also rerun the proxy suite with relative, space-laden and subst-drive cache
directories — the josh#2288 regression cases.

.EXAMPLE
.\test\windows.ps1 C:\src\josh-master\target\release
.EXAMPLE
.\test\windows.ps1 C:\src\josh-master\target\release -PathForms
#>
param(
  [Parameter(Mandatory = $true)][string]$BinDir,
  [switch]$PathForms
)

$ErrorActionPreference = 'Stop'

$bash = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw "Git Bash not found. Install Git for Windows (winget install Git.Git)." }

foreach ($tool in 'go', 'curl', 'git') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH. The suites need git, go and curl (winget install GoLang.Go)."
  }
}

$BinDir = (Resolve-Path $BinDir).Path
$proxy = Join-Path $BinDir 'josh-proxy.exe'
if (-not (Test-Path $proxy)) { throw "josh-proxy.exe not found in $BinDir — build it first." }

# Git Bash wants /c/... spellings for arguments it passes to native tools.
function To-BashPath([string]$p) {
  $p = $p -replace '\\', '/'
  if ($p -match '^([A-Za-z]):(.*)$') { return "/$($Matches[1].ToLower())$($Matches[2])" }
  return $p
}

$suite = Join-Path $PSScriptRoot 'roundtrip.sh'
$cli = Join-Path $PSScriptRoot 'cli.sh'
$results = [ordered]@{}

function Run-Suite([string]$name, [string[]]$bashArgs) {
  Write-Host "`n=== $name" -ForegroundColor Cyan
  & $bash @bashArgs
  $results[$name] = ($LASTEXITCODE -eq 0)
}

Run-Suite 'proxy round-trip' @((To-BashPath $suite), (To-BashPath $proxy))

if (Test-Path (Join-Path $BinDir 'josh.exe')) {
  Run-Suite 'cli' @((To-BashPath $cli), (To-BashPath $BinDir))
} else {
  Write-Warning "josh.exe not in $BinDir — skipping the CLI suite (cargo build -p josh-cli --release)"
}

if ($PathForms) {
  $tmp = $env:TEMP
  Run-Suite 'paths: relative' @((To-BashPath $suite), (To-BashPath $proxy), './josh-rel')
  Run-Suite 'paths: spaces'   @((To-BashPath $suite), (To-BashPath $proxy), (To-BashPath "$tmp\josh cache spaces"))
  subst X: $tmp 2>$null
  try   { Run-Suite 'paths: subst drive' @((To-BashPath $suite), (To-BashPath $proxy), '/x/josh-subst') }
  finally { subst X: /d 2>$null }
}

Write-Host "`n=== verdict" -ForegroundColor Cyan
foreach ($k in $results.Keys) {
  if ($results[$k]) { Write-Host "  PASS  $k" -ForegroundColor Green }
  else              { Write-Host "  FAIL  $k" -ForegroundColor Red }
}
if ($results.Values -contains $false) { exit 1 }
Write-Host "`nAll suites passed." -ForegroundColor Green
