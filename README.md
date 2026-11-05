# ArcVault AI Intake & Triage

An agentic intake workflow for **ArcVault**, a fictional B2B SaaS company. It ingests unstructured customer requests,
classifies and enriches them with an LLM, routes each one to the right team queue, flags escalations for human review,
and writes a structured JSON record per request.

Built with free tools: **n8n** (self-hosted in Docker) for orchestration and **Groq** (`llama-3.3-70b-versatile`) as the LLM.

> 🚧 Work in progress. Setup instructions, sample output and design docs will be added as the build progresses.

## Repository layout

| Path | Contents |
|---|---|
| `workflow/` | Exported n8n workflow (importable JSON) |
| `samples/` | Test requests: the 5 from the brief + 3 edge cases |
| `scripts/` | Sender script that POSTs the samples to the workflow webhook |
| `output/` | `arcvault_output.json` (collected results); `records/` holds per-request files (git-ignored) |
| `docs/` | Prompt documentation, architecture write-up, AI notes |
| `screenshots/` | Workflow and node output screenshots |
