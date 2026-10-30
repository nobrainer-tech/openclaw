param([int]$Port = 18793)
# Upgrade proof: jobs created by the latest stable release, then Doctor and the Gateway from this branch.
$ErrorActionPreference = 'Continue'
$entry = @('dist/index.mjs', 'dist/index.js') | Where-Object { Test-Path $_ } | Select-Object -First 1
$work = Join-Path $env:RUNNER_TEMP 'oc-upgrade'
New-Item -ItemType Directory -Force -Path "$work\home", "$work\state" | Out-Null
$env:OPENCLAW_HOME = "$work\home"; $env:OPENCLAW_STATE_DIR = "$work\state"; $env:OPENCLAW_CONFIG_PATH = "$work\state\openclaw.json"
foreach ($k in 'CHANNELS', 'GMAIL_WATCHER', 'CANVAS_HOST', 'ACPX_RUNTIME', 'ACPX_RUNTIME_PROBE') { Set-Item "env:OPENCLAW_SKIP_$k" '1' }
# Synthetic provider key: agent-turn jobs need a configured route to be accepted; no model is called.
$env:OPENAI_API_KEY = 'sk-proof-not-a-real-key'
$token = 'proof-upgrade'; $env:OPENCLAW_GATEWAY_TOKEN = $token
$cli = @('--port', $Port, '--token', $token)
$cleanPath = ($env:PATH -split ';' | Where-Object { $_ -notmatch '\\Git\\' -and $_ -notmatch 'msys|cygwin' }) -join ';'

function Start-Gw([string[]]$launch) {
  $saved = $env:PATH; $env:PATH = $cleanPath
  $script:gw = Start-Process -FilePath $launch[0] -ArgumentList (@($launch[1]) + @('gateway', '--port', $Port, '--bind', 'loopback', '--allow-unconfigured')) -RedirectStandardOutput "$work\gw-$($launch[2]).out" -RedirectStandardError "$work\gw-$($launch[2]).err" -PassThru -NoNewWindow
  $env:PATH = $saved
  for ($i = 0; $i -lt 60; $i++) { & $launch[0] $launch[1] cron status --json @cli *> $null; if ($LASTEXITCODE -eq 0) { return }; Start-Sleep 3 }
  Write-Host 'Gateway did not become ready'; Get-Content "$work\gw-*.err" -Tail 40; exit 1
}
function Stop-Gw {
  Stop-Process -Id $script:gw.Id -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "gateway --port $Port" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep 3
}
function Show-Job([string[]]$launch, [string]$id, [string]$label) {
  $j = & $launch[0] $launch[1] cron show $id --json @cli | ConvertFrom-Json
  if ($j.job) { $j = $j.job }
  Write-Host "[$label] payload: $($j.payload | ConvertTo-Json -Compress -Depth 5)"
}
function Run-Job([string[]]$launch, [string]$id, [string]$label) {
  $r = (& $launch[0] $launch[1] cron run $id --wait --json @cli | ConvertFrom-Json).run
  Write-Host "[$label] run status: $($r.status); summary: $($r.summary); error: $($r.error)"
}
function New-Job([string[]]$launch, [string[]]$jobArgs) {
  $j = & $launch[0] $launch[1] cron add --every 1h --no-deliver @jobArgs --json @cli | ConvertFrom-Json
  if ($j.job) { $j = $j.job }
  return $j.id
}

$stable = @('node', (Join-Path (npm root -g) 'openclaw\openclaw.mjs'), 'stable')
Write-Host "===== stable $(node $stable[1] --version) creates jobs ====="
Start-Gw $stable
$oldShellJobId = New-Job $stable @('--name', 'stable-shell', '--command', 'echo stable-shell-ok')
$argvId = New-Job $stable @('--name', 'stable-argv', '--command-argv', '["node","-e","console.log(\"argv-ok\")"]', '--timeout-seconds', '45', '--command-env', 'PROOF=1')
$legacyId = New-Job $stable @('--name', 'stable-legacy', '--message', "Command to run:`n- command: echo legacy-ok", '--tools', 'exec')
Show-Job $stable $oldShellJobId 'shell'; Show-Job $stable $argvId 'argv'; Show-Job $stable $legacyId 'legacy'
Stop-Gw

$branch = @('node', $entry, 'branch')
Write-Host '===== this branch: doctor --fix --non-interactive ====='
node $entry doctor --fix --non-interactive *> "$work\doctor.log"
Write-Host "doctor exit: $LASTEXITCODE"
Select-String -Path "$work\doctor.log" -Pattern 'command|cron' -SimpleMatch:$false | Select-Object -First 6 | ForEach-Object { $_.Line }

Write-Host '===== this branch: Gateway after upgrade ====='
Start-Gw $branch
Show-Job $branch $legacyId 'legacy'; Run-Job $branch $legacyId 'legacy'
Show-Job $branch $argvId 'argv'; Run-Job $branch $argvId 'argv'
Show-Job $branch $oldShellJobId 'shell'; Run-Job $branch $oldShellJobId 'shell'
Write-Host '----- documented recovery: cron edit --command -----'
node $entry cron edit $oldShellJobId --command 'echo stable-shell-ok' --json @cli *> $null
Show-Job $branch $oldShellJobId 'shell'; Run-Job $branch $oldShellJobId 'shell'
Stop-Gw
exit 0
