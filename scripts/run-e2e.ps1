#Requires -Version 7.0
<#
.SYNOPSIS
  End-to-end orchestrator: provision, RBAC, deploy 4 hosted agents, drive
  traffic, register continuous-eval rule + custom evaluator, fire one-shot
  batch eval, run red team, create alerts, export telemetry.

  Mirrors docs/MANUAL_GUIDE.md Steps 1-10 and docs/QUICKSTART.md.

.PARAMETER Region
  Azure region for the Foundry account. Default: eastus2.

.PARAMETER EnvName
  azd env name (also resource group suffix). Default: aiobs-foundry-<yyyymmdd>.

.PARAMETER SubscriptionId
  Target subscription. If omitted, uses the current az/azd context.

.PARAMETER SkipPhases
  Comma-separated phase numbers to skip (e.g. "9,10" to skip batch eval + red team).

.PARAMETER MaxPrompts
  Maximum prompts to send in Phase 6 seed traffic. Default: 10. Use 0 for no limit (~48 prompts).
#>
[CmdletBinding()]
param(
    [string]$Region = 'eastus2',
    [string]$EnvName = ('aiobs-foundry-' + (Get-Date -Format 'yyyyMMdd')),
    [string]$SubscriptionId,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$SkipPhases = '',
    [int]$MaxPrompts = 10
)

# Parse SkipPhases from comma-separated string to int array (pwsh -File passes arrays as strings).
$SkipPhasesList = @()
if ($SkipPhases) {
    $SkipPhasesList = $SkipPhases -split ',' | ForEach-Object { [int]$_.Trim() }
}

$ErrorActionPreference = 'Stop'
$AZD = if (Test-Path "$env:LOCALAPPDATA\Programs\azd-local\azd.exe") {
    "$env:LOCALAPPDATA\Programs\azd-local\azd.exe"
} else { 'azd' }
$AgentDir = Join-Path $RepoRoot 'agent'
$ScriptsDir = Join-Path $RepoRoot 'scripts'
$VenvPython = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogRoot = Join-Path $RepoRoot "artifacts\e2e-$Stamp"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

# Suppress azd interactive progress spinners so Tee-Object doesn't block.
$env:NO_COLOR = '1'
$env:TERM = 'dumb'
$env:AZD_CONSOLE_NO_SPINNER = '1'
$env:CI = '1'

function Write-Phase {
    param([int]$N, [string]$Title, [string]$Description)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ("PHASE {0}: {1}" -f $N, $Title) -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    if ($Description) {
        Write-Host "  Goal: $Description" -ForegroundColor White
    }
}

function Invoke-Phase {
    param([int]$N, [string]$Title, [string]$Description, [scriptblock]$Body)
    if ($SkipPhasesList -contains $N) {
        Write-Host "Skipping phase $N ($Title)" -ForegroundColor Yellow
        return
    }
    Write-Phase $N $Title $Description
    $log = Join-Path $LogRoot ("phase-{0:D2}.log" -f $N)
    Write-Host "  Log: $log" -ForegroundColor DarkGray
    Write-Host ''
    try {
        # Write to log file and stream to console line-by-line.
        # Avoids Tee-Object which blocks on azd's ANSI progress spinners.
        & $Body 2>&1 | ForEach-Object {
            $line = $_ | Out-String -Stream
            $line | Out-File -Append -FilePath $log -Encoding utf8
            Write-Host $line
        }
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Phase $N exited with code $LASTEXITCODE. See $log"
        }
    } catch {
        Write-Host "Phase $N FAILED: $_" -ForegroundColor Red
        Write-Host "Log: $log"
        throw
    }
}

# --- Validate prereqs ---
Write-Host ''
Write-Host 'Pre-flight checks:' -ForegroundColor Cyan

if (-not (Test-Path $VenvPython)) {
    throw "Python venv not found at $VenvPython. Create it per docs/QUICKSTART.md Step 0."
}
# Verify the venv Python actually works (not a broken symlink to a deleted base interpreter)
$pyTest = & $VenvPython --version 2>&1
if ($LASTEXITCODE -ne 0 -or $pyTest -match 'No Python at') {
    throw "Python venv is broken: $pyTest. Rebuild with: py -3.13 -m venv .venv"
}
Write-Host "  [OK] Python venv ($pyTest)" -ForegroundColor Green

if (-not (Test-Path $AgentDir)) { throw "Agent dir not found: $AgentDir" }
Write-Host "  [OK] Agent dir" -ForegroundColor Green

