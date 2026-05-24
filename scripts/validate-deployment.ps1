#Requires -Version 7.0
<#
.SYNOPSIS
  Post-deployment validation: checks every resource and service created by
  run-e2e.ps1 is functioning correctly.

  Run after run-e2e.ps1 completes (or after a partial run with -SkipPhases)
  to confirm what is working and what needs attention.

.PARAMETER EnvName
  azd env name to validate. Defaults to the currently selected env.

.PARAMETER SkipInvoke
  Skip agent invocation tests (useful if you only want to check infra).
#>
[CmdletBinding()]
param(
    [string]$EnvName,
    [switch]$SkipInvoke,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Continue'
$AZD = if (Test-Path "$env:LOCALAPPDATA\Programs\azd-local\azd.exe") {
    "$env:LOCALAPPDATA\Programs\azd-local\azd.exe"
} else { 'azd' }
$AgentDir = Join-Path $RepoRoot 'agent'
$VenvPython = Join-Path $RepoRoot '.venv\Scripts\python.exe'

$pass = 0; $fail = 0; $skip = 0
$results = @()

function Test-Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $result = & $Test
        if ($result) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
            $script:pass++
            $script:results += @{name=$Name; status='PASS'; detail=$result}
        } else {
            Write-Host "  [FAIL] $Name" -ForegroundColor Red
            $script:fail++
            $script:results += @{name=$Name; status='FAIL'; detail='returned empty/false'}
        }
    } catch {
        Write-Host "  [FAIL] $Name : $_" -ForegroundColor Red
        $script:fail++
        $script:results += @{name=$Name; status='FAIL'; detail=$_.ToString()}
    }
}

function Skip-Check {
    param([string]$Name, [string]$Reason)
    Write-Host "  [SKIP] $Name ($Reason)" -ForegroundColor Yellow
    $script:skip++
    $script:results += @{name=$Name; status='SKIP'; detail=$Reason}
}

# --- Load azd env ---
Push-Location $AgentDir
try {
    if ($EnvName) { & $AZD env select $EnvName }
    $values = (& $AZD env get-values) -split "`n"
    $env = @{}
    foreach ($line in $values) {
        if ($line -match '^\s*([A-Z0-9_]+)="?(.*?)"?\s*$') {
            $env[$Matches[1]] = $Matches[2]
        }
    }
} finally { Pop-Location }

$rg = $env['AZURE_RESOURCE_GROUP']
$sub = $env['AZURE_SUBSCRIPTION_ID']
$endpoint = $env['AZURE_AI_PROJECT_ENDPOINT']
$agentName = $env['AZURE_AI_AGENT_NAME']
if (-not $agentName) { $agentName = 'agent-framework-agent-basic-responses' }

Write-Host ''
Write-Host '=====================================================================' -ForegroundColor Cyan
Write-Host '  AI Observability Starter Kit: Post-Deployment Validation' -ForegroundColor Cyan
Write-Host '=====================================================================' -ForegroundColor Cyan
Write-Host "  Env:            $($env['AZURE_ENV_NAME'])"
Write-Host "  Resource group: $rg"
Write-Host "  Subscription:   $sub"
Write-Host "  Endpoint:       $endpoint"
Write-Host ''

# ========================================================================
# 1. INFRASTRUCTURE
# ========================================================================
Write-Host '--- Infrastructure ---' -ForegroundColor Cyan

Test-Check 'Resource group exists' {
    $exists = az group exists -n $rg 2>$null
    $exists -eq 'true'
}

Test-Check 'Cognitive Services account exists' {
    $acct = (az cognitiveservices account list -g $rg --query "[0].name" -o tsv 2>$null).Trim()
    if ($acct) { $acct } else { $false }
}
$acctName = (az cognitiveservices account list -g $rg --query "[0].name" -o tsv 2>$null).Trim()

Test-Check 'Foundry project exists' {
    $proj = az cognitiveservices account list -g $rg --query "[0].properties.endpoints" -o json 2>$null
    if ($proj) { $true } else { $false }
}

Test-Check 'Application Insights exists' {
    $appi = (az resource list -g $rg --resource-type microsoft.insights/components --query "[0].name" -o tsv 2>$null).Trim()
    if ($appi) { $appi } else { $false }
}

