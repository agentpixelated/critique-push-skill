#!/usr/bin/env python3
"""critique-push bridge — the one push engine both adapters call.

Shared by the dedicated-computer adapter (Hermes / Codex / omp / Claude Code
/ any CLI agent on a persistent machine) and the ephemeral-computer adapter
(Muse), so a critique pushed from either path is rendered, deduped, and
filed identically.

Usage:
    push.py --critique <critique.json> --repo <owner/repo> [--dry-run|--live]
    push.py --critique <critique.json> --repo <owner/repo> --labels bug,ux

Behaviour:
- Default is --dry-run: validates, renders, prints the dedup search it
  WOULD run and the exact issue title/body it WOULD file, and prints a
  receipt with issue_url=null. Nothing leaves the machine.
- --live requires BOTH the flag AND a token: GH_TOKEN or GITHUB_TOKEN from
  the environment, or an already-authenticated `gh` CLI. A token is NEVER
  accepted as a CLI argument, NEVER logged, and NEVER written to disk.
- Dedup: before creating, searches existing issues by title keywords
  (`gh issue list --search`). A match is reported, not silently re-filed.
- Create: `gh issue create` subprocess first; fallback is GitHub REST via
  urllib (stdlib only) with the env token.
- Receipt: prints JSON {issue_url, issue_number, repo, pushed_at,
  critique_id} on stdout and exits 0 on success; exits non-zero with a
  clear stderr message on any failure. No silent success.

Stdlib only. No new dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent

SCHEMA_PATH = REPO_ROOT / "critique-schema.json"
# The template lives at the repo root (templates/), not under bridge/.
# One path, one placeholder style: {single-brace} names, substituted in
# render() below. See templates/critique-template.md.
TEMPLATE_PATH = REPO_ROOT / "templates" / "critique-template.md"

# Minimal required fields when critique-schema.json is not present.
REQUIRED_FIELDS = ("tool", "title", "body", "date")

BUILTIN_TEMPLATE = """## User's words

{user_words}

## What happened

{body}

## Agent-added evidence

{evidence}