# azd
$azdVer = & $AZD version 2>&1
if ($LASTEXITCODE -ne 0) { throw "azd not found. Install via: winget install Microsoft.Azd" }
Write-Host "  [OK] azd $($azdVer -replace '\s+', ' ')" -ForegroundColor Green

# az CLI
$azVer = (az version 2>&1 | ConvertFrom-Json).'azure-cli'
if (-not $azVer) { throw "az CLI not found. Install via: winget install Microsoft.AzureCLI" }
Write-Host "  [OK] az CLI $azVer" -ForegroundColor Green

# Docker (required for azd deploy to push container images to ACR)
$dockerVer = docker version --format '{{.Client.Version}}' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Docker is not running. azd deploy needs Docker to build and push agent containers to ACR. Start Docker Desktop and try again."
}
Write-Host "  [OK] Docker $dockerVer" -ForegroundColor Green

# az login check
$azAccount = az account show --query '{name:name, id:id}' -o json 2>&1 | ConvertFrom-Json
if (-not $azAccount.id) { throw "Not logged in to az CLI. Run: az login" }
Write-Host "  [OK] Logged in: $($azAccount.name) ($($azAccount.id))" -ForegroundColor Green

Write-Host ''
Write-Host 'All pre-flight checks passed.' -ForegroundColor Green
Write-Host ''
Write-Host "Repo:    $RepoRoot"
Write-Host "Region:  $Region"
Write-Host "EnvName: $EnvName"
Write-Host "Logs:    $LogRoot"

$YourPrincipalId = (az ad signed-in-user show --query id -o tsv).Trim()
if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv).Trim()
}

# ========================================================================
# PHASE 1: provision (azd up)
# ========================================================================
Invoke-Phase 1 'Provision infrastructure (azd provision)' `
    'Creates the Azure resource group + all infrastructure: Foundry account, project, ACR, App Insights, Log Analytics, model deployment. Does NOT deploy agents (Phases 3 and 5 do that; Foundry auto-creates the project agentIdentity on first agent deploy).' `
    {
    Push-Location $AgentDir
    try {
        # Create env if missing.
        $envs = & $AZD env list --output json | ConvertFrom-Json
        if (-not ($envs | Where-Object { $_.Name -eq $EnvName })) {
            'n' | & $AZD env new $EnvName -l $Region --subscription $SubscriptionId
        }
        & $AZD env select $EnvName
        & $AZD env set MODEL_DEPLOYMENT_NAME gpt-4o-mini
        & $AZD env set MODEL_NAME            gpt-4o-mini
        & $AZD env set MODEL_VERSION         2024-07-18
        & $AZD env set MODEL_FORMAT          OpenAI
        & $AZD env set MODEL_SKU_NAME        GlobalStandard
        & $AZD env set MODEL_CAPACITY        30
        & $AZD env set AZURE_PRINCIPAL_ID    $YourPrincipalId
        # enableHostedAgents=true and enableCapabilityHost=false in
        # main.parameters.json. With capability host disabled, Foundry v2
        # hosted agents auto-create the project agentIdentity on first deploy.
        & $AZD provision --no-prompt
    } finally { Pop-Location }
}

