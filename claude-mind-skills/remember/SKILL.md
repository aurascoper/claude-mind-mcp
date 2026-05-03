---
name: remember
description: Save a memory in claude-mind. Use when the user types /remember or asks to save, store, persist, note, or "remember" a piece of information for later recall.
---

Call the `remember` MCP tool from the `claude-mind` server.

Arguments:
- `text`: the memory body (required) — by default this is $ARGUMENTS verbatim
- `tags`: array of strings; extract `#hashtag` tokens from the input if present and pass them as tags (with the `#` stripped). Do not invent tags the user did not give.
- `source`: pass through if the user names a source ("from email", "from slack", etc.)
- `conversation_id`: pass through if the user gives one
- `occurred_at`: ISO8601 datetime; only set this if the user explicitly states *when* the event occurred (distinct from when they're saving it). Do not back-date based on phrasing alone.

Return the stored memory id and a one-line confirmation. Do not echo back the full text — the user just typed it.

If the server returns an error, surface the error message verbatim. Do not retry with mutated arguments.
