# km reference: Review, pull requests and approval

## Contents

- Review (`/km review <doc>...`)
- Pull request preparation (`/km pr`)
  - Review of a PR you did not open
- Approval (`km approve`)

## Review (`/km review <doc>...`)

The author's own review before sign-off, run on the docs a branch adds or changes. Read-only until the last step: report findings, never fix the doc during the review.

1. **Rules first.** Read the brain's `CONVENTIONS.md`, `schema.local.yaml` and `CLAUDE.md`; they override anything general here. Run `km validate` on the docs; its errors are blocking findings. Its `pin:` warnings are not, but each one decides a check in step 3.
2. **Level.** Determine who may sign off (see Approval below). At level `human`, say so up front, review anyway, and hand the findings over. A missing `audience` is the author's to set: ask, do not set it yourself.
3. **Check the content, not the prose:**
   - every factual claim against its source (`sources`, linked docs, datasheets, the code it describes); a claim with no source and no evidence in the repo is a finding;
   - contradictions with docs already in the brain on the same topic (search by tags and terms);
   - numbers, units, part numbers and versions copied correctly from the source;
   - `audience` matches the content: a doc written for a customer or other outside reader that is marked internal, or has no audience, is blocking;
   - every pinned source (`sources`, `translates`) read against the doc. `pin:stale`: `git diff` from the pinned content shows the change; a doc that has not caught up with it is blocking, one that has is pinned in step 5. `pin:old`: the source was replaced; a doc still built on it is blocking, and repinning does not fix that;
   - `related`, `supersedes`, links and `_index.md` entries in place, and the doc reachable;
   - nothing that belongs elsewhere: a customer, project or person named outside where the brain's rules allow it, secrets, machine paths;
   - `owner` and a realistic `review_by` for the sign-off.
4. **Findings.** Each one names the file and line, what is wrong and the source that shows it. Blocking: wrong or unsupported facts, contradictions, validate errors, leaks. Not blocking: wording, style, structure preferences; mention them once, briefly, or leave them out.
5. **Outcome.** Blocking findings: list them and stop. Otherwise show the user the result, and on their OK:
   - a `draft` doc goes to `status: review` first (`km approve` signs off review docs);
   - `km repin <doc>` where a pin is stale or has no hash, so the approval covers the sources just checked (run after `km approve`, it would take the approval back); no `pin:` warning is left;
   - level `ai`: `km approve <doc> --by ai:<model> [--review-by YYYY-MM-DD]`, then commit it on its own, on top of the content commits (see "Approval");
   - level `human`: add `"ai:<model> <date>"` to `reviewed_by`, so the approver sees that an AI review ran, commit, and name who should sign off. Never change `audience`, `approval` or `type` to make a sign-off pass; `km approve` refuses what the level does not allow and gates the result with `km validate`.

## Pull request preparation (`/km pr`)

Runs on a brain branch before its first push, and again before pushing new commits to your own open PR: steps 1–5 before the push, step 6 once the PR exists. On a PR you did not open, run step 1 and the check in step 2 (no fixes), then post one review as below; never commit to or push their branch. `<base>` is the merge base with the brain's default branch.

1. **Review, sized to the PR.** The docs are the ones the branch adds or changes since `<base>`, or on an open PR since the head the PR body's `Last reviewed:` line records (all of them if that commit no longer resolves). Each reviewer is a separate agent running `/km review` steps 1–4 on its docs:
   - up to 4 docs: one reviewer, who also checks them against each other;
   - more: one per about three docs, grouped by folder or topic, at most six, plus one that checks them against each other and the brain.
2. **Verify, then fix.** Verify each finding against its named source; drop the unsupported ones. Commit the remaining fixes, one commit per doc, and have a fresh reviewer check only those commits.
3. **Fold.** One commit per doc or logical change: every later content commit on a doc (fixes, review fixes, earlier plain fix commits) goes into the branch's first commit that touches it (`git log --reverse --format=%h <base>.. -- <doc> | head -1`). Sign-off commits are never folded: leave them where they are. Note `git rev-parse HEAD` as `<before>`, write the rebase todo yourself with each such commit as `fixup <sha>` right under its target, and run `GIT_SEQUENCE_EDITOR="cp <todo-file>" git rebase -i <base>`. Afterwards `git diff <before> HEAD` must be empty. On a conflict, `git rebase --abort`, leave those commits unfolded and say so in the PR; do the same for a commit that changes docs from several commits.
4. **Sign-off.** `/km review` step 5 on the user's OK, as its own commit on top of the content (`docs(<scope>): approve <doc> (<approver>)`), so the history shows apart what was written and who signed it off. A doc whose content changed after its sign-off on this branch is signed off again.
5. **Push.** First push as the calling flow says. To your own open PR after a fold: `--force-with-lease=<branch>:<pushed-head>`, where `<pushed-head>` is the PR head you started from, read before your first commit (`gh pr view <N> --json headRefOid`, or `FETCH_HEAD` right after fetching `pull/<N>/head`), so a push someone made since is refused, not overwritten.
6. **Label and summary.** Exactly one label, set in one call (`gh pr edit <N> --add-label <label> --remove-label <the other two>`; pass the number, a detached HEAD has no current PR); first create all three with `gh label create <label> --force` where missing, or name the label in the PR when you lack the rights:
   - `km:ready`: every changed doc is accepted at its level; once CI is green it only needs a merge;
   - `km:needs-human`: a doc waits for a person's sign-off; the PR body names who;
   - `km:blocked`: blocking findings remain. The PR body carries a table of doc, level, findings and status, and the pushed head as a line `Last reviewed: <full sha>` (replace the earlier one).