# Hydrate env vars from azd into this process for the rest of the run.
Push-Location $AgentDir
try {
    # Always select the target env (Phase 1 may have been skipped).
    & $AZD env select $EnvName 2>$null

    # Ensure AZURE_TENANT_ID is set in the azd env (required by postdeploy
    # hooks of the azure.ai.agents extension). `azd env new` does not set it,
    # and `azd env get-value` returns an error string instead of empty when
    # the key is missing, so always set it unconditionally from az context.
    $tenantId = (az account show --query tenantId -o tsv).Trim()
    if ($tenantId) {
        & $AZD env set AZURE_TENANT_ID $tenantId 2>&1 | Out-Null
        Write-Host "Set AZURE_TENANT_ID=$tenantId in azd env."
    } else {
        throw "Could not determine AZURE_TENANT_ID from az account."
    }

    $values = (& $AZD env get-values) -split "`n"
    foreach ($line in $values) {
        if ($line -match '^\s*([A-Z0-9_]+)="?(.*?)"?\s*$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
} finally { Pop-Location }

$ResourceGroup = $env:AZURE_RESOURCE_GROUP
$AcctName = (az cognitiveservices account list -g $ResourceGroup --query "[0].name" -o tsv).Trim()
if (-not $AcctName) { throw "No Cognitive Services account found in $ResourceGroup." }
Write-Host "Resource group: $ResourceGroup"
Write-Host "Foundry acct:   $AcctName"

# ========================================================================
# PHASE 2: RBAC (Foundry User on project for the account MI)
# ========================================================================
Invoke-Phase 2 'Grant Foundry User to project MI' `
    'Assigns the Foundry User RBAC role to the project managed identity so it can call evaluation, taxonomy, and red-team APIs. Without this, eval and red-team scripts get 403 errors.' `
    {
    & pwsh -NoProfile -File (Join-Path $ScriptsDir '03-grant-foundry-user.ps1') -AgentDir $AgentDir -ResourceGroup $ResourceGroup
}

# ========================================================================
# PHASE 3: deploy the basic agent (gpt-4o-mini)
# ========================================================================
Invoke-Phase 3 'Deploy agent-framework-agent-basic-responses' `
    'Builds the Docker container for the primary agent (with 6 @tool functions) and publishes it to ACR. End state: one Foundry-hosted agent active and ready to invoke.' `
    {
    Push-Location $AgentDir
    try {
        # Retry on transient Foundry/ACR errors: 'Project not found' (data plane
        # propagation, 1-3 min after provision) and 'ImageError' (flaky ACR
        # image pull from the hosted agent runtime).
        $maxAttempts = 5
        $attempt = 0
        $success = $false
        while ($attempt -lt $maxAttempts -and -not $success) {
            $attempt++
            Write-Host "Deploy attempt $attempt of $maxAttempts..."
            $output = & $AZD deploy agent-framework-agent-basic-responses --no-prompt 2>&1
            $output | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) {
                $success = $true
                break
            }
            $errText = ($output | Out-String)
            if ($errText -match 'Project not found' -or $errText -match 'NotFound') {
                $wait = 60 * $attempt
                Write-Host "Project data plane not ready yet (attempt $attempt). Waiting $wait s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                $global:LASTEXITCODE = 0
            } elseif ($errText -match 'ImageError' -or $errText -match 'Failed to pull container image') {
                Write-Host "Transient ACR image pull failure (attempt $attempt). Waiting 90s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 90
                $global:LASTEXITCODE = 0
            } else {
                throw "azd deploy failed with exit code $LASTEXITCODE (non-retryable error)"
            }
        }
        if (-not $success) {
            throw "azd deploy failed after $maxAttempts attempts"
        }
    } finally { Pop-Location }
}

# ========================================================================
# PHASE 4: pre-create sister model deployments
# ========================================================================
Invoke-Phase 4 'Create gpt-5-mini + gpt-4.1-mini deployments on the Foundry account' `
    'Creates additional model deployments on the same Foundry account so multiple agents can use different models. End state: 3 model deployments visible in the portal.' `
    {
    $existing = az cognitiveservices account deployment list -g $ResourceGroup -n $AcctName --query "[].name" -o tsv
    if ($existing -notmatch 'gpt-5-mini') {
        az cognitiveservices account deployment create -g $ResourceGroup -n $AcctName `
            --deployment-name gpt-5-mini --model-name gpt-5-mini --model-version 2025-08-07 `
            --model-format OpenAI --sku-name GlobalStandard --sku-capacity 100 | Out-Null
    }
    if ($existing -notmatch 'gpt-4\.1-mini') {
        az cognitiveservices account deployment create -g $ResourceGroup -n $AcctName `
            --deployment-name gpt-4.1-mini --model-name gpt-4.1-mini --model-version 2025-04-14 `
            --model-format OpenAI --sku-name GlobalStandard --sku-capacity 100 | Out-Null
    }
    az cognitiveservices account deployment list -g $ResourceGroup -n $AcctName -o table
}

# ========================================================================
# PHASE 5: deploy sister hosted agents (gpt5, gpt41, broken-model)
# ========================================================================
Invoke-Phase 5 'Deploy gpt5-mini + gpt41-mini + broken-model hosted agents' `
    'Deploys 3 sister agents: gpt5-mini, gpt41-mini (both functional), and broken-model (intentionally points at a non-existent model to generate error spans). End state: 4 agents total, dashboard tiles will light up with multi-model breakdowns.' `
    {
    Push-Location $AgentDir
    try {
        foreach ($svc in @(
            'agent-framework-agent-gpt5-mini',
            'agent-framework-agent-gpt41-mini',
            'agent-framework-agent-broken-model'
        )) {
            $srcDir = Join-Path $AgentDir "src\$svc"
            if (-not (Test-Path $srcDir)) {
                Write-Host "Skip $svc (no source dir; not configured for this repo)" -ForegroundColor Yellow
                continue
            }
            Write-Host "Deploying $svc ..."
            # Retry on transient Foundry/ACR errors: 'Project not found' (data
            # plane propagation) and 'ImageError' (flaky ACR image pull from
            # the hosted agent runtime). Up to 4 attempts with 60-90s backoff.
            $maxAttempts = 4
            $a = 0
            $deployed = $false
            while ($a -lt $maxAttempts -and -not $deployed) {
                $a++
                $output = & $AZD deploy $svc --no-prompt 2>&1
                $output | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -eq 0) {
                    $deployed = $true
                    break
                }
                $errText = ($output | Out-String)
                if ($errText -match 'Project not found' -or $errText -match 'NotFound') {
                    Write-Host "Project not found (attempt $a). Waiting 60s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 60
                    $global:LASTEXITCODE = 0
                } elseif ($errText -match 'ImageError' -or $errText -match 'Failed to pull container image') {
                    Write-Host "Transient ACR image pull failure (attempt $a). Waiting 90s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 90
                    $global:LASTEXITCODE = 0
                } else {
                    throw "azd deploy $svc failed with exit code $LASTEXITCODE (non-retryable)"
                }
            }
            if (-not $deployed) { throw "azd deploy $svc failed after $maxAttempts attempts" }
        }
    } finally { Pop-Location }
}