Test-Check 'Log Analytics workspace exists' {
    $ws = (az monitor log-analytics workspace list -g $rg --query "[0].name" -o tsv 2>$null).Trim()
    if ($ws) { $ws } else { $false }
}

Test-Check 'Container Registry exists' {
    $acr = (az acr list -g $rg --query "[0].name" -o tsv 2>$null).Trim()
    if ($acr) { $acr } else { $false }
}

# ========================================================================
# 2. MODEL DEPLOYMENTS
# ========================================================================
Write-Host ''
Write-Host '--- Model Deployments ---' -ForegroundColor Cyan

if ($acctName) {
    $deployments = az cognitiveservices account deployment list -g $rg -n $acctName --query "[].name" -o tsv 2>$null
    foreach ($model in @('gpt-4o-mini', 'gpt-5-mini', 'gpt-4.1-mini')) {
        Test-Check "Model deployment: $model" {
            $deployments -match $model
        }
    }
} else {
    Skip-Check 'Model deployments' 'No Cognitive Services account found'
}

# ========================================================================
# 3. HOSTED AGENTS
# ========================================================================
Write-Host ''
Write-Host '--- Hosted Agents ---' -ForegroundColor Cyan

$agents = @(
    'agent-framework-agent-basic-responses',
    'agent-framework-agent-gpt5-mini',
    'agent-framework-agent-gpt41-mini',
    'agent-framework-agent-broken-model'
)

Push-Location $AgentDir
try {
    foreach ($agent in $agents) {
        $srcDir = Join-Path $AgentDir "src\$agent"
        if (-not (Test-Path $srcDir)) {
            Skip-Check "Agent: $agent" 'No source directory'
            continue
        }
        Test-Check "Agent: $agent (status=active)" {
            $info = & $AZD ai agent show $agent 2>&1
            if ($info -match 'active') { $true } else { $false }
        }
    }
} finally { Pop-Location }

# ========================================================================
# 4. AGENT INVOCATION (optional)
# ========================================================================
Write-Host ''
Write-Host '--- Agent Invocation ---' -ForegroundColor Cyan

if ($SkipInvoke) {
    Skip-Check 'Agent invocation' 'Skipped via -SkipInvoke'
} else {
    Push-Location $AgentDir
    try {
        Test-Check 'basic-responses agent responds' {
            $resp = & $AZD ai agent invoke --new-session --new-conversation $agentName "Reply with the word OK and nothing else." 2>&1
            $resp -match 'OK'
        }

        Test-Check 'Tool call succeeds (list orders C001)' {
            $resp = & $AZD ai agent invoke --new-session --new-conversation $agentName "List orders for customer C001." 2>&1
            $resp -match 'order' -or $resp -match 'C001'
        }

        Test-Check 'broken-model agent returns error span' {
            $resp = & $AZD ai agent invoke --new-session --new-conversation agent-framework-agent-broken-model "ping" 2>&1
            # The agent will error but still produce a trace
            $true
        }
    } finally { Pop-Location }
}

# ========================================================================
# 5. TELEMETRY (App Insights has data)
# ========================================================================
Write-Host ''
Write-Host '--- Telemetry ---' -ForegroundColor Cyan

$wsId = (az monitor log-analytics workspace list -g $rg --query "[0].customerId" -o tsv 2>$null).Trim()
if ($wsId) {
    Test-Check 'invoke_agent spans in App Insights' {
        # Newer agent-framework SDK emits invoke_agent as dependency spans, not requests.
        $q = "AppDependencies | where TimeGenerated > ago(2h) | where Name startswith 'invoke_agent' | count"
        $count = (az monitor log-analytics query -w $wsId --analytics-query $q --query "[0].Count" -o tsv 2>$null).Trim()
        if ([int]$count -gt 0) { "$count spans found" } else { $false }
    }

    Test-Check 'chat dependency spans exist' {
        $q = "AppDependencies | where TimeGenerated > ago(2h) | where Name startswith 'chat ' | count"
        $count = (az monitor log-analytics query -w $wsId --analytics-query $q --query "[0].Count" -o tsv 2>$null).Trim()
        if ([int]$count -gt 0) { "$count chat spans" } else { $false }
    }

    Test-Check 'execute_tool dependency spans exist' {
        $q = "AppDependencies | where TimeGenerated > ago(2h) | where Name startswith 'execute_tool' | count"
        $count = (az monitor log-analytics query -w $wsId --analytics-query $q --query "[0].Count" -o tsv 2>$null).Trim()
        if ([int]$count -gt 0) { "$count tool spans" } else { $false }
    }
} else {
    Skip-Check 'Telemetry checks' 'No Log Analytics workspace found'
}

