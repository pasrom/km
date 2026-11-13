"""The dummy team brain the e2e run starts from: `seed.py build OUT --km CMD [--date D] [--mount URL@SHA]`.

All content is invented (a fictional garden lamp, project code p9001, customer Northwind). The brain
is written by the km that `--km` runs (the baseline release: `km init --team`, the sign-offs by `km
approve`, the pins by `km repin`), so seeding is also a local test of that km. The result is one git
history on `main` with fixed identities and commit dates: the same inputs (km, date, mount) give the
same commits. Dates in the docs are relative to `--date` (default: today). `km init` stamps its own
files with the day it runs, so a seed built on another day than `--date` differs in those lines.

Sign-off order matters: `km approve` refuses a served doc that links to a page still in review
(gate-bergab), so link targets are approved before the pages that link to them.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROSTER = ["AAA", "BBB", "CCC", "DDD"]       # AAA is the maintainer; ZZZ is deliberately not on it
AI = "ai:e2e-seed"                           # the AI sign-off the seed records
FOLDERS = [("process", "How the sandbox team works"), ("product", "The invented Lumen garden lamp"),
           ("projects", "Invented customer projects, one folder per project code")]
NO_LOGIN = {"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_CONFIG_DIR", "GH_HOST", "GIT_ASKPASS", "SSH_ASKPASS"}
IDENT = {"GIT_AUTHOR_NAME": "km e2e seed", "GIT_AUTHOR_EMAIL": "seed@e2e.invalid",
         "GIT_COMMITTER_NAME": "km e2e seed", "GIT_COMMITTER_EMAIL": "seed@e2e.invalid"}

SCHEMA = """\
# schema.local.yaml of the e2e sandbox brain (invented data). Written by the km e2e seed.
meta:
  profile: "e2e-brain"
author_default: "AAA"
approval_default: ai
check_index: true
skip_prefixes: [mounted/]
gate:
  enabled: true
  served_status: accepted
  customer_audience: customer
  project_prefix: projects/
  project_code_pattern: 'p[0-9]+'
status_rules:
  accepted_requires: [owner, review_by]
  review_requires: [owner]
  review_recommends: [reviewed_by]
