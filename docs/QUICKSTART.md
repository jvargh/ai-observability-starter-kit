# Quickstart: end-to-end in 6 commands

This is a flattened version of [MANUAL_GUIDE.md](./MANUAL_GUIDE.md). Run the commands top-to-bottom in **PowerShell 7 on Windows** and you get the full stack: Foundry account + project + agents (4 hosted agents across 3 models), traffic, continuous eval, red team, alerts, telemetry exports.

Per-step deep dives, troubleshooting, and the rationale for every choice live in [MANUAL_GUIDE.md](./MANUAL_GUIDE.md). When something fails, jump there.

## 0. One-time prereqs (5 min)

```powershell
# PowerShell 7, az CLI 2.86+, Docker 29+, Python 3.12 already installed.
# Pinned azd build (the PATH 1.23.10 is broken):
$AZD = "$env:LOCALAPPDATA\Programs\azd-local\azd.exe"
& $AZD version    # expect >= 1.25.1

cd c:\path\to\repo-root

py -3.12 -m venv .venv
. .venv\Scripts\Activate.ps1
pip install --upgrade pip
pip install azure-ai-projects==2.1.0 azure-identity openai pyyaml python-dotenv azure-monitor-opentelemetry azure-monitor-query requests
deactivate

az login --tenant <TENANT_ID>
az account set --subscription <SUB_ID>
& $AZD auth login --tenant-id <TENANT_ID>
```

## 1. Provision + deploy all 4 agents, drive traffic, run evals + red team + alerts

One command (the orchestrator does everything in [MANUAL_GUIDE.md](./MANUAL_GUIDE.md) Steps 1-10):

```powershell
pwsh -NoProfile -File scripts\run-e2e.ps1 -Region eastus2
```

Wall-clock: roughly **35-50 min** (mostly `azd up` + red team polling). The script writes per-step logs to `artifacts\e2e-<timestamp>\` and stops on the first failure.

What it does (and what to look for after each phase):

| Phase | Wraps | Wait | Verify |
|---|---|---|---|
| 1. provision | `azd up` (Foundry account, project, ACR, App Insights, Log Analytics, gpt-4o-mini, capability host) | ~7 min | `az resource list -g $rg` shows 5+ types |
| 2. RBAC | `scripts\03-grant-foundry-user.ps1` | ~10 s | Project MI gets Foundry User at project scope |
| 3. deploy basic agent | `azd deploy agent-framework-agent-basic-responses` | ~3 min | `azd ai agent show` reports `status=active` |
| 4. sister model deployments | `az cognitiveservices account deployment create` for gpt-5-mini + gpt-4.1-mini | ~1 min | `az cognitiveservices account deployment list` shows 3 deployments |
| 5. deploy 3 sister agents (gpt5-mini, gpt41-mini, broken-model) | `azd deploy <name>` x3 | ~9 min | 4 agents visible in Foundry portal |
| 6. warmup + seed traffic | `scripts\04-warmup.ps1` + `scripts\05-seed-traffic.ps1` | ~6 min | `artifacts\seed-*.log` shows 48/48/48 prompts/replies/traces |
| 7. tool + multi-agent fan-out | 12 prompts x 3 agents + 8 broken-model invokes | ~3 min | `AppDependencies` shows `execute_tool` rows with errors + `chat <model>` rows for 3 models + 1 fake |
| 8. continuous eval rule + custom evaluator | `scripts\10-continuous-eval.py` + `scripts\11-custom-evaluator-register.py` | ~30 s | `artifacts\continuous-eval.json` + `artifacts\custom-evaluator.json` exist |
| 9. force-fill the Evaluations pane | `scripts\20-agent-batch-eval.py` | ~5 min | run reports `total=8, passed>=5` |
| 10. red team | `scripts\12-red-team.py` | ~6 min | `artifacts\redteam-run-final.json` status=completed |
| 11. alerts | `scripts\06b-alerts-rest.py` | ~10 s | 2 scheduledQueryRules visible in the RG |
| 12. telemetry export | `scripts\13-telemetry-kql.py` | ~10 s | `artifacts\telemetry.json` written |

## 2. Smoke test after the pipeline

```powershell
cd agent
& $AZD ai agent invoke --new-session --new-conversation `
    "What time is it in Tokyo? Be brief and add 'This response is for informational purposes only.' at the end."
cd ..

# 60-90 s later, verify the continuous-eval rule fired and check the evaluator scores:
& .venv\Scripts\python.exe scripts\14-verify-continuous-eval.py
```

The App Insights "Agents (preview)" pane rollup takes 15-30 min after spans land. The Grafana dashboard (see [GRAFANA_GUIDE.md](./GRAFANA_GUIDE.md)) queries Log Analytics directly and updates within 1-2 min.

## 3. Tear down

```powershell
pwsh -NoProfile -File scripts\teardown.ps1 -EnvName <env-name>
```

Purge is the default behavior (clears Cognitive Services soft-delete so the account name can be reused). Add `-NoPurge` to skip.

## Common bailouts

| Symptom | Fix |
|---|---|
| `azd deploy` prints `No services found.` | Wrong azd build. Re-run with `$AZD = "$env:LOCALAPPDATA\Programs\azd-local\azd.exe"`. |
| `role not found: Azure AI User` | The role was renamed to `Foundry User`. The orchestrator tries both; if you ran the raw command, use `Foundry User`. |
| Continuous-eval rule returns 0 runs | Expected. The orchestrator's Phase 9 batch-eval is the reliable path to fill the Evaluations pane. |
| Agents pane empty after 30 min | Hosted agents tracing is preview. Confirm `ENABLE_INSTRUMENTATION=true` on every `agent.yaml`, then re-drive traffic. |

For anything else, read the matching section of [MANUAL_GUIDE.md](./MANUAL_GUIDE.md) and the script comments under `scripts\`.
