---
name: recall_around
description: Retrieve memories temporally adjacent to an anchor (memory id or ISO8601 date) within a time window. Use when the user types /recall_around or asks "what else happened around X", "what did I save near Y", or wants context surrounding a specific memory or moment.
---

Call the `recall_around` MCP tool from the `claude-mind` server.

Arguments — exactly one of `anchor_id` or `anchor_date` is required:
- `anchor_id`: a memory UUID. Use this if the user gives or implies a specific memory.
- `anchor_date`: ISO8601 datetime. Use this if the user gives a date/time but no memory id.
- `window_seconds`: integer; default `86400` (±1 day). Adjust if the user says "this week" (`604800`), "this hour" (`3600`), etc.
- `k`: integer, default `5`. Only raise if the user asks for more.

If neither anchor is parseable from the user's input, ask them for one — do not guess.

**Required output contract — do not deviate.** For each hit, surface to the user:
1. The memory **id** (UUID)
2. The **timestamp** (`createdAt`, plus `occurredAt` when present)
3. The **time delta** from the anchor (the server returns this; pass it through)
4. The **provenance** fields: `source`, `conversation_id`, `tags`
5. The memory **text**

Order results by absolute time delta (the server already does this; preserve the order). Do not collapse hits into a single summary — the user is asking for adjacency, so each hit's individual timestamp is the point.