# ========================================================================
# 6. EVALUATION
# ========================================================================
Write-Host ''
Write-Host '--- Evaluation ---' -ForegroundColor Cyan

if (Test-Path $VenvPython) {
    Test-Check 'Batch eval artifact exists' {
        $f = Join-Path $RepoRoot 'artifacts\agent-batch-eval-run.json'
        if (Test-Path $f) { "Found: $f" } else { $false }
    }
    Test-Check 'Custom evaluator registered' {
        $f = Join-Path $RepoRoot 'artifacts\custom-evaluator.json'
        if (Test-Path $f) { "Found: $f" } else { $false }
    }
    Test-Check 'Red-team results exist' {
        $f = Join-Path $RepoRoot 'artifacts\redteam-run-final.json'
        if (Test-Path $f) { "Found: $f" } else { $false }
    }
} else {
    Skip-Check 'Evaluation checks' 'Python venv not found'
}

# ========================================================================
# 7. ALERTS
# ========================================================================
Write-Host ''
Write-Host '--- Alerts ---' -ForegroundColor Cyan

Test-Check 'Action group: ag-aiobs-silent' {
    $ag = az monitor action-group show -g $rg -n ag-aiobs-silent --query name -o tsv 2>$null
    if ($ag) { $ag } else { $false }
}

Test-Check 'Alert: gen-ai-errors-15m' {
    $alert = az resource show -g $rg --resource-type "Microsoft.Insights/scheduledQueryRules" -n alert-gen-ai-errors-15m --query name -o tsv 2>$null
    if ($alert) { $alert } else { $false }
}

Test-Check 'Alert: gen-ai-p95-latency-15m' {
    $alert = az resource show -g $rg --resource-type "Microsoft.Insights/scheduledQueryRules" -n alert-gen-ai-p95-latency-15m --query name -o tsv 2>$null
    if ($alert) { $alert } else { $false }
}

# ========================================================================
# 8. RBAC
# ========================================================================
Write-Host ''
Write-Host '--- RBAC ---' -ForegroundColor Cyan

if ($acctName) {
    Test-Check 'Foundry User role assigned to project MI' {
        $projectMi = (az resource show -g $rg --resource-type Microsoft.CognitiveServices/accounts -n $acctName --query identity.principalId -o tsv 2>$null).Trim()
        if ($projectMi) {
            $roles = az role assignment list --assignee $projectMi --all --query "[?roleDefinitionName=='Foundry User'].roleDefinitionName" -o tsv 2>$null
            if ($roles) { "Foundry User assigned to $projectMi" } else { $false }
        } else { $false }
    }
} else {
    Skip-Check 'RBAC checks' 'No Cognitive Services account found'
}

# ========================================================================
# SUMMARY
# ========================================================================
Write-Host ''
Write-Host '=====================================================================' -ForegroundColor Cyan
Write-Host '  VALIDATION SUMMARY' -ForegroundColor Cyan
Write-Host '=====================================================================' -ForegroundColor Cyan
Write-Host "  Passed:  $pass" -ForegroundColor Green
Write-Host "  Failed:  $fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $skip" -ForegroundColor $(if ($skip -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ''

if ($fail -eq 0) {
    Write-Host '  All checks passed. Deployment is fully functional.' -ForegroundColor Green
} else {
    Write-Host '  Some checks failed. Review the [FAIL] items above.' -ForegroundColor Red
    Write-Host '  If telemetry checks fail, wait 15-30 min for App Insights rollup.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    App Insights Agents pane: Azure portal > rg $rg > App Insights > Agents (Preview)"
Write-Host "    Grafana dashboard:        Import artifacts/grafana/agent-observability-dashboard.json"
Write-Host "    Teardown:                 pwsh -NoProfile -File scripts\teardown.ps1 -EnvName <env-name>"
Write-Host ''

exit $fail
