# logmine — implement one accepted proposal

A human accepted the improvement proposal below (JSON, after `=== PROPOSAL ===`).
Implement it end-to-end. You are running headless with
`--dangerously-skip-permissions`; there is nobody to answer prompts.

## Scope — hard rule
Touch **only** the repo named in the proposal's `repo` field:
- `server-orchestrator` → `/home/agent/all-machines-at-work/server-orchestrator`
- `machines-at-work`     → `/home/agent/all-machines-at-work/machines-at-work`

Never touch project app code (bibbles, tell-your-friends). If the proposal cannot
be done within that one repo, STOP and report why instead of overreaching.

## Procedure
1. **Preserve the current state first.** In the target repo, before changing
   anything: if the working tree is dirty, commit it (`git add -A && git commit -m
   "logmine: snapshot before <title>"`) and push that commit to its branch. The
   point is that everything already on disk is safely in git history before
   logmine edits anything — so a bad change is a trivial `git revert`.
2. **Work on a fresh branch** off the current HEAD: `git checkout -b
   logmine/<short-slug>`. The guard forbids Claude sessions from pushing to
   `main`/`master`, so never commit onto or push the default branch.
3. **Make the change** described in `change`. Keep it minimal and mechanical —
   exactly what was proposed, nothing extra. Match the surrounding code's style
   and comment density.
   - `machines-at-work`: after editing scripts run `bash -n` on them and
     `bash tests/smoke.sh`; bump `version` in `.claude-plugin/plugin.json`
     (the project scaffolds auto-update off this version). Editing the plugin
     requires the session cwd to be inside the plugin root (the guard's
     dev-session exemption) — `cd` there first.
   - `server-orchestrator`: if you touched daemon.py, `python3 -m py_compile
     daemon.py`; run `bash tests/smoke.sh` if present.
4. **Commit** with a message that states the fix and quotes the motivating log
   evidence from the proposal. End with the standard trailers.
5. **Push the branch and open a PR** to the repo's default branch
   (`gh pr create`), body summarizing the change + evidence. Do not merge.
6. **Report** (your stdout is delivered to Telegram): one short paragraph — what
   you changed and the PR URL, or why you stopped. If you bumped the plugin
   version, say so and that a `claude plugin update` will propagate it.

Keep it tight. One proposal, one branch, one PR.
