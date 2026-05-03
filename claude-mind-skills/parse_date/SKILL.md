---
name: parse_date
description: Detect explicit dates in a phrase using claude-mind's NSDataDetector-backed parser. Use when the user types /parse_date or asks to parse, extract, or normalize a date from natural language.
---

Call the `parse_date` MCP tool from the `claude-mind` server.

Arguments:
- `text`: $ARGUMENTS — the phrase to scan for dates (required)

Return the parser's output verbatim. Do not invent or "fix" dates the parser did not detect — if it returns nothing, say so. Relative-phrase resolution (e.g. "next Tuesday") is planned for v2 of the server; if the user clearly wants relative resolution and the parser misses it, note that limitation rather than guessing.
