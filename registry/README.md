# Registry — tool → GitHub repo mapping

Resolves a `tool_name` to the `target_repo` (`owner/repo`) a critique is
filed against. **No real repos are mapped yet** — every entry below is a
placeholder. Until the user approves a real mapping for a tool, critiques
about that tool must be given `--repo owner/repo` explicitly, and a
critique with no resolvable repo is saved locally as `pending-unmapped`
(SPEC.md) — never pushed to a guessed repo.

## Format (`tools.yaml`)

```yaml
tools:
  - tool_name: codex            # must match critique-schema.json `tool_name`
    target_repo: OWNER/REPO     # placeholder until the user approves the real repo
    notes: "placeholder — no real repo mapped yet"
```

## Rules

- One entry per tool. `tool_name` is the key; it must match the name the
  adapters record (`codex`, `claude-code`, `omp`, `hermes`, …).
- `target_repo` is `owner/repo` of the tool's own public repo, taken from
  the tool's own docs — never guessed, never a fork, never a personal repo
  unless the user says so.
- Adding a real mapping needs the user's approval for that tool (SPEC.md:
  "Which repos are in the registry and who maintains the mapping" is an
  open decision for the user).
- Adapters do not read this file yet — resolution is manual (`--repo`)
  until an adapter wires it in. This directory exists so the mapping has
  one home when that lands.