# ========================================================================
# PHASE 6: warmup + seed traffic
# ========================================================================
Invoke-Phase 6 'Warmup + seed 48-prompt corpus' `
    'Pings the agent 3 times to defeat scale-to-zero, then sends a curated prompt corpus to generate baseline telemetry. End state: invoke_agent spans visible in App Insights Logs within ~5 min.' `
    {
    & pwsh -NoProfile -File (Join-Path $ScriptsDir '04-warmup.ps1') -AgentDir $AgentDir
    Write-Host ''
    Write-Host "Seeding $MaxPrompts prompts (output goes to artifacts/seed-*.log)..." -ForegroundColor Yellow
    Write-Host 'To monitor progress in another terminal:' -ForegroundColor Yellow
    Write-Host "  Get-ChildItem `"$RepoRoot\artifacts\seed-*.log`" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Wait" -ForegroundColor DarkGray
    Write-Host ''
    & pwsh -NoProfile -File (Join-Path $ScriptsDir '05-seed-traffic.ps1') -SleepSeconds 1 -MaxPrompts $MaxPrompts
}

# ========================================================================
# PHASE 7: tool + multi-agent fan-out (lights up the Agents pane)
# ========================================================================
Invoke-Phase 7 'Fan out 12 tool prompts across 3 working agents + 8 broken-model invokes' `
    'Drives diverse traffic across all 4 agents: 12 tool-using prompts per working agent (36 total, ~3 raise LookupError to populate tool error tiles) plus 8 invokes against broken-model (all fail, populate chat-level error charts). End state: Agents pane shows per-tool, per-model, and error breakdowns.' `
    {
    $prompts = @(
        'List orders for customer C001.',
        'List orders for customer C002.',
        'List orders for customer C999.',
        'Find suppliers for request 1001.',
        'Find suppliers for request 1002.',
        'Find suppliers for request 42.',
        'Tell me about supplier S-77.',
        'Tell me about supplier S-91.',
        'Tell me about supplier S-XYZ.',
        'What time is it in UTC?',
        'Weather in Seattle?',
        'Roll a 20-sided die.'
    )
    $working = @(
        'agent-framework-agent-basic-responses',
        'agent-framework-agent-gpt5-mini',
        'agent-framework-agent-gpt41-mini'
    )
    Push-Location $AgentDir
    try {
        $total = $working.Count * $prompts.Count
        $count = 0
        foreach ($svc in $working) {
            if (-not (Test-Path (Join-Path $AgentDir "src\$svc"))) { continue }
            Write-Host ""
            Write-Host "[$svc] sending 12 prompts" -ForegroundColor Cyan
            foreach ($p in $prompts) {
                $count++
                $start = Get-Date
                & $AZD ai agent invoke --new-session --new-conversation $svc $p 2>&1 | Out-Null
                $dur = [int]((Get-Date) - $start).TotalSeconds
                Write-Host ("  [{0,2}/{1}] {2,3}s  {3}" -f $count, $total, $dur, $p)
                Start-Sleep -Milliseconds 400
            }
        }
        if (Test-Path (Join-Path $AgentDir 'src\agent-framework-agent-broken-model')) {
            Write-Host ""
            Write-Host "[broken-model] driving 8 invokes (expected to error)" -ForegroundColor Yellow
            1..8 | ForEach-Object {
                $start = Get-Date
                & $AZD ai agent invoke --new-session --new-conversation `
                    agent-framework-agent-broken-model "ping $_" 2>&1 | Out-Null
                $dur = [int]((Get-Date) - $start).TotalSeconds
                Write-Host ("  [{0}/8] {1,3}s  ping {0}" -f $_, $dur)
                Start-Sleep -Milliseconds 400
            }
        }
        Write-Host ""
        Write-Host "Fan-out complete: $count working + 8 broken-model invocations" -ForegroundColor Green
        # Broken-model invokes and ~3 LookupError prompts are EXPECTED to fail
        # (that's how we populate error tiles). Reset the exit code so the
        # phase wrapper doesn't treat the last failing invoke as a failure.
        $global:LASTEXITCODE = 0
    } finally { Pop-Location }
}

