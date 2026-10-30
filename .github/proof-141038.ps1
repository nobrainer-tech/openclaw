param([string]$Label, [int]$Port)
$ErrorActionPreference = 'Continue'
$entry = @('dist/index.mjs', 'dist/index.js') | Where-Object { Test-Path $_ } | Select-Object -First 1
Write-Host "===== $Label (entry $entry) ====="
$work = Join-Path $env:RUNNER_TEMP "oc-$Label"
New-Item -ItemType Directory -Force -Path "$work\home", "$work\state" | Out-Null
$env:OPENCLAW_HOME = "$work\home"; $env:OPENCLAW_STATE_DIR = "$work\state"; $env:OPENCLAW_CONFIG_PATH = "$work\state\openclaw.json"
foreach ($k in 'CHANNELS', 'GMAIL_WATCHER', 'CANVAS_HOST', 'ACPX_RUNTIME', 'ACPX_RUNTIME_PROBE') { Set-Item "env:OPENCLAW_SKIP_$k" '1' }
$token = "proof-$Label"; $env:OPENCLAW_GATEWAY_TOKEN = $token
$cli = @('--port', $Port, '--token', $token)

# Mirror the issue: a Windows Gateway without sh on PATH (the Git for Windows default).
$savedPath = $env:PATH
$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch '\\Git\\' -and $_ -notmatch 'msys|cygwin' }) -join ';'
Write-Host "sh on Gateway PATH: $([bool](Get-Command sh -ErrorAction SilentlyContinue))"
$gw = Start-Process -FilePath node -ArgumentList $entry, 'gateway', '--port', $Port, '--bind', 'loopback', '--allow-unconfigured' -RedirectStandardOutput "$work\gw.out" -RedirectStandardError "$work\gw.err" -PassThru -NoNewWindow
$env:PATH = $savedPath

$ready = $false
for ($i = 0; $i -lt 60; $i++) {
  node $entry cron status --json @cli *> $null
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  if ($gw.HasExited) { break }
  Start-Sleep 3
}
if (-not $ready) {
  Write-Host "Gateway did not become ready"; Get-Content "$work\gw.out", "$work\gw.err" -Tail 60; exit 1
}

function Show-Run([string]$name, [string]$command) {
  node $entry cron add --name $name --every 1h --no-deliver --command $command --json @cli > "$work\$name-add.json" 2> "$work\$name-add.err"
  $raw = Get-Content "$work\$name-add.json" -Raw
  if ($LASTEXITCODE -ne 0 -or -not $raw) { Write-Host "cron add failed:"; Get-Content "$work\$name-add.err" -Tail 10; return }
  $job = $raw | ConvertFrom-Json
  if ($job.job) { $job = $job.job }
  Write-Host "[$name] command: $command"
  Write-Host "[$name] stored argv: $($job.payload.argv | ConvertTo-Json -Compress)"
  node $entry cron run $job.id --wait --json @cli > "$work\$name-run.json" 2>&1
  $run = (Get-Content "$work\$name-run.json" -Raw | ConvertFrom-Json).run
  Write-Host "[$name] run status: $($run.status); summary: $($run.summary); error: $($run.error)"
}

$platform = (node $entry gateway call system.info --params '{}' --json @cli | ConvertFrom-Json).platform
Write-Host "Gateway system.info platform: $platform"
Show-Run 'plain' 'echo hello-from-windows-cron'
$node = (Get-Command node).Source
Show-Run 'quoted' ('"' + $node + '" -e "console.log(''quoted-ok'')"')

Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "--port $Port" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
exit 0
