---
name: recall
description: Retrieve memories from claude-mind by semantic + lexical + entity search with optional structured filters. Use when the user types /recall or asks to find, look up, search, or "remember" something they previously stored.
---

Call the `recall` MCP tool from the `claude-mind` server.

Arguments:
- `query`: $ARGUMENTS — what to recall (required)
- `k`: integer, default `5`. Only raise above 5 if the user explicitly asks for more results.
- `from`, `to`: ISO8601 bounds. Set these only if the user gives a date range.
- `source`, `conversation_id`: pass through if the user specifies one.
- `tags`: array of strings; extract `#hashtag` tokens from the query if present.

**Required output contract — do not deviate.** For each hit, surface to the user:
1. The memory **id** (UUID)
2. The **timestamp** (`createdAt`, plus `occurredAt` when present)
3. The **provenance** fields the server returned: `source`, `conversation_id`, `tags`, and the `seed_source` array (e.g. `["vector"]`, `["lexical","entity"]`) that explains *why* the result matched
4. The memory **text**

Do not summarize multiple hits into a single paragraph. Do not drop ids "for readability". Provenance and timestamps are load-bearing for the user's trust in retrieval — if you compress them away, the tool is useless.

If the server returns zero hits, say so plainly and report the `path` (`mirror` or `local`) and any `fallback_reason`. Do not fabricate near-matches from your context.