### Review of a PR you did not open

`<repo>` is the owner/repo in the PR's URL, `<head>` its `headRefOid`, read when the review starts; fetch `pull/<N>/head` and review that tree, so findings carry its line numbers. Step 1 ignores the author's `Last reviewed:` line: it covers the docs changed since `<base>`, or on a new head since the `commit_id` of your last review there (`gh api repos/<repo>/pulls/<N>/reviews`, `user.login` as `gh api user -q .login`; `<base>` if that commit no longer resolves). One review per reviewed head, the payload built with `jq -n` (findings quote text), posted with `gh api repos/<repo>/pulls/<N>/reviews --method POST --input -`: `{"commit_id": "<head>", "event": "COMMENT", "body": "<summary>", "comments": [{"path": "<file>", "line": <n>, "side": "RIGHT", "body": "<finding>"}]}`.
- `comments`: one per finding on a line inside a hunk of `gh pr diff <N> -R <repo>` (with MCP only, the `get_files` patches); `line` is its line number in the file at `<head>`. A removed line takes `side` `LEFT` and its number in the base; a range adds `start_line` and `start_side`.
- `body`: the verdict with the count of blocking findings, then each finding on no diff line with its file and line. Blocking findings (`/km review` step 4) come first and say so.
- Never `APPROVE` or `REQUEST_CHANGES`: that is the human reviewer's call; recommend it in chat only.
- Show the user the full review (body and line comments) and post only on their OK. Where gh cannot write (none, or 401/403 for this repo), post nothing, as in "GitHub access" (SKILL.md): give the user the payload and the exact `gh api` command. On a 422 for a line, move that comment into `body` and post again.
- A new head gets a new review without the findings fixed since; never delete or resolve the old comments.

## Approval (`km approve`)

`km approve <doc>... --by WHO [--at YYYY-MM-DD] [--review-by YYYY-MM-DD]` moves a `status: review` doc to `accepted` and records `approved_by` / `approved_at` and `approved_digest` (the content it approved), then gates it with `km validate` and restores it byte for byte if that fails. The docs of one call are gated together, so docs that link to each other are signed off in one call: alone, each would link to a doc still in review. A doc whose `review_by` has passed (typically one CI demoted) is refused until `--review-by` sets a new date.

- **Levels:** `approval: human` needs a person; `approval: ai` lets an AI review alone sign off, written `--by ai:<model>`. Unset, the level is the brain's `approval_default` in `schema.local.yaml` (`human` when absent). An AI sign-off needs a doc marked `audience: internal` that is not a `verbatim-block`; customer-facing docs, any other audience and docs without one need a person. `km validate` enforces it on signed-off docs (metadata, not authentication).
- **Commit:** commit the approval on its own, on top of the content commits, as `docs(<scope>): approve <doc> (<approver>)`, never folded into them: the history then shows apart what was written and who signed it off. `km approve` only edits the files; it does not commit. This holds however the sign-off was started, also for a plain `/km approve`.
- **After a change:** an approval covers the content it saw: the body and the content fields (`title`, `description`, `type`, `audience`, `claim_category`, `valid_for`, `evidence`, `participants`, `resource`, `language`, `license`). Changing any of them on an accepted doc makes `km validate` report `approval-stale` (an error with the gate on, as in a team brain, so the pre-commit hook refuses the commit; a warning without it). So an edit to an accepted doc sends it back to review in the same commit: `km demote <doc>` sets `status: review` and drops the approval and `reviewed_by`; the approval follows after review, in its own commit as above. Quote versions and numbers in those fields (`valid_for: "1.10"`): YAML reads `1.10` as 1.1, and `km validate` warns about an unquoted one. Bookkeeping (`tags`, `project`, dates, `owner`, `reviewed_by`, links, pins, `cites`) does not touch it; `km repin` and a `km cite add` that changes cited content send the doc back to review anyway. A doc approved before km recorded the digest is not checked until `km upgrade` records one, or `km approve` on it records its content and keeps its approver.
- **Pre-reviews:** `reviewed_by` (a list) records them, e.g. a PR bot's model, date and PR; it is not an approval. `promote` and `--replace` drop it with the approval; a cross-repo promote also drops `approval`, so the target brain decides its own level.
- **Required fields:** `status_rules` keys are `<status>_<requires|recommends|forbids>`, e.g. `accepted_requires: [owner, review_by]` in `schema.local.yaml`.
