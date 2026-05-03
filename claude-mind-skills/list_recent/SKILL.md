---
name: list_recent
description: List the N most recently created memories in claude-mind. Use when the user types /list_recent or asks "what did I save recently", "show recent memories", or "what's in memory".
---

Call the `list_recent` MCP tool from the `claude-mind` server.

Arguments:
- `limit`: integer, default `10`. Use the user's number if they give one (e.g. "last 25"); otherwise leave at `10`. The server's own default is `25`, but a smaller default is friendlier in chat.

For each entry, surface the **id**, **createdAt** timestamp, **tags**, and **text**. Keep the per-entry rendering compact — this is a list view, not a deep read. If the user wants details on one entry, they can follow up with `/recall_around anchor_id=<id>` or quote the id back.