---
*Filed from the user's point of view by their agentic AI via critique-push.*
*User's words are quoted verbatim above; anything under "Agent-added evidence"*
*was observed by the agent and is labelled as such. No reproduction steps were*
*invented — if the user did not describe them, they are not here.*
"""


class PushError(Exception):
    """Fatal, user-facing push failure."""


def load_critique(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise PushError(f"critique file not found: {path}")
    except json.JSONDecodeError as exc:
        raise PushError(f"critique file is not valid JSON ({path}): {exc}")
    if not isinstance(data, dict):
        raise PushError(f"critique file must contain a JSON object: {path}")
    return data


def validate(critique: dict) -> None:
    """Validate against critique-schema.json — the single contract.

    critique-schema.json is authoritative: its `required` list, its
    `additionalProperties: false`, and its field formats are all enforced
    here (stdlib only, hand-rolled). On top of the schema, the bridge's
    own minimal contract is enforced too: `tool`, `title`, `body`, and
    `date` (YYYY-MM-DD) must be present, and the bridge-compat aliases
    must agree with the schema fields they mirror (`tool` == `tool_name`,
    `body` == `what_happened`, `date` == the date part of `date_wib`).
    Anything failing any of these is rejected with a named field — never
    silently accepted.
    """
    missing = [f for f in REQUIRED_FIELDS
               if not isinstance(critique.get(f), str) or not critique[f].strip()]
    if missing:
        raise PushError(
            f"critique missing required field(s): {', '.join(missing)} "
            f"(required: {', '.join(REQUIRED_FIELDS)})")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", critique["date"].strip()):
        raise PushError(
            f"critique field 'date' must be YYYY-MM-DD, got: {critique['date']!r}")
    if not SCHEMA_PATH.exists():
        raise PushError(
            f"critique-schema.json not found at {SCHEMA_PATH}; refusing to "
            f"validate against an unknown contract")
    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        raise PushError(f"cannot read critique-schema.json: {exc}")
    for field in schema.get("required", []):
        if field not in critique or critique[field] in (None, "", []):
            raise PushError(
                f"critique fails critique-schema.json: missing required "
                f"field {field!r}")
    allowed = set(schema.get("properties", {}))
    unknown = sorted(set(critique) - allowed)
    if unknown:
        raise PushError(
            f"critique fails critique-schema.json: unknown field(s) "
            f"{', '.join(unknown)} (additionalProperties is false — "
            f"declare the field in the schema or drop it)")
    if critique.get("tool") and critique.get("tool_name") \
            and critique["tool"] != critique["tool_name"]:
        raise PushError(
            f"critique field 'tool' ({critique['tool']!r}) disagrees with "
            f"'tool_name' ({critique['tool_name']!r}); they must match")
    if critique.get("body") and critique.get("what_happened") \
            and critique["body"] != critique["what_happened"]:
        raise PushError(
            "critique field 'body' disagrees with 'what_happened'; "
            "they must be the same text")
    date_wib = critique.get("date_wib", "")
    if date_wib and not re.fullmatch(
            r"\d{4}-\d{2}-\d{2} \d{2}:\d{2} WIB", date_wib):
        raise PushError(
            f"critique field 'date_wib' must be 'YYYY-MM-DD HH:mm WIB', "
            f"got: {date_wib!r}")
    if date_wib and date_wib[:10] != critique["date"].strip():
        raise PushError(
            f"critique field 'date' ({critique['date']!r}) disagrees with "
            f"'date_wib' ({date_wib!r}); they must be the same day")
    category = critique.get("category")
    if category not in ("bug", "ux-friction", "wrong-output",
                        "missing-feature", "confusing-copy", "other"):
        raise PushError(f"critique field 'category' invalid: {category!r}")
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", critique.get("target_repo", "")):
        raise PushError(
            f"critique field 'target_repo' must be 'owner/repo', got: "
            f"{critique.get('target_repo')!r}")
    env = critique.get("environment")
    if not isinstance(env, dict) or not env.get("os"):
        raise PushError(
            "critique field 'environment.os' is required and must be "
            "non-empty")


def render(critique: dict) -> tuple[str, str]:
    """Return (title, body).

    Title: the critique's title is used as-is when it already carries
    SPEC's `[<category>]` prefix; otherwise the category is prepended.
    The bridge never prepends `[<tool>]` — a title that already says
    `[bug] ...` must not come out as `[tool] [bug] ...`.

    Body: rendered from templates/critique-template.md (repo root) when
    present, else the built-in template. Both use the same flat
    {single-brace} mapping below — lists and conditionals are pre-rendered
    here (repro_steps, tool_line), never in the template.
    """
    title = critique["title"].strip()
    if not title.startswith("["):
        title = f"[{critique['category']}] {title}"
    env = critique.get("environment") or {}
    steps = critique.get("repro_steps") or []
    if steps:
        repro_steps = "\n".join(f"{i + 1}. {s}" for i, s in enumerate(steps))
    else:
        repro_steps = "_Not observed — no repro steps were run or described._"
    tool_line = critique["tool_name"]
    if critique.get("tool_version"):
        tool_line += f" {critique['tool_version']}"
    if critique.get("tool_commit"):
        tool_line += f" ({critique['tool_commit']})"
    mapping = {
        "user_words": str(critique.get("user_words") or critique["body"]).strip(),
        "body": critique["body"].strip(),
        "evidence": str(critique.get("evidence") or "None recorded by the agent.").strip(),
        "tool": critique["tool"].strip(),
        "tool_name": critique["tool_name"].strip(),
        "tool_line": tool_line,
        "tool_version": str(critique.get("tool_version") or ""),
        "tool_commit": str(critique.get("tool_commit") or ""),
        "date": critique["date"].strip(),
        "date_wib": critique.get("date_wib", "").strip(),
        "title": critique["title"].strip(),
        "category": critique["category"],
        "id": str(critique.get("id") or ""),
        "what_happened": critique["what_happened"].strip(),
        "expected": critique["expected"].strip(),
        "actual": critique["actual"].strip(),
        "impact": critique["impact"].strip(),
        "repro_steps": repro_steps,
        "environment_os": str(env.get("os") or "unknown"),
        "environment_runtime": str(env.get("runtime") or "unknown"),
        "target_repo": critique.get("target_repo", ""),
        "dedup_key": critique.get("dedup_key", ""),
        "status": critique.get("status", ""),
    }
    if TEMPLATE_PATH.exists():
        template = TEMPLATE_PATH.read_text(encoding="utf-8")
    else:
        template = BUILTIN_TEMPLATE
    body = template
    for key, value in mapping.items():
        body = body.replace("{" + key + "}", value)
    leftover = re.findall(r"\{[a-z_]+\}", body)
    if leftover:
        print(f"[warn] template placeholders left unfilled: "
              f"{sorted(set(leftover))}", file=sys.stderr)
    return title, body


def dedup_search_terms(title: str) -> str:
    """Keywords for the existing-issue search: distinctive words from the
    title, stopwords dropped, capped so the query stays useful."""
    stopwords = {"the", "a", "an", "and", "or", "of", "to", "in", "on",
                 "for", "with", "is", "it", "my", "when", "after"}
    words = [w.strip("[]()\"'.,:;!?") for w in title.lower().split()]
    keywords = [w for w in words if len(w) > 2 and w not in stopwords]
    return " ".join(keywords[:6])


def gh_available() -> bool:
    try:
        result = subprocess.run(["gh", "auth", "status"],
                                capture_output=True, text=True, timeout=15)
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def get_token() -> str | None:
    """Token from environment ONLY. Never from argv, never logged."""
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or None


def dedup_check(repo: str, title: str, dry_run: bool) -> list[dict]:
    """Search existing issues by title keywords. Returns matches (possibly
    empty). In dry-run, prints the command it would run and returns []."""
    query = dedup_search_terms(title)
    cmd = ["gh", "issue", "list", "--repo", repo, "--search", query,
           "--limit", "10", "--json", "number,title,url,state"]
    if dry_run:
        print(f"[dry-run] dedup search (not run): {' '.join(cmd)}",
              file=sys.stderr)
        return []
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=60)
    except FileNotFoundError:
        print("[warn] `gh` not found; skipping dedup check",
              file=sys.stderr)
        return []
    if result.returncode != 0:
        print(f"[warn] dedup search failed ({result.stderr.strip()}); "
              f"continuing without dedup", file=sys.stderr)
        return []
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return []


def create_via_gh(repo: str, title: str, body: str,
                  labels: list[str]) -> dict:
    cmd = ["gh", "issue", "create", "--repo", repo,
           "--title", title, "--body", body]
    for label in labels:
        cmd += ["--label", label]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise PushError(f"`gh issue create` failed: {result.stderr.strip()}")
    url = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    number = None
    match = re.search(r"/issues/(\d+)\s*$", url)
    if match:
        number = int(match.group(1))
    return {"issue_url": url or None, "issue_number": number}


def create_via_rest(repo: str, title: str, body: str,
                    labels: list[str], token: str) -> dict:
    owner_repo = repo.split("/", 1)
    if len(owner_repo) != 2 or not all(owner_repo):
        raise PushError(f"repo must be 'owner/repo', got: {repo!r}")
    url = f"https://api.github.com/repos/{repo}/issues"
    payload = json.dumps({"title": title, "body": body,
                          "labels": labels}).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "User-Agent": "critique-push-bridge"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise PushError(f"GitHub REST create failed ({exc.code}): {detail}")
    except urllib.error.URLError as exc:
        raise PushError(f"GitHub REST request failed: {exc}")
    return {"issue_url": data.get("html_url"),
            "issue_number": data.get("number")}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Push a user critique to GitHub as an issue "
                    "(dry-run by default).")
    parser.add_argument("--critique", required=True,
                        help="path to critique JSON file")
    parser.add_argument("--repo", required=True,
                        help="target repo as owner/repo")
    parser.add_argument("--labels", default="",
                        help="comma-separated labels (default: none)")
    parser.add_argument("--dry-run", action="store_true", default=True,
                        help="validate + render only; nothing is pushed "
                             "(default)")
    parser.add_argument("--live", action="store_true",
                        help="actually create the GitHub issue; requires a "
                             "token from GH_TOKEN/GITHUB_TOKEN or `gh auth`")
    args = parser.parse_args(argv)

    dry_run = not args.live
    if "/" not in args.repo or args.repo.count("/") != 1:
        print(f"error: --repo must be 'owner/repo', got: {args.repo!r}",
              file=sys.stderr)
        return 2

    labels = [l.strip() for l in args.labels.split(",") if l.strip()]

    try:
        critique = load_critique(Path(args.critique))
        validate(critique)
        title, body = render(critique)
    except PushError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    matches = dedup_check(args.repo, title, dry_run)
    if matches:
        print("error: possible duplicate — matching existing issue(s):",
              file=sys.stderr)
        for m in matches:
            print(f"  #{m.get('number')} [{m.get('state')}] "
                  f"{m.get('title')} — {m.get('url')}", file=sys.stderr)
        print("Refine the critique title/body or confirm it is distinct "
              "before pushing.", file=sys.stderr)
        return 3

    critique_id = critique.get("id") or critique.get("critique_id") or ""
    pushed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    if dry_run:
        print(f"[dry-run] repo: {args.repo}", file=sys.stderr)
        print(f"[dry-run] labels: {labels or '(none)'}", file=sys.stderr)
        print(f"[dry-run] title: {title}", file=sys.stderr)
        print("[dry-run] body:", file=sys.stderr)
        print(body, file=sys.stderr)
        receipt = {"issue_url": None, "issue_number": None,
                   "repo": args.repo, "pushed_at": pushed_at,
                   "critique_id": critique_id, "dry_run": True}
        print(json.dumps(receipt, indent=2))
        return 0

    # --- live path ---
    token = get_token()
    if not token and not gh_available():
        print("error: --live needs a token (GH_TOKEN or GITHUB_TOKEN env) "
              "or an authenticated `gh` CLI (`gh auth login`). No token "
              "was found and `gh auth status` failed. Nothing was pushed.",
              file=sys.stderr)
        return 2

    try:
        if gh_available():
            created = create_via_gh(args.repo, title, body, labels)
        elif token:
            created = create_via_rest(args.repo, title, body, labels, token)
        else:  # pragma: no cover — guarded above
            raise PushError("no authenticated push path available")
    except PushError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not created.get("issue_url"):
        print("error: issue creation reported success but returned no URL; "
              "treat as failed and check the repo manually.",
              file=sys.stderr)
        return 1

    receipt = {"issue_url": created["issue_url"],
               "issue_number": created["issue_number"],
               "repo": args.repo, "pushed_at": pushed_at,
               "critique_id": critique_id, "dry_run": False}
    print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