owners: [AAA, BBB, CCC, DDD]
"""

# make_plot.py writes the SVG below from data.csv (stdlib only, so it reruns anywhere)
PLOT_SCRIPT = '''\
"""Writes plot.svg from data.csv: lamp housing temperature over runtime (invented data)."""
import csv
from pathlib import Path

here = Path(__file__).parent
rows = [(float(h), float(t)) for h, t in csv.reader((here / "data.csv").read_text().splitlines()[1:])]
pts = " ".join(f"{20 + h * 40:.0f},{120 - t * 2:.0f}" for h, t in rows)
(here / "plot.svg").write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="360" height="140" viewBox="0 0 360 140">\\n'
    f'  <polyline fill="none" stroke="black" points="{pts}"/>\\n'
    "</svg>\\n")
'''
PLOT_DATA = "hours,celsius\n0,20\n2,31\n4,36\n6,38\n8,39\n"


def plot_svg() -> str:
    """The SVG make_plot.py writes from PLOT_DATA (computed the same way, so the seed needs no run)."""
    rows = [tuple(map(float, line.split(","))) for line in PLOT_DATA.splitlines()[1:]]
    pts = " ".join(f"{20 + h * 40:.0f},{120 - t * 2:.0f}" for h, t in rows)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="360" height="140" viewBox="0 0 360 140">\n'
            f'  <polyline fill="none" stroke="black" points="{pts}"/>\n</svg>\n')


def fm(**fields) -> str:
    """A frontmatter block; values are written as given (strings that need quotes carry them)."""
    lines = [f"{k}: {v}" for k, v in fields.items() if v is not None]
    return "---\n" + "\n".join(lines) + "\n---\n\n"


def doc(type_, title, author, status, body, *, owner=None, audience="internal", **extra) -> str:
    return fm(type=type_, title=f'"{title}"', timestamp="<D>", author=author, owner=owner or author,
              status=status, audience=audience, language="en", **extra) + body


# The pages of the concept's data set (section 2.3), all written in review first; build() then signs
# them off in dependency order. <D> is replaced by the seed date.
PAGES = {
    "process/review-rules.md": doc(
        "concept", "Review rules of the sandbox team", "AAA", "review", tags="[process, review]",
        body="# Review rules\n\nEvery page is reviewed before it is served. Invented test data.\n"),
    "process/label-guide.md": doc(
        "reference", "Label guide of the sandbox team", "BBB", "review", approval="human",
        tags="[process, labels]",
        body="# Label guide\n\n- km:ready: every changed page is signed off at its level.\n"
             "- km:needs-human: a page waits for a person.\n- km:blocked: a review finding blocks the merge.\n\n"
             "See also [review rules](review-rules.md).\n"),
    "process/how-we-work.md": doc(
        "reference", "How the sandbox team works", "AAA", "review", tags="[process, sandbox]",
        body="# How the sandbox team works\n\nPages change by pull request. The rules for reviews are in "
             "[review rules](review-rules.md), the labels in [label guide](label-guide.md). The charging "
             "advice is in [charging note](../product/charging-note.md). All content is invented test data.\n"),
    "process/onboarding.md": doc(
        "note", "Onboarding checklist", "AAA", "draft", tags="[process, onboarding]",
        body="# Onboarding\n\n1. Read the review rules.\n2. Ask for access.\n"),
    "process/glossary.md": fm(
        type="reference", title='"Glossary of the sandbox team"', timestamp="<D>", author="CCC", owner="CCC",
        status="review", language="en", tags="[process, glossary]",
        reviewed_by=f'["{AI} <D> (seed)"]')
        + "# Glossary\n\n- Lumen: the invented garden lamp.\n- Runtime: hours on one charge.\n",
    "product/lamp-overview.md": doc(
        "concept", "Lumen garden lamp overview", "AAA", "review", tags="[product, overview]",
        body="# Lumen garden lamp\n\nA solar garden lamp with a 2 Ah cell. Invented product.\n"),
    "product/battery-choice.md": doc(
        "decision", "Battery choice for the Lumen lamp", "BBB", "review", tags="[product, battery]",
        body="# Decision\n\nWe use one LiFePO4 cell of 2 Ah. Invented decision.\n"),
    "product/charging-note.md": doc(
        "note", "Charging note for the Lumen lamp", "CCC", "review", tags="[product, charging]",
        body="# Charging\n\nCharge between 0 and 45 degrees Celsius. Invented note.\n"),
    "product/kickoff-2026-01.md": doc(
        "transcript", "Lumen kickoff meeting", "AAA", "review", tags="[product, meeting]",
        participants="[AAA, BBB, CCC]",
        body="# Kickoff\n\nAAA: We start with the lamp housing.\nBBB: The cell is chosen.\n"),
    "product/datasheet-quote.md": doc(
        "verbatim-block", "Datasheet sentence on the lamp runtime", "CCC", "review", tags="[product, datasheet]",
        body="The Lumen garden lamp runs for up to eight hours on a full charge.\n"),
    "product/lamp-summary.md": doc(
        "summary", "Summary of the Lumen lamp decisions", "BBB", "review", tags="[product, summary]",
        sources="[product/battery-choice.md]", reviewed_by=f'["{AI} <D> (seed)"]',
        body="# Summary\n\nThe lamp uses one LiFePO4 cell ([decision](battery-choice.md)).\n"),
    "product/test-report.md": doc(
        "artifact", "Runtime test report", "CCC", "review", tags="[product, test]",
        body="# Runtime test\n\nMeasured runtime: 8.2 hours at 20 degrees Celsius. Invented data.\n"),
    "product/thermal-plot.md": doc(
        "reference", "Housing temperature over runtime", "BBB", "review", tags="[product, thermal]",
        body="# Housing temperature\n\n![temperature over runtime](thermal-plot_media/plot.svg)\n\n"
             "Regenerate the plot with `python3 thermal-plot_media/make_plot.py` (reads `data.csv` beside it).\n"),
    "product/old-charger.md": fm(
        type="concept", title='"Charger, first version"', timestamp="<D>", author="BBB", owner="BBB",
        status="superseded", audience="internal", language="en", tags="[product, charger]",
        superseded_by="product/new-charger.md")
        + "# Old charger\n\nA 5 V charger. Replaced. Invented.\n",
    "product/new-charger.md": doc(
        "concept", "Charger, second version", "BBB", "review", tags="[product, charger]",
        supersedes="product/old-charger.md",
        body="# New charger\n\nA USB-C charger. Invented.\n"),
    "product/supplier-list.md": doc(
        "reference", "Supplier list", "DDD", "review", tags="[product, suppliers]",
        body="# Suppliers\n\n- Cells: an invented supplier.\n- Housing: another invented supplier.\n"),
    "product/cited-spec.md": doc(
        "reference", "Runtime specification", "AAA", "review", tags="[product, spec]",
        sources="[product/test-report.md]",
        body="# Runtime specification\n\nThe lamp runs at least eight hours, see the "
             "[test report](test-report.md).\n"),
    "projects/p9001/_index.md": fm(
        type="reference", title='"projects/p9001/"',
        description='"fictional project p9001: Lumen garden lamps for the fictional customer Northwind"',
        timestamp="<D>", author='"AAA"', status="draft", tags='["projects", "p9001", index]')
        + "# p9001\n\nFictional project p9001: Lumen garden lamps for the fictional customer Northwind.\n\n"
          "## Documents\n",
    "projects/p9001/customer-manual.md": fm(
        type="reference", title='"Lumen garden lamp customer manual"', timestamp="<D>", author="BBB", owner="BBB",
        status="review", audience="customer", language="en", project="p9001", tags="[manual, customer]")
        + "# Manual\n\nPlace the lamp in the sun for one day before first use.\n",
    "projects/p9001/customer-faq.md": fm(
        type="note", title='"Lumen garden lamp customer FAQ"', timestamp="<D>", author="BBB", owner="BBB",
        status="review", audience="customer", language="en", project="p9001", tags="[faq, customer]",
        reviewed_by=f'["{AI} <D> (seed)"]')
        + "# FAQ\n\nQ: Can the lamp stay outside in winter?\n\nA: Yes, in this invented product.\n",
    "projects/p9001/offer-notes.md": fm(
        type="note", title='"Offer notes for project p9001"', timestamp="<D>", author="AAA", owner="AAA",
        status="review", audience="internal", language="en", project="p9001", tags="[offer]")
        + "# Offer notes\n\n100 lamps for the fictional customer Northwind. Invented.\n",
}
MEDIA = {"product/thermal-plot_media/make_plot.py": PLOT_SCRIPT,
         "product/thermal-plot_media/data.csv": PLOT_DATA,
         "product/thermal-plot_media/plot.svg": plot_svg()}

# Sign-offs, in order: (docs, by). Link targets first: how-we-work links review-rules, label-guide
# and charging-note; cited-spec is signed after its source pin (below).
AI_FIRST = ["process/review-rules.md", "product/lamp-overview.md", "product/battery-choice.md",
            "product/charging-note.md", "product/kickoff-2026-01.md", "product/test-report.md",
            "product/thermal-plot.md", "product/new-charger.md", "product/supplier-list.md",
            "projects/p9001/offer-notes.md"]
HUMAN = [(["process/label-guide.md", "projects/p9001/customer-manual.md"], "BBB"),
         (["product/datasheet-quote.md"], "CCC")]
LAST = ["process/how-we-work.md"]
LAPSED = ["product/lamp-overview.md", "product/charging-note.md"]   # review_by in the past: staleness demotes
OLD_DECISION = "product/battery-choice.md"                           # a decision does not expire
PINNED = ["product/lamp-summary.md", "product/cited-spec.md"]        # km repin writes their source blobs
SIGNED_AFTER_PIN = "product/cited-spec.md"


def pages(date: datetime.date) -> dict[str, str]:
    """Every file the seed writes on top of `km init`, with the dates filled in (pure: no km, no git)."""
    out = {"schema.local.yaml": SCHEMA, **MEDIA}
    out |= {p: t.replace("<D>", date.isoformat()) for p, t in PAGES.items()}
    return out


def write_pages(out: Path, date: datetime.date) -> None:
    for rel, text in pages(date).items():
        (out / rel).parent.mkdir(parents=True, exist_ok=True)
        (out / rel).write_text(text, encoding="utf-8")


def set_review_by(path: Path, day: datetime.date) -> None:
    """Set a doc's review_by (bookkeeping: it does not touch the approval); a doc without one gets the
    line at the end of its frontmatter."""
    text, line = path.read_text(encoding="utf-8"), f"review_by: {day.isoformat()}"
    text, n = re.subn(r"(?m)^review_by:.*$", line, text, count=1)
    if not n:
        head, sep, body = text.partition("\n---\n")       # the closing line of the frontmatter
        text = f"{head}\n{line}{sep}{body}"
    path.write_text(text, encoding="utf-8")


class Builder:
    def __init__(self, out: Path, km: list[str], date: datetime.date):
        self.out, self.km_cmd, self.date, self.n = out, km, date, 0
        # no GitHub login of the machine's user reaches km or git: an empty gh config, no tokens, no prompts
        self.env = {k: v for k, v in os.environ.items() if k not in NO_LOGIN}
        self.env |= {**IDENT, "KM_LOCAL": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                     "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                     "GH_CONFIG_DIR": tempfile.mkdtemp(prefix="km-e2e-seed-gh-")}

    def run(self, *cmd: str) -> str:
        try:                              # km through uvx may fetch km first
            r = subprocess.run(cmd, cwd=self.out, env=self.env, capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, timeout=600)
        except subprocess.TimeoutExpired:
            sys.exit(f"seed: {' '.join(cmd)}: no answer in 600 s")
        if r.returncode != 0:
            sys.exit(f"seed: {' '.join(cmd)} failed ({r.returncode}):\n{r.stdout}{r.stderr}")
        return r.stdout

    def km(self, *args: str) -> str:
        return self.run(*self.km_cmd, *args)

    def commit(self, msg: str) -> None:
        self.n += 1                                       # one minute apart, all on the seed date
        stamp = f"{self.date.isoformat()}T08:{self.n:02d}:00+00:00"
        self.env |= {"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp}
        self.run("git", "add", "-A")
        self.run("git", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", msg)


def build(out: Path, km: list[str], date: datetime.date, mount: tuple[str, str] | None) -> str:
    """Write the seeded brain into the empty folder `out`; returns the head commit."""
    out.mkdir(parents=True, exist_ok=False)
    b = Builder(out, km, date)
    try:
        return _build(b, out, date, mount)
    finally:
        shutil.rmtree(b.env["GH_CONFIG_DIR"], ignore_errors=True)


def _build(b: Builder, out: Path, date: datetime.date, mount: tuple[str, str] | None) -> str:
    b.km("init", str(out), "--team", "--name", "E2E-Brain", "--desc", "the e2e sandbox team",
         "--initials", "AAA", *[f"--folder={n}={p}" for n, p in FOLDERS])
    b.run("git", "init", "-q", "-b", "main")
    b.commit("chore: initialize E2E-Brain (team served knowledge base)")

    write_pages(out, date)
    b.run("git", "add", "-A")
    b.km("gen-index")
    b.commit("docs(seed): add the invented Lumen lamp pages in review")

    b.km("approve", *AI_FIRST, "--by", AI, "--at", date.isoformat())
    b.commit(f"docs(seed): approve the AI-level pages ({AI})")
    for docs, by in HUMAN:
        b.km("approve", *docs, "--by", by, "--at", date.isoformat())
    b.commit("docs(seed): approve the human-level pages (BBB, CCC)")
    b.km("approve", *LAST, "--by", AI, "--at", date.isoformat())
    b.commit(f"docs(seed): approve how-we-work once the pages it links to are accepted ({AI})")

    for rel in LAPSED:
        set_review_by(out / rel, date - datetime.timedelta(days=30))
    set_review_by(out / OLD_DECISION, date - datetime.timedelta(days=400))
    b.commit("docs(seed): let review_by lapse on two pages and age the decision's")

    b.run("git", "add", "-A")
    b.km("repin", *PINNED)
    b.km("approve", SIGNED_AFTER_PIN, "--by", AI, "--at", date.isoformat())
    b.commit(f"docs(seed): pin the sources of the summary and the spec, approve the spec ({AI})")

    if mount:
        url, sha = mount
        (out / ".gitmodules").write_text(f'[submodule "mounted/notes"]\n\tpath = mounted/notes\n'
                                         f"\turl = {url}\n", encoding="utf-8")
        (out / "mounted" / "notes").mkdir(parents=True)   # an empty checkout: `git add -A` keeps the gitlink
        b.run("git", "update-index", "--add", "--cacheinfo", f"160000,{sha},mounted/notes")
        b.commit("chore(mount): mount the notes repository")

    b.run("git", "add", "-A")
    b.km("gen-index", "--check")
    b.km("validate")
    return b.run("git", "rev-parse", "HEAD").strip()


def main() -> int:
    ap = argparse.ArgumentParser(prog="seed.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build", help="write the seeded brain into a new folder")
    p.add_argument("out", type=Path)
    p.add_argument("--km", required=True, help="the command that runs the baseline km, e.g. 'uvx --from ... km'")
    p.add_argument("--date", type=datetime.date.fromisoformat, default=datetime.date.today())
    p.add_argument("--mount", metavar="URL@SHA", help="mount a repository at mounted/notes, pinned at SHA")
    w = sub.add_parser("pages", help="write only the generated files (no km, no git), for review")
    w.add_argument("out", type=Path)
    w.add_argument("--date", type=datetime.date.fromisoformat, default=datetime.date.today())
    a = ap.parse_args()
    if a.cmd == "pages":
        write_pages(a.out, a.date)
        return 0
    mount = tuple(a.mount.rsplit("@", 1)) if a.mount else None
    print(build(a.out, shlex.split(a.km), a.date, mount))
    return 0


if __name__ == "__main__":
    sys.exit(main())
