"""Continuous evaluation setup (Phase 5 of demo).

Creates an eval container with three built-in evaluators and a rule that runs
on every response completion for the demo agent. Persists ids to
``artifacts/continuous-eval.json``.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    ContinuousEvaluationRuleAction,
    EvaluationRule,
    EvaluationRuleEventType,
    EvaluationRuleFilter,
)
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
# Discover active azd env dynamically.
_azd_base = ROOT / "agent" / ".azure"
_env_name = os.environ.get("AZURE_ENV_NAME", "")
if not _env_name:
    # Fall back to azd's tracked default env from config.json
    _config = _azd_base / "config.json"
    if _config.exists():
        try:
            import json as _json
            _env_name = _json.loads(_config.read_text()).get("defaultEnvironment", "")
        except Exception:
            _env_name = ""
if _env_name and (_azd_base / _env_name / ".env").exists():
    AZD_ENV = _azd_base / _env_name / ".env"
else:
    AZD_ENV = next(
        (p / ".env" for p in sorted(_azd_base.iterdir()) if p.is_dir() and (p / ".env").exists()),
        _azd_base / "default" / ".env",
    )
ARTIFACTS = ROOT / "artifacts"


def main() -> int:
    if AZD_ENV.exists():
        load_dotenv(AZD_ENV)
    load_dotenv()

    endpoint = os.environ["AZURE_AI_PROJECT_ENDPOINT"]
    model_deployment = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME") or os.environ["MODEL_DEPLOYMENT_NAME"]
    agent_name = os.environ.get(
        "AZURE_AI_AGENT_NAME", "agent-framework-agent-basic-responses"
    )
    print(f"endpoint:        {endpoint}")
    print(f"agent_name:      {agent_name}")
    print(f"model deploy:    {model_deployment}")

    project = AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())
    openai_client = project.get_openai_client()

    data_source_config = {"type": "azure_ai_source", "scenario": "responses"}
    # Source fields match what the azure_ai_traces_preview data source emits per
    # trace item: query, response, tool_calls, tool_definitions. Using item.input
    # or item.output here will silently produce empty rows and every evaluator
    # will error with "Missing inputs for line N: 'data.input, data.output'".
    common_qr = {"query": "{{item.query}}", "response": "{{item.response}}"}
    testing_criteria = [
        {
            "type": "azure_ai_evaluator",
            "name": "intent_resolution",
            "evaluator_name": "builtin.intent_resolution",
            "initialization_parameters": {"deployment_name": model_deployment},
            "data_mapping": common_qr,
        },
        {
            "type": "azure_ai_evaluator",
            "name": "tool_call_accuracy",
            "evaluator_name": "builtin.tool_call_accuracy",
            "initialization_parameters": {"deployment_name": model_deployment},
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{item.response}}",
                "tool_definitions": "{{item.tool_definitions}}",
                "tool_calls": "{{item.tool_calls}}",
            },
        },
        {
            "type": "azure_ai_evaluator",
            "name": "violence",
            "evaluator_name": "builtin.violence",
            "data_mapping": common_qr,
        },
    ]
    eval_object = openai_client.evals.create(
        name="Demo continuous eval",
        data_source_config=data_source_config,
        testing_criteria=testing_criteria,
    )
    print(f"eval_id:         {eval_object.id}")

    rule = project.evaluation_rules.create_or_update(
        id="demo-continuous-eval",
        evaluation_rule=EvaluationRule(
            display_name="Demo continuous eval",
            description="Runs on every response completion for the demo agent",
            action=ContinuousEvaluationRuleAction(
                eval_id=eval_object.id, max_hourly_runs=100
            ),
            event_type=EvaluationRuleEventType.RESPONSE_COMPLETED,
            filter=EvaluationRuleFilter(agent_name=agent_name),
            enabled=True,
        ),
    )
    print(f"rule_id:         {rule.id}")

    ARTIFACTS.mkdir(exist_ok=True)
    out_path = ARTIFACTS / "continuous-eval.json"
    out_path.write_text(
        json.dumps(
            {
                "eval_id": eval_object.id,
                "rule_id": rule.id,
                "agent_name": agent_name,
                "model_deployment": model_deployment,
            },
            indent=2,
        )
    )
    print(f"saved:           {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
