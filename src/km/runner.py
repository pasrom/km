"""The runner the team workflows run on: the brain's setting `runner: <label>` in schema.local.yaml,
ubuntu-latest (GitHub's runners) where it sets none.

`km init --team` and `km upgrade` write the label into every runs-on line of the team workflows. A
literal label reaches every run, a fork's pull request run of ci too: that run takes the workflow as the pull
request has it (the base branch's, unless the fork changes it, a control file approve-fork-ci leaves to
a person), and GitHub passes it no repository or organisation variables unless it also passes the
secrets, so km 1.22's `${{ vars.KM_RUNNER || 'ubuntu-latest' }}` sent a fork's ci to GitHub's runners.
km reads that variable nowhere now; `km upgrade` rewrites the line in km's ci and staleness workflows
and says to move the variable into the setting, and `km doctor` notes a variable still set.

Each spot the label is written into is km's: a copy rendered with any label is still km's version
(`unrendered` puts the placeholder back before hashing). Runs without PyYAML, as km doctor does.
"""
from __future__ import annotations

import re
from pathlib import Path

from km.paths import overlay

DEFAULT = "ubuntu-latest"
PLACEHOLDER = "<RUNNER>"
LABEL = r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}"   # one runner label: it is written into YAML unquoted
# what YAML may read as no string (a bool, null, number or date), which an unquoted runs-on would turn
# into one: kept conservative, so a label of digits and signs is refused even where YAML reads it as text
_NOT_A_STRING = re.compile(r"(?i)y|yes|n|no|true|false|on|off|null|[0-9][0-9_.e-]*|0[box][0-9a-f_]+")
OLD_EXPR = "${{ vars.KM_RUNNER || 'ubuntu-latest' }}"   # km 1.22's runs-on line
READS_VARIABLE = re.compile(r"(?m)^[ \t]*runs-on:[^#\n]*vars\.KM_RUNNER")
_SETTING = re.compile(r"(?m)^runner:(?![^ \t\n])(.*)$(\n[ \t]+[^\s#])?")   # 2: an indented line under it (a block value)
# The spots km writes the label into, as (before)(label)(after): a runs-on line, and bump-mounted-pins'
# fallback behind MOUNTED_PINS_RUNNER.
_SPOTS = re.compile(rf"(?m)(^[ \t]*runs-on:[ \t]*|vars\.MOUNTED_PINS_RUNNER \|\| ')({LABEL}|{PLACEHOLDER})([ \t]*(?:#.*)?$|' \}}\}})")
_RUNS_ON = re.compile(r"(?m)^([ \t]*runs-on:[ \t]*)(.*?)([ \t]*(?:[ \t]#.*)?)$")   # 2: the value, without a comment


def check(value: str, yaml_load=None) -> str:
    """`value` when it is one runner label, else ValueError. With `yaml_load` (yaml.safe_load, where
    PyYAML is at hand), it must also read as that string."""
    if not re.fullmatch(LABEL, value) or _NOT_A_STRING.fullmatch(value) or yaml_load and yaml_load(value) != value:
        raise ValueError(f"runner {value!r} must be one runner label (letters, digits, '.', '_', '-'), as in `runner: my-runner`")
    return value


def setting(root: Path, yaml_load=None) -> str | None:
    """The label the brain's schema overlay names in its top-level `runner:` line, None where it names
    none, or leaves it empty or null. ValueError for a value that is not one label on that line (a list,
    a quote, an expression). With `yaml_load` (yaml.safe_load, where PyYAML is at hand), the overlay as
    YAML reads it must agree: its top-level `runner` is that label, or absent or null where the line
    names none (a quoted key, `runner : x`, a flow mapping or a BOM the line does not see)."""
    path = overlay(root)
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    try:
        if re.search(r"(?m)^runner:[^ \t\n]", text):
            raise ValueError("runner needs a space after its colon, as in `runner: my-runner`")
        value = _from_line(_SETTING.findall(text), yaml_load)
        if yaml_load and not _agrees(text, value, yaml_load):
            raise ValueError("runner must be written as one line `runner: <label>` at the top level, as km reads it")
    except ValueError as e:
        raise ValueError(f"{path.name}: {e}") from None
    return value


def _from_line(found: list[tuple[str, str]], yaml_load) -> str | None:
    if not found:
        return None
    value = re.sub(r"(^|[ \t])#.*$", "", found[0][0]).strip()
    if len(found) == 1 and not found[0][1] and value in ("", "~", "null", "Null", "NULL"):
        return None
    if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    if len(found) > 1:
        raise ValueError("runner is set more than once")
    return check(value, yaml_load)


def _agrees(text: str, value: str | None, yaml_load) -> bool:
    """Whether YAML reads the same top-level runner as the line does; a file YAML cannot read is left to
    whoever reads it as YAML."""
    try:
        parsed = yaml_load(text)
    except Exception:            # yaml.YAMLError: km validate reports the file
        return True
    return (parsed.get("runner") if isinstance(parsed, dict) else None) == value


def label(root: Path) -> str:
    """The runner the brain's team workflows run on."""
    return setting(root) or DEFAULT


def rendered(text: str, runner: str) -> str:
    """The workflow with every spot km writes the runner into set to `runner`."""
    return _SPOTS.sub(lambda m: m.group(1) + runner + m.group(3), text)


def unrendered(text: str) -> str:
    """The workflow as km's template has it, whatever runner was written into it."""
    return rendered(text, PLACEHOLDER)


def labels(text: str) -> set[str]:
    """The runners written into a workflow's spots."""
    return {m.group(2) for m in _SPOTS.finditer(text)}


def km_form(value: str) -> bool:
    """Whether a runs-on value is one km wrote: a label, the placeholder or km 1.22's expression."""
    return value in (PLACEHOLDER, OLD_EXPR) or bool(re.fullmatch(LABEL, value))


def runs_on(text: str) -> list[str]:
    """The value of every runs-on line, as written."""
    return [m.group(2) for m in _RUNS_ON.finditer(text)]


def with_runs_on(text: str, runner: str) -> str:
    """The workflow with every runs-on line set to `runner`, as text (km.upgrade checks the result)."""
    return _RUNS_ON.sub(lambda m: m.group(1) + runner + m.group(3), text)
