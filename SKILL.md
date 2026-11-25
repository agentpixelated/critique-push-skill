# critique-push — push user critiques to a tool's GitHub repo, from the user's point of view

When a user, while working with an agentic AI tool, criticises that tool —
a bug, a confusing behaviour, a missing feature, a wrong result — turn the
critique into a GitHub issue on the tool's own repo, written from the user's
point of view, with the agent acting only as the bridge.

The contract is `SPEC.md` + `critique-schema.json` (v0.1.0): one
critique record shape, shared by both adapters and the bridge. The
issue body is rendered from `templates/critique-template.md`.

## When to use

- The user says, in their own words, that something about the tool they are
  using is broken, confusing, missing, or wrong — and they want it reported,
  or they ask "report this / tell them / file this".
- The user explicitly asks for a critique, bug report, or feature request
  to be sent to the tool's developers on GitHub.
- A recurring friction the user keeps hitting comes up again and they agree
  it is worth reporting.

## When NOT to use

- The user is only venting, thinking aloud, or asking you to fix something
  locally — ask before reporting; never file an issue from a passing
  complaint without their go-ahead.
- The critique is about a different product than the tool in use, or the
  tool has no public GitHub repo — say so instead of filing nowhere.
- Anything containing secrets, tokens, credentials, private paths,
  screenshots of private data, or other people's personal information —
  strip it or refuse to file it, and tell the user what was left out.
- The user asked for the critique to stay private.

## Workflow

1. **Listen, don't paraphrase away the point.** Keep the user's own words
   for the problem and the expected behaviour. Ask at most one clarifying
   question, only if the repro steps or the expected behaviour are missing
   and you cannot infer them.
2. **Pick the adapter** for where this agent runs:
   - Persistent computer (Hermes, Codex CLI, omp, Claude Code, any CLI on
     a machine that survives reboots) → `adapters/dedicated/`.
   - Ephemeral computer (Muse, sandboxed sessions that vanish) →
     `adapters/ephemeral/` (separate adapter; do not use the queue here).
3. **Capture.** Write the critique as a structured file in the one
   `critique-schema.json` shape (see `adapters/dedicated/README.md` for
   the field list). Validate it before queuing.
4. **Queue, then flush.** On a dedicated machine the critique sits in
   `~/.critique-push/queue/` until flushed. Flush on a hook, on a cron, or
   manually with `capture.sh --flush`. Never drop a queued critique
   silently — a failed flush stays queued and the user is told.
5. **Push through the bridge.** The push goes through `bridge/push.py`
   (shared GitHub logic, one place). Adapters call the bridge; they never
   implement the GitHub API themselves.
6. **Receipt.** Save the issue URL + number + timestamp back to the queue
   file and print a one-line receipt to the user, e.g.
   `Filed: https://github.com/<owner>/<repo>/issues/123`.

## Authorship — the hard rule

- **Author is the user.** The issue body is written in the user's voice,
  from the user's point of view ("I tried…", "I expected…").
- **The agent is only the bridge.** Sign the footer with the agent id and
  the tool name, e.g. `Filed via critique-push by <agent-id> (<tool>) on
  behalf of the user`. Never present the agent as the user, never sign with
  the user's name, never impersonate.
- **No token ever touches disk in plaintext.** Auth is `gh` CLI login or a
  token from the environment / secret store only (see
  `adapters/dedicated/README.md`).

## Do

- Confirm the repo the issue goes to before filing (owner/repo from the
  tool's own docs or the user's config, never guessed).
- Keep the issue to one problem. Two problems = two critiques.
- Include repro steps, what happened, what was expected, and tool version
  when known.
- Dry-run first when unsure: `capture.sh --dry-run` prints the issue body
  and files nothing.
- Tell the user the issue URL, or tell them plainly if it failed and is
  still queued.

## Don't

- Don't file without the user's go-ahead (an explicit "report it" or a
  standing opt-in for this tool).
- Don't rewrite the user's critique into marketing-speak or soften it.
- Don't attach logs, screenshots, or files the user hasn't approved.
- Don't retry forever: max 3 flush attempts with backoff, then hold the
  critique queued and tell the user.
- Don't store, log, or echo any token, PAT, or credential.
- Don't reimplement GitHub API calls in an adapter — that is the bridge's
  job.

## Layout

```
critique-push-skill/
  SKILL.md                  — this file
  SPEC.md                   — schema, routing, templates (Subagent 1)
  critique-schema.json      — JSON schema for a critique (Subagent 1)
  bridge/                   — shared GitHub push logic (Subagent 3)
  adapters/
    dedicated/              — persistent-computer adapter (this skill's owner)
    ephemeral/              — ephemeral-computer adapter (Subagent 4)
  registry/                 — tool→repo mapping (placeholders only until
                              the user approves real repos)
  templates/                — issue-body templates (Subagent 1)
```

## Available connectors

- Use `muse.connector_search` to find other connectors and `muse.skill_search` to find related skills.

- If nothing here fits, look on the web for a maintained API or MCP server and set it up with [Custom Connectors and MCPs](/opt/muse/skills/custom-connector-setup/SKILL.md), or build a custom connector.
