---
name: now
description: Get the current local date, time, timezone, weekday, quarter, and Unix timestamp from claude-mind. Use when the user types /now or asks for the current time, today's date, or "what day is it".
---

Call the `now` MCP tool from the `claude-mind` server. It takes no arguments.

Return the result as-is to the user, lightly formatted. Do not paraphrase the timezone or weekday — those are authoritative from the tool, not from your training data.

If the `claude-mind` MCP server is not connected, tell the user and point them at the README install instructions in `~/Developer/claude-mind-mcp/README.md`.
