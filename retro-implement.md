# retro — apply one accepted proposal

A human accepted the machines-at-work improvement proposal below (full markdown
report, after `=== PROPOSAL ===`). It was written by `/machines-at-work:retro`
in a project workspace; you apply it in the plugin's own repo. You are running
headless with `--dangerously-skip-permissions`; there is nobody to answer
prompts.

## Scope — hard rule

The target is the **machines-at-work plugin repo**
(`/home/agent/all-machines-at-work/machines-at-work`) — your cwd. If a part of
the proposal's diff explicitly names files in
`/home/agent/all-machines-at-work/server-orchestrator`, apply that part there,
on its own branch + PR. Never touch project app code (bibbles,
tell-your-friends) or any project workspace. If the proposal cannot be done
within those repos, STOP and report why instead of overreaching.

## Procedure

1. **Preserve the current state first.** In each repo you will touch: if the
   working tree is dirty, commit it (`git add -A && git commit -m "retro:
   snapshot before <slug>"`) and push that commit to its branch — everything on
   disk must be in git history before you edit, so a bad change is a trivial
   revert.
2. **Work on a fresh branch** off the repo's default branch:
   `git checkout -b retro/<short-slug>`. The guard forbids pushing the default
   branch; never commit onto it.
3. **Make the change** in the proposal's "Proposed change" section — it is
   authoritative. Its diffs may be stale against current code: adapt line
   numbers and surrounding text, keep the substance exact, add nothing extra.
   Match the surrounding style and comment density. Copy the proposal file into
   `proposals/` (repo convention for applied retros).
4. **Verify.** machines-at-work: `bash -n` every edited script, then
   `bash tests/smoke.sh`; bump `version` in `.claude-plugin/plugin.json` (the
   project scaffolds auto-update off it). server-orchestrator: `python3 -m
   py_compile daemon.py` if touched, then `bash tests/smoke.sh`.
5. **Commit** referencing the proposal file (repo rule), quoting its key
   evidence. **Push the branch and open a PR** (`gh pr create`) to the default
   branch, body = what changed + the proposal's evidence and risk. Do not merge.
6. **Report** (your stdout is delivered to Telegram): one short paragraph —
   what you changed and the PR URL, or why you stopped. If you bumped the
   plugin version, say a `plugin`/🔌 run will propagate it after merge.

Keep it tight. One proposal, one branch, one PR per repo.