# ========================================================================
# PHASE 8: continuous eval rule + custom evaluator
# ========================================================================
Invoke-Phase 8 'Register custom compliance evaluator' `
    'Registers a custom code-based compliance evaluator (grade -> float) in the Foundry catalog. End state: the evaluator is available for batch runs.' `
    {
    & $VenvPython (Join-Path $ScriptsDir '11-custom-evaluator-register.py')
}

# ========================================================================
# PHASE 9: populate Evaluations pane via one-shot batch eval over traces
# ========================================================================
Invoke-Phase 9 'Run agent batch eval over App Insights traces (5 evaluators)' `
    'Creates an eval group with 5 built-in evaluators (intent_resolution, task_adherence, coherence, fluency, relevance) and runs them over the last 2h of agent traces in App Insights (max 20 traces). End state: eval run completes in 1-3 min and appears in the Foundry portal Evaluations pane immediately.' `
    {
    & $VenvPython (Join-Path $ScriptsDir '20-agent-batch-eval.py')
}

# ========================================================================
# PHASE 10: red team
# ========================================================================
Invoke-Phase 10 'Run red-team scan' `
    'Launches a Foundry-managed adversarial scan with 2 attack strategies (Flip, Base64) and 3 safety evaluators (prohibited_actions, task_adherence, sensitive_data_leakage) against a temporary prompt agent. End state: per-prompt safety verdicts saved to artifacts/redteam-run-final.json.' `
    {
    & $VenvPython (Join-Path $ScriptsDir '12-red-team.py')
}

# ========================================================================
# PHASE 11: alerts
# ========================================================================
Invoke-Phase 11 'Create silent action group + 2 scheduled-query alerts' `
    'Creates a silent action group (no receivers, just for routing) and two Azure Monitor scheduled-query rules: one for error count (sev 2) and one for p95 latency > 30s (sev 3), both over 15-min windows. End state: alerts will fire automatically if production degrades.' `
    {
    & $VenvPython (Join-Path $ScriptsDir '06b-alerts-rest.py')
}

# ========================================================================
# PHASE 12: telemetry KQL export
# ========================================================================
Invoke-Phase 12 'Export telemetry summary to artifacts/telemetry.json' `
    'Runs 4 KQL queries against Log Analytics (volume + success rate, latency percentiles, session activity, token usage) and saves results. End state: artifacts/telemetry.json contains operational baseline. Returns empty if traffic has not yet been ingested (5-15 min ingest delay).' `
    {
    $env:LOG_ANALYTICS_WORKSPACE_ID = (az monitor log-analytics workspace list -g $ResourceGroup --query "[0].customerId" -o tsv).Trim()
    $env:APPLICATIONINSIGHTS_RESOURCE_ID = (az resource list -g $ResourceGroup --resource-type microsoft.insights/components --query "[0].id" -o tsv).Trim()
    & $VenvPython (Join-Path $ScriptsDir '13-telemetry-kql.py')
}

