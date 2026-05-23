# AI Observability Starter Kit

End-to-end reference implementation for observing, evaluating, and red-teaming AI agents on **Microsoft Foundry**. Provisions infrastructure, deploys four containerized agents (three models + one intentionally broken), generates traffic, wires up continuous and batch evaluation, runs red-team attacks, and configures alerts, all in a single orchestrated pipeline.

![AI Observability Starter Kit](docs/AI-Obs-StarterKit.png)

## Why This Exists

An HTTP 200 tells you nothing about what happened inside an AI agent call. Model hallucinations, tool failures, safety breaches, and token cost spikes are invisible without purpose-built observability. This kit gives you the full stack:

| Layer | What You Get |
| --- | --- |
| **Telemetry** | OpenTelemetry GenAI spans (`invoke_agent`, `chat`, `execute_tool`) flowing into Application Insights and Log Analytics |
| **Multi-model comparison** | Side-by-side token consumption, latency percentiles, and error rates across gpt-4o-mini, gpt-5-mini, and gpt-4.1-mini |
| **Continuous evaluation** | Built-in evaluators (intent\_resolution, coherence, fluency, task\_adherence) + custom code-based evaluators running on every response |
| **Red-team testing** | Cloud AI Red Teaming Agent with Flip, Base64, and IndirectJailbreak strategies across multi-turn conversations |
| **Alerting** | Scheduled query rules for error spikes (Severity 2) and p95 latency breaches (Severity 3) |
| **Dashboards** | App Insights Agents pane, Grafana dashboards, and exportable telemetry JSON |

## Quick Start

**Prerequisites:** PowerShell 7, azd 1.25.1+, az CLI 2.86.0+, Docker 29.x, Python 3.12+

```
# Setup, deploy, evaluate, red-team, alert, and validate (35-50 min)
pwsh -NoProfile -File scripts\run-e2e.ps1 `
    -Region eastus2 `
    -EnvName <env-name> `
    -SubscriptionId <subscription-id>

# Validate everything is working (24 checks)
pwsh -NoProfile -File scripts\validate-deployment.ps1

# Tear down and purge
pwsh -NoProfile -File scripts\teardown.ps1 -EnvName <env-name>
```

Each phase logs to `artifacts/e2e-{timestamp}/phase-xx.log`. Skip specific phases with `-SkipPhases "9,10"`. For the full walkthrough, see [docs/starter-kit-ai-observability-v2.md](docs/starter-kit-ai-observability-v2.md).

## Key Highlights

**Built on Microsoft Foundry:** The kit uses Foundry's hosted agent infrastructure, which handles container orchestration, model routing, and automatic OpenTelemetry instrumentation. Setting `ENABLE_INSTRUMENTATION=true` in the agent manifest emits GenAI semantic convention spans for every model call and tool execution with no SDK wiring. Foundry also provides the evaluation and red-team APIs as managed services, so you get quality scoring and safety scanning without standing up separate infrastructure.

**Evaluation:** 8 built-in [agent evaluators](https://learn.microsoft.com/en-us/azure/foundry/concepts/evaluation-evaluators/agent-evaluators) run as a single batch over traces in App Insights, covering both system outcomes (task adherence, completion, intent resolution) and process quality (tool call accuracy, selection, input accuracy, output utilization, success). A [custom code-based evaluator](https://learn.microsoft.com/en-us/azure/foundry/concepts/evaluation-evaluators/custom-evaluators) demonstrates the pattern for domain-specific checks (compliance disclaimers, format rules, policy enforcement).

**Red-team testing:** Automated [cloud red-team scanning](https://learn.microsoft.com/en-us/azure/foundry/how-to/develop/run-ai-red-teaming-cloud?tabs=python) with configurable attack strategies (Flip, Base64, IndirectJailbreak) over multi-turn conversations. Three safety evaluators (Prohibited Actions, Task Adherence, Sensitive Data Leakage) score every response. Results include per-prompt verdicts with the adversarial prompt, agent response, and evaluator scores for audit trails.

**Observability:** Three complementary viewing surfaces from a single telemetry backbone: the App Insights Agents pane (zero setup, populates automatically from Foundry spans), prebuilt Azure-managed Grafana dashboards, and two importable custom dashboards covering tokens, latency, error rates, model breakdowns, and session activity. Four KQL queries are included for ad-hoc investigation.

## Agent Variants

All agents share the same tool set (6 tools: `get_orders`, `find_suppliers`, `get_company_supplier_info`, `get_current_utc_date`, `get_weather`, `roll_dice`) and instructions. They differ only by target model:

| Agent | Model | Purpose |
| --- | --- | --- |
| `agent-framework-agent-basic-responses` | gpt-4o-mini | Primary agent, baseline for all evaluations |
| `agent-framework-agent-gpt5-mini` | gpt-5-mini | Multi-model comparison (cost, latency, quality) |
| `agent-framework-agent-gpt41-mini` | gpt-4.1-mini | Multi-model comparison (cost, latency, quality) |
| `agent-framework-agent-broken-model` | `nonexistent-model-deployment-xyz` | Intentional 404s to populate error telemetry in dashboards |

## Repo Structure

| Folder | Purpose |
| --- | --- |
| [agent/](agent/) | `azure.yaml`, Bicep infrastructure, and four agent source projects under `src/` |
| [agent/src/](agent/src/) | Containerized Python agents (see [Agent Variants](#agent-variants) below) |
| [agent/infra/](agent/infra/) | Bicep modules for Foundry account, ACR, App Insights, Log Analytics |
| [scripts/](scripts/) | PowerShell and Python automation: e2e orchestrator, traffic seeding, eval registration, alerts, teardown |
| [notebooks/](notebooks/) | Jupyter notebooks for continuous eval setup, custom evaluator registration, red-team taxonomy and execution |
| [evaluators/](evaluators/) | Custom code-based evaluator (compliance phrase check) with YAML manifest |
| [prompts/](prompts/) | Test prompt files: clean, ambiguous, and safety-bait categories |
| [artifacts/](artifacts/) | Pre-staged JSON payloads, eval results, red-team outputs, Grafana dashboard configs |
| [docs/](docs/) | Architecture diagram, infographic, implementation plan, manual guide, quickstart, runbook, Grafana guide |