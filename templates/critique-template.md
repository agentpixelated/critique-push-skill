<!-- critique-push issue template.
     Fill every placeholder from the validated critique record.
     Placeholders are single-brace names, substituted by bridge/push.py
     (render() builds a flat mapping; sections and lists are pre-rendered
     there, e.g. repro_steps is already a numbered list or a "not
     observed" line). There is no mustache logic in this file — no
     conditionals or loops — so what you see here is exactly
     what the bridge can fill. Sections marked AGENT-ADDED are the only
     places agent-observed evidence may appear. Never invent repro steps,
     severity, or version. Language: the user's language. -->

> {what_happened}

<!-- Verbatim quote of the user's own words. Keep it exact. -->

## Expected

{expected}

## Actual

{actual}

## Steps to reproduce

{repro_steps}

## Impact

{impact}

## Environment

- Tool: {tool_line}
- OS: {environment_os}
- Runtime: {environment_runtime}
- Date: {date_wib}

## Agent-added evidence

<!-- Only facts the agent actually observed (command output, logs,
     version strings). Nothing guessed. Delete this section if empty. -->

{evidence}

---
<!-- Footer, added by the adapter at push time. Do not edit by hand. -->
_Filed via critique-push · critique id `{id}` · category `{category}`_