# ========================================================================
# Smoke test
# ========================================================================
Invoke-Phase 13 'Smoke invoke + verify batch eval completed' `
    'Final sanity check: invokes the agent once and verifies the batch eval produced results.' `
    {
    Push-Location $AgentDir
    try {
        & $AZD ai agent invoke --new-session --new-conversation `
            agent-framework-agent-basic-responses "What time is it in Tokyo? Be brief." 2>&1 | Out-Null
    } finally { Pop-Location }
    # Confirm batch eval artifact exists from Phase 9
    $batchFile = Join-Path $RepoRoot 'artifacts\agent-batch-eval-run.json'
    if (Test-Path $batchFile) {
        Write-Host "Batch eval artifact confirmed: $batchFile" -ForegroundColor Green
    } else {
        Write-Host 'WARNING: agent-batch-eval-run.json missing. Phase 9 may have failed.' -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host "E2E COMPLETE" -ForegroundColor Green
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host ''
Write-Host "  Logs:           $LogRoot"
Write-Host "  Resource group: $ResourceGroup"
Write-Host "  Env:            $EnvName"
Write-Host ''

Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host "  NEXT STEPS: how to view what was deployed" -ForegroundColor Cyan
Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host ''

$AppiName = (az resource list -g $ResourceGroup --resource-type microsoft.insights/components --query "[0].name" -o tsv 2>$null).Trim()
$portal = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

Write-Host "1. Validate the deployment (recommended first step)" -ForegroundColor Yellow
Write-Host "   Runs 25+ checks across infrastructure, agents, eval, alerts, RBAC." -ForegroundColor DarkGray
Write-Host "     pwsh -NoProfile -File scripts\validate-deployment.ps1" -ForegroundColor White
Write-Host ''

Write-Host "2. View the App Insights Agents pane (built-in dashboard)" -ForegroundColor Yellow
Write-Host "   Wait 15-30 min after deployment for telemetry rollup, then open:" -ForegroundColor DarkGray
Write-Host "     $portal/providers/microsoft.insights/components/$AppiName/agents" -ForegroundColor White
Write-Host ""
Write-Host "   Expected tiles: Agent Runs, Gen AI Errors, Tool Calls, Models, Token Consumption, Evaluations" -ForegroundColor DarkGray
Write-Host ''

Write-Host "3. Import the Grafana dashboard (5 custom panels)" -ForegroundColor Yellow
Write-Host "   App Insights > Dashboards with Grafana > New > Import the JSON:" -ForegroundColor DarkGray
Write-Host "     $RepoRoot\artifacts\grafana\agent-observability-custom-dashboard.json" -ForegroundColor White
Write-Host ''

Write-Host "4. Invoke an agent manually to see traces live" -ForegroundColor Yellow
Write-Host "   cd agent" -ForegroundColor White
Write-Host "   azd ai agent invoke --new-session --new-conversation `"List orders for customer C001.`"" -ForegroundColor White
Write-Host ''

Write-Host "5. Check telemetry summary (KQL queries against Log Analytics)" -ForegroundColor Yellow
Write-Host "     Get-Content $RepoRoot\artifacts\telemetry.json" -ForegroundColor White
Write-Host ''

Write-Host "6. Inspect red-team results" -ForegroundColor Yellow
Write-Host "     Get-Content $RepoRoot\artifacts\redteam-run-final.json" -ForegroundColor White
Write-Host ''

Write-Host "7. Browse all created resources in the portal" -ForegroundColor Yellow
Write-Host "     $portal" -ForegroundColor White
Write-Host ''

Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host "  TROUBLESHOOTING (if something looks empty or wrong)" -ForegroundColor Cyan
Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host ''
Write-Host "  Telemetry empty after 30 min?" -ForegroundColor Yellow
Write-Host "    pwsh -NoProfile -File scripts\17-list-connections.py    # check App Insights wiring" -ForegroundColor White
Write-Host ''
Write-Host "  Eval pane shows no runs?" -ForegroundColor Yellow
Write-Host "    & .venv\Scripts\python.exe scripts\18-trigger-eval-runs.py    # post stored responses" -ForegroundColor White
Write-Host "    & .venv\Scripts\python.exe scripts\15-list-eval-rules.py      # dump rule definitions" -ForegroundColor White
Write-Host ''
Write-Host "  Want to inspect phase logs from this run?" -ForegroundColor Yellow
Write-Host "    Get-ChildItem $LogRoot" -ForegroundColor White
Write-Host ''

Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host "  TEARDOWN (when you're done)" -ForegroundColor Cyan
Write-Host ('-' * 70) -ForegroundColor Cyan
Write-Host ''
Write-Host "  pwsh -NoProfile -File scripts\teardown.ps1 -EnvName $EnvName" -ForegroundColor White
Write-Host "    Purges the Cognitive Services soft-delete by default. Add -NoPurge to skip." -ForegroundColor DarkGray
Write-Host ''
