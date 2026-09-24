# Provider profiles

One sample per provider. The dashboard's **Stack Settings → LLM profiles** page lists these, stores
the operator's real values in Mongo (`llm_profiles`), and writes the profile into a slot's file under
`llm/` when it is attached (`llm/<id>.env`, `llm/ingest-<id>.env`, `llm/fallback-<id>.env`,
`llm/agent-<id>.env`).

File shape — the page reads it, so keep it:

- line 1 `# <Title>`, then `# ` lines up to the first blank line: the description shown on the card;
- `KEY=value` lines: the profile's fields. `replace-me-in-stack-settings` marks a value the operator
  must enter; a profile still holding one cannot be attached.

Fields: `PROVIDER`, `API_KEY`, the provider's endpoint locators (`REGION`, `GEMINI_API_SURFACE`,
`GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`), the tiers `SMART_MODELS` / `SMARTER_MODELS` /
`SMARTEST_MODELS` (comma-separated, cheapest first; SMARTER is ONE id — it is query enrichment), and
`AGENT_*` only where the public agent's OpenAI-shaped tool loop is known to work on that endpoint.
