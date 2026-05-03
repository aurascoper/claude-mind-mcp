# claude-mind-skills

Companion **Claude Code skills pack** for [`claude-mind-mcp`](../README.md).

Each skill here is a thin wrapper that tells Claude to call the matching MCP
tool. Together they give you clean slash-command UX in Claude Code:

```
/now
/parse_date
/remember
/recall
/recall_around
/list_recent
/forget
```

## Why a skills pack and not just MCP prompts

If you expose prompts directly from the MCP server, Claude Code surfaces them
as `/mcp__claude-mind__<prompt>` — long, ugly, and impossible to muscle-memory.
Skills get you the clean `/remember` form because they live under
`~/.claude/skills/<name>/SKILL.md`.

Splitting concerns:

| layer  | role                              |
|--------|-----------------------------------|
| MCP    | execution and state (Core Data, embeddings, mirror) |
| skills | human-friendly slash invocations  |

The skills do not reimplement memory logic. Each one resolves arguments and
calls the corresponding MCP tool.

## Install

```sh
# from the repo root
scripts/install_skills.sh             # install (or refresh) symlinks
scripts/install_skills.sh --dry-run   # preview, change nothing
scripts/install_skills.sh --uninstall # remove only the symlinks we own
```

The installer:

- creates `~/.claude/skills/<name>` as a symlink into this repo so edits in
  the repo update the live skill immediately,
- is idempotent — re-running is a no-op when targets already point here,
- **refuses to overwrite** any non-symlink at the destination, so a hand-rolled
  skill at `~/.claude/skills/now/` is never silently clobbered.

Override the destination with `CLAUDE_SKILLS_DIR=/some/path`.

## Required: register the MCP server

Skills only work if Claude Code can see the `claude-mind` MCP server. Register
it once:

```sh
claude mcp add claude-mind -- /absolute/path/to/.build/release/claude-mind-mcp
```

(See the main README for build instructions and environment knobs.)

## Tool surface (v1)

Skills wrap exactly the tools wired in `Sources/ClaudeMindMCP/main.swift`:

| skill            | MCP tool         | required args                    |
|------------------|------------------|----------------------------------|
| `/now`           | `now`            | —                                |
| `/parse_date`    | `parse_date`     | `text`                           |
| `/remember`      | `remember`       | `text`                           |
| `/recall`        | `recall`         | `query`                          |
| `/recall_around` | `recall_around`  | `anchor_id` OR `anchor_date`     |
| `/list_recent`   | `list_recent`    | —                                |
| `/forget`        | `forget`         | `id` (UUID)                      |

### Response contract for `recall` and `recall_around`

These skills require Claude to surface, for every hit:

1. memory **id** (UUID)
2. **timestamp** (`createdAt`, plus `occurredAt` when present)
3. **provenance** — `source`, `conversation_id`, `tags`, and `seed_source`
   (`["vector"]`, `["lexical","entity"]`, …) for `recall`; time-delta from
   anchor for `recall_around`
4. memory **text**

Provenance and timestamps are load-bearing for trust in retrieval. The skill
bodies say so explicitly so Claude does not summarize ids away.

## Not yet shipped

The main README lists `relative`, `calendar_context`, `relate`, and `traverse`
in the planned tool surface. As of this commit the server's dispatch returns
`"planned for v2"` for `relate`/`traverse` and does not register
`relative`/`calendar_context` at all. We deliberately do **not** ship skill
wrappers for tools that error — wrappers will be added as each lands.
