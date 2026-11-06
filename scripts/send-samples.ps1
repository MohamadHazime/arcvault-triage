<#
.SYNOPSIS
  Sends the sample requests to the ArcVault intake webhook, one at a time, and checks the results.

.DESCRIPTION
  Simulates inbound traffic (email / web form / support portal) by POSTing each sample's
  {source, message} to the n8n webhook. Every response (the triage record built by the workflow)
  is collected into output/arcvault_output.json. Each record is then compared with the sample's
  "expected" block, and PASS/FAIL is printed per sample.

  An expected value of null means "not checked"; an array means "any of these values".
  Exit code: 0 if every request succeeded and matched, 1 otherwise.

  Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).

.EXAMPLE
  ./scripts/send-samples.ps1
.EXAMPLE
  ./scripts/send-samples.ps1 -Ids 3,7
.EXAMPLE
  ./scripts/send-samples.ps1 -DelaySeconds 0   # no pause (may hit the Groq free-tier rate limit)
#>
[CmdletBinding()]
param(
  [string]$Url = 'http://localhost:5678/webhook/arcvault-intake',
  [string]$SamplesPath,
  [string]$OutputPath,
  # string[] rather than int[]: via `powershell -File`, "-Ids 1,3" arrives as the single string "1,3",
  # which an int[] parameter would silently turn into 13.
  [string[]]$Ids,
  # Pause between requests. Each request makes LLM calls; the Groq free tier allows ~8K tokens/minute.
  [int]$DelaySeconds = 20
)

$ErrorActionPreference = 'Stop'

# Defaults are resolved here, not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot empty
# inside param() defaults when the script is launched with `powershell -File`.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SamplesPath) { $SamplesPath = Join-Path $scriptDir '..\samples\requests.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $scriptDir '..\output\arcvault_output.json' }
$inv = [Globalization.CultureInfo]::InvariantCulture

# --- JSON writer -------------------------------------------------------------------------------
# Windows PowerShell 5.1's ConvertTo-Json escapes characters like ' as ' and pads its
# indentation unevenly. This small writer keeps the deliverable readable: 2-space indent, real UTF-8.
function ConvertTo-JsonString([string]$s) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($c in $s.ToCharArray()) {
    switch ($c) {
      '"'  { [void]$sb.Append('\"') }
      '\'  { [void]$sb.Append('\\') }
      "`n" { [void]$sb.Append('\n') }
      "`r" { [void]$sb.Append('\r') }
      "`t" { [void]$sb.Append('\t') }
      default {
        if ([int]$c -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) }
      }
    }
  }
  [void]$sb.Append('"')
  $sb.ToString()
}

function ConvertTo-PrettyJson($value, [int]$level = 0) {
  $pad = '  ' * $level
  $padIn = '  ' * ($level + 1)
  if ($null -eq $value) { return 'null' }
  if ($value -is [bool]) { return $value.ToString().ToLowerInvariant() }
  if ($value -is [string]) { return ConvertTo-JsonString $value }
  if ($value -is [datetime]) { return ConvertTo-JsonString ($value.ToUniversalTime().ToString('o', $inv)) }
  if ($value -is [ValueType]) { return ([IFormattable]$value).ToString($null, $inv) }
  if ($value -is [Collections.IDictionary]) {
    $keys = @($value.Keys)
    if ($keys.Count -eq 0) { return '{}' }
    $parts = foreach ($k in $keys) { $padIn + (ConvertTo-JsonString ([string]$k)) + ': ' + (ConvertTo-PrettyJson $value[$k] ($level + 1)) }
    return "{`n" + ($parts -join ",`n") + "`n$pad}"
  }
  if ($value -is [Collections.IEnumerable]) {
    $items = @($value)
    if ($items.Count -eq 0) { return '[]' }
    $parts = foreach ($i in $items) { $padIn + (ConvertTo-PrettyJson $i ($level + 1)) }
    return "[`n" + ($parts -join ",`n") + "`n$pad]"
  }
  # PSCustomObject (what ConvertFrom-Json / Invoke-RestMethod return): keep property order.
  $props = @($value.PSObject.Properties)
  if ($props.Count -eq 0) { return '{}' }
  $parts = foreach ($p in $props) { $padIn + (ConvertTo-JsonString $p.Name) + ': ' + (ConvertTo-PrettyJson $p.Value ($level + 1)) }
  return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

# --- Load samples ------------------------------------------------------------------------------
$samples = Get-Content -LiteralPath $SamplesPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Ids) {
  $idList = @($Ids -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [int]$_.Trim() })
  $samples = @($samples | Where-Object { $idList -contains $_.id })
}
if (-not $samples) { throw "No samples selected from $SamplesPath" }

Write-Host "Sending $(@($samples).Count) sample(s) to $Url" -ForegroundColor Cyan
Write-Host ''

$records = New-Object Collections.Generic.List[object]
$passed = 0
$first = $true

foreach ($s in $samples) {
  if (-not $first -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
  $first = $false
  # Send the body as UTF-8 bytes: PS 5.1 would otherwise mangle characters such as the em dash in sample 5.
  $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PrettyJson ([ordered]@{ source = $s.source; message = $s.message })))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $record = Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
  } catch {
    $sw.Stop()
    Write-Host ("#{0}  ERROR  {1}" -f $s.id, $_.Exception.Message) -ForegroundColor Red
    $records.Add([ordered]@{ sample_id = $s.id; source = $s.source; raw_message = $s.message; error = $_.Exception.Message })
    continue
  }
  $sw.Stop()
  $records.Add($record)

  # Compare against the expected block (null = not checked, array = any of).
  $mismatches = @()
  foreach ($p in $s.expected.PSObject.Properties) {
    $want = $p.Value
    if ($null -eq $want) { continue }
    $got = $record.($p.Name)
    $ok = if ($want -is [array]) { $want -contains $got } else { $got -eq $want }
    if (-not $ok) {
      $wantText = if ($want -is [array]) { $want -join ' | ' } else { "$want" }
      $mismatches += ("{0}: expected '{1}', got '{2}'" -f $p.Name, $wantText, $got)
    }
  }

  $summary = "{0} | {1} | {2} | escalated={3}" -f $record.category, $record.priority, $record.destination_queue, $record.escalated
  $secs = ($sw.Elapsed.TotalSeconds).ToString('0.0', $inv)
  if ($mismatches.Count -eq 0) {
    $passed++
    Write-Host ("#{0}  PASS  ({1}s)  {2}" -f $s.id, $secs, $summary) -ForegroundColor Green
  } else {
    Write-Host ("#{0}  FAIL  ({1}s)  {2}" -f $s.id, $secs, $summary) -ForegroundColor Red
    foreach ($m in $mismatches) { Write-Host "      - $m" -ForegroundColor Yellow }
  }
}

# --- Write the deliverable ---------------------------------------------------------------------
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$json = ConvertTo-PrettyJson $records.ToArray()
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json + "`n", (New-Object Text.UTF8Encoding($false)))

$total = @($samples).Count
Write-Host ''
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("{0}/{1} matched expected results. Output written to {2}" -f $passed, $total, [IO.Path]::GetFullPath($OutputPath)) -ForegroundColor $color
if ($passed -ne $total) { exit 1 }
exit 0
