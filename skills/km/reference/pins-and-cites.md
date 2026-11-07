# km reference: Source pins and cited files

## Contents

- Source pins (`km repin`)
- Cited files (`km cite add`, `km cites check`)

## Source pins (`km repin`)

`sources:` (a summary's inputs) and `translates:` (a translation's original) pin a source as `path.md@<hash>`, so a reader can tell whether the doc still matches its source. Write the pin with `km repin <doc>...`: it sets each pinned source that changed (or has no hash yet) to the blob of its current content, as staged, and leaves current pins alone. A blob pin depends only on the content, so it survives the rebase or squash merge that rewrites a PR's commits; a commit pin set on a PR branch points nowhere after such a merge. `km validate` compares every pin, blob or commit, with the source as staged and reports `pin:stale` once the source has changed. Only the body counts: approving, demoting or re-pinning the source changes its frontmatter, not its pins. A source that is `superseded` or `obsolete` is reported as `pin:old`. Re-review the doc against the change (`git diff` from the pinned content), then `km repin`; a signed-off doc whose pins change goes back to `status: review` without its approval and `reviewed_by`, so sign it off again with `km approve` in the same change: until then, served docs that link to it fail the gate. Stage the source first: an unstaged edit is not seen yet (repin says so). `km repin` needs km 1.4.0 in the brain's pins (`km upgrade`). A per-file run (the pre-commit hook) checks only the docs it is given, so a doc whose source changed is reported by the whole-repo `km validate` (CI), not when only the source is committed.

## Cited files (`km cite add`, `km cites check`)

When a doc cites a SharePoint or OneDrive file, record it under `cites:` with `km cite add <doc> <url> --file <synced copy>`: it stores the https URL, the sha256 of the copy's bytes and the date (add `--version` for a SharePoint version label). km makes no network request, so the copy must be on disk (a synced library, a download).

`km validate` checks the entries' format (`cite:format`, an error) and warns about a SharePoint or OneDrive link to a file in the body with no entry (`cite:missing`; http or https, a view or sharing query such as `?web=1`, a trailing slash and the case of a SharePoint host or path do not make another file, nor does a `/:b:/r/` sharing link that carries the path; sites, folders and pages are not files). A sharing link that names the file by a token or an id (`/:b:/g/...`, `/:w:/s/<site>/<token>`, 1drv.ms, Office's `Doc.aspx?sourcedoc=`, onedrive.live.com `?id=`) maps to no path: `km cite add` refuses it, cite the file's path URL instead.

`km cites check` compares each entry with a local copy, given per URL (`--file URL=PATH`) or through a synced library mapped to the URL it holds: `--dir "<local library>=https://<host>/sites/<site>/<library>"` (repeatable; the most specific prefix wins). Below the prefix the URL names exactly one local path (decoded, case-insensitive per segment); km does not search by name, so a file of another library or folder never counts. It reports `current`, `stale` or `unchecked` (no copy at that path, a URL under no `--dir` prefix, an unreadable copy).

When a cited file changed, re-review the doc against it, then `km repin --cites <doc> --dir "<local library>=<URL prefix>"` (or `--file`): like a source pin, a signed-off doc goes back to review. Adding a new cited file to a signed-off doc with `km cite add` sends it back too, since the approval never saw it; citing the same content again changes nothing. km rewrites the whole `cites:` block, so comments inside it are dropped. These commands need km 1.8.0 in the brain's pins.
