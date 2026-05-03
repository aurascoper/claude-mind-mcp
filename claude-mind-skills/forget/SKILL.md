---
name: forget
description: Soft-delete a memory in claude-mind by id (sets tombstoned). Use when the user types /forget or asks to delete, remove, forget, or tombstone a specific memory.
---

Call the `forget` MCP tool from the `claude-mind` server.

Arguments:
- `id`: a memory UUID (required). $ARGUMENTS is the id.

If the user did not give a UUID — for example they said "forget the last thing I told you" or named a topic — do **not** guess. Either:
1. Run `/list_recent` first and ask the user which id to forget, or
2. Tell the user `forget` requires a UUID and offer to look one up via `/recall <query>`.

Forget is destructive from the user's point of view (the memory will no longer surface in `recall`). Do not chain `forget` calls speculatively. One tool call per explicit user instruction.

Return the server's confirmation (id + status). Do not invent an undo step — the server's tombstoning is soft-delete, but there is no `unforget` tool exposed.
