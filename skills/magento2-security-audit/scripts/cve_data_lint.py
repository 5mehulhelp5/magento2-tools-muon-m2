#!/usr/bin/env python3
"""Shared CVE-data validation.

Both tests/test-cve-data-schema.sh (lints the shipped magento-cve-data.yaml) and
refresh-cve-data.py (gates its own generated output before writing it) call
validate_text() here — the ONE implementation of the data-file schema contract, so
the two can never drift apart.

This lint used to regex the YAML as TEXT. cve-scan.sh's ACTUAL loader is much
stricter — parse_record hard-codes exact indents (keys at 2, list items at 4, object
continuation at 6) and load_cve_data_yaml splits entries only on a literal `- cve:`
line. Every place the regex lint was looser than that gave a curator green CI and a
silently blind scanner (measured: sibling-indented `affected:`, `cve` not an entry's
first key, flow-style `affected: [...]`, and a bare-string `magento_version_range` all
linted clean while producing ZERO runtime findings). So: don't reimplement the
parser here — a hand-copied second implementation would just drift from the real one,
which is the exact bug being fixed. Import `cve_parser`, the ONE parser the scanner
itself uses, so this lint checks exactly what the scanner will do with this file.
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cve_parser  # noqa: E402

# The ONLY editions an advisory may declare. An ABSENT edition is legal and means
# "affects both" — it already matches every store.
KNOWN_EDITIONS = ('open-source', 'commerce')
# `component` lives on the affected RANGE, a sibling key to `edition`. ABSENT means
# core — the vast majority of entries. The only defined non-core value is 'b2b'.
KNOWN_COMPONENTS = ('b2b',)
# Only the fields magento-cve-database.md marks EXPLICITLY "Required". `severity`,
# `description` and `fixed_in` are left unmarked by that doc, so they are NOT enforced
# here — under-enforcing is recoverable; rejecting a valid curated entry because this
# lint guessed would be a self-inflicted wound. Resolve the doc's ambiguity, then tighten.
REQUIRED_SCALAR = ('cve', 'bulletin_url', 'recorded_at')
# A `fixed_in` token that names a version a store can actually BE on, as opposed to a
# pre-release tag ('2.4.9-alpha1') or an isolated-patch label ('2.4.9-2026-jul'). Kept
# byte-identical to cve-scan.sh's _REAL_VERSION_TOKEN, which gates the same distinction
# when wording a recommendation.
_REAL_VERSION_TOKEN = re.compile(r'^\d+\.\d+\.\d+(-p\d+)?$')


def _apparent_entry_count(text):
    """Best-effort GROUND TRUTH for "how many entries does this file appear to
    define under `entries:`?" — independent of whether load_cve_data_yaml's
    `- cve:`-anchored splitter actually recognizes each one.

    load_cve_data_yaml only starts a new record on a literal `- cve:` line. A legal
    entry whose first key is something else (e.g. `- bulletin_url: ...` with `cve:`
    two lines later) is therefore never recognized as a record at all — not merged
    into any other record, not counted, just gone. That is the sharpest possible
    silent drop and a naive per-record field check can never see it, because there is
    no record to check.

    We estimate the entries' shared indentation from the FIRST list-item line inside
    `entries:`, then count sibling list items at exactly that column — mirroring how
    a real YAML parser treats a block sequence (siblings share one indentation level).
    This deliberately does NOT count nested list items (e.g. under `affected:`),
    which sit at a different indent than the entries themselves in every layout this
    lint has seen, including the buggy ones.
    """
    in_entries = False
    entry_indent = None
    count = 0
    for line in text.splitlines():
        if re.match(r'^entries:', line):
            in_entries = True
            continue
        if not in_entries:
            continue
        m = re.match(r'^(\s*)-\s', line)
        if not m:
            continue
        indent = len(m.group(1))
        if entry_indent is None:
            entry_indent = indent
        if indent == entry_indent:
            count += 1
    return count


def validate_text(text):
    """Validate CVE-data YAML text against the real parser + schema. Returns problems
    ([] = ok).

    Writes `text` to a temp file, loads it via `cve_parser`'s load_cve_data_yaml /
    parse_record — the scanner's real parser, imported rather than reimplemented, so this
    lint can never drift from what the scanner actually does — and applies every rule the
    lint enforces today:
      - required fields cve/bulletin_url/recorded_at present; affected non-empty;
      - edition in {open-source, commerce} or absent;
      - every magento_version_range parses AND matches some version via version_in_range
        (catches an un-normalised bare range or an impossible range);
      - fixed_by_patch: non-empty list of dicts each with id;
      - detect: single-object list with file + both signatures; each signature re.compiles,
        does NOT match the empty string, and is not single-quoted.
    """
    load_cve_data_yaml = cve_parser.load_cve_data_yaml
    parse_record = cve_parser.parse_record
    version_in_range = cve_parser.version_in_range

    errors = []

    fd, tmp_path = tempfile.mkstemp(suffix='.yaml')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(text)

        m = re.search(r'^status:\s*(\S+)', text, re.M)
        status = m.group(1) if m else None
        if status not in ('live', 'illustrative'):
            errors.append(f"status: {status!r} (expected 'live' or 'illustrative')")

        # --- Ground truth: did the real parser drop any entries? -----------------------
        _, records = load_cve_data_yaml(tmp_path)
        apparent = _apparent_entry_count(text)
        if apparent != len(records):
            errors.append(
                f"the file appears to define {apparent} entr{'y' if apparent == 1 else 'ies'} "
                f"under `entries:`, but cve-scan.sh's parser recognized only {len(records)} — "
                f"entries are being SILENTLY DROPPED (a common cause: an entry whose first key "
                f"is not `cve`). Every dropped entry is an advisory that will never fire.")

        # --- Per-record checks, run through the REAL parser -----------------------------
        for raw in records:
            try:
                rec = parse_record(raw)
            except cve_parser.CveRecordError as e:
                hint = re.search(r'^- cve:\s*(\S+)', raw, re.M)
                where = hint.group(1) if hint else '<unknown-cve>'
                errors.append(f"{where}: unparseable record — {e}")
                continue
            cve = rec.get('cve') or '<unknown-cve>'

            for field in REQUIRED_SCALAR:
                if not rec.get(field):
                    errors.append(f"{cve}: missing required field {field!r}")

            affected = rec.get('affected')
            if not isinstance(affected, list) or not affected:
                errors.append(
                    f"{cve}: 'affected' must be a non-empty list of version-range objects "
                    f"(parse_record produced {affected!r}) — check for flow-style "
                    f"`affected: [...]`, or a nested list indented to the same column as its "
                    f"`affected:` key instead of 4 spaces deeper; either reads as empty/opaque "
                    f"to the real parser and this advisory will never match anything")
                continue

            for aff in affected:
                if not isinstance(aff, dict):
                    errors.append(f"{cve}: an 'affected' entry is not a mapping (got {aff!r})")
                    continue
                rng = aff.get('magento_version_range', '')
                # Probe version_in_range with the range's OWN declared lower bound: if the
                # range is well-formed, its lower bound must be inside itself. This reuses the
                # real matcher as the source of truth instead of re-deriving lo/hi ourselves.
                probe = rng.split(' - ', 1)[0].strip() if rng else ''
                if not version_in_range(probe, rng):
                    errors.append(
                        f"{cve}: magento_version_range {rng!r} is not a usable 'A - B' range — "
                        f"the scanner's version_in_range() can never match it against any "
                        f"version, so this advisory is dead on arrival")
                # An upper bound that omits `-pN` means the BASE release only (see
                # version_in_range). That is unambiguous when the bounds are EQUAL
                # ("2.4.8 - 2.4.8" = only 2.4.8) but ambiguous when they differ:
                # "2.4.4 - 2.4.7" reads as "through 2.4.7" to a human while the matcher
                # stops at 2.4.7 exactly, silently excluding 2.4.7-p1.. — a false
                # NEGATIVE, the failure direction that lets a vulnerable store look clean.
                # No such range exists today; rejecting the shape keeps it that way, so the
                # inf-upper-bound fix cannot be quietly undone by a future curator writing
                # the ambiguous form. Spell the intended patch level out.
                lo_s, sep, hi_s = rng.partition(' - ')
                if sep and lo_s.strip() != hi_s.strip() and '-p' not in hi_s:
                    errors.append(
                        f"{cve}: magento_version_range {rng!r} has differing bounds and an "
                        f"upper bound with no '-pN' — the matcher reads {hi_s.strip()!r} as "
                        f"the BASE release and excludes every {hi_s.strip()}-pN, which is "
                        f"probably not what you meant. Write the highest affected patch "
                        f"level explicitly (e.g. '{hi_s.strip()}-p5'), or set both bounds "
                        f"equal if only the base release is affected.")
                ed = aff.get('edition')
                if ed and ed not in KNOWN_EDITIONS:
                    errors.append(
                        f"{cve}: edition {ed!r} is not a recognized advisory edition; it will "
                        f"match EVERY store as a low-confidence `candidate` and warn at scan "
                        f"time. Use 'open-source' or 'commerce', or omit the field entirely if "
                        f"the advisory affects both.")
                comp = aff.get('component')
                if comp is not None and comp not in KNOWN_COMPONENTS:
                    errors.append(
                        f"{cve}: component {comp!r} is not recognized; the only defined value "
                        f"is 'b2b'. Omit it for a core advisory.")
                # A non-core (major != 2) range MUST be tagged component:b2b, else the matcher
                # ranges it against the core magento_version and it silently matches nothing.
                mmaj = re.match(r'\s*(\d+)\.', probe or rng)
                if mmaj and mmaj.group(1) != '2' and comp != 'b2b':
                    errors.append(
                        f"{cve}: magento_version_range {rng!r} is not a 2.x core range but is "
                        f"not tagged `component: b2b` — the scanner would range it against the "
                        f"core version and it would never match. Tag it, or it is a curation error.")
                # Mirror of the check above: a component:b2b range MUST NOT be a 2.x core
                # range, else the matcher ranges it against b2b_version (a 1.x value) and
                # it silently never matches on a core store — a silent false negative.
                if comp == 'b2b' and mmaj and mmaj.group(1) == '2':
                    errors.append(
                        f"{cve}: magento_version_range {rng!r} is tagged `component: b2b` but "
                        f"looks like a 2.x core range — the scanner would range it against "
                        f"b2b_version (a 1.x value) and it would never match. Untag it, or it "
                        f"is a curation error.")

            # --- fixed_in must fall OUTSIDE every affected range ----------------------------
            # A version listed as the fix cannot also be a version that is vulnerable. When it
            # is, the scanner reports a store sitting on the declared-fixed version — and for
            # an ordinary version-fixed advisory it does so at confidence `confirmed`, i.e.
            # asserted as fact. This is the check that would have caught the inf-upper-bound
            # bug (2.4.8-p1 reported vulnerable to five advisories whose own fixed_in named
            # 2.4.8-p1) at curation time instead of in a customer's audit report.
            #
            # Only REAL version tokens are cross-checked. `fixed_in` legitimately also carries
            # pre-release tags ('2.4.9-alpha1') and isolated-patch LABELS ('2.4.9-2026-jul',
            # the APSB26-73 shape) — a label is a ZIP filename, not a version you can be on,
            # and parse_version happens to read '2.4.9-2026-jul' as (2,4,9,0), so comparing it
            # would flag every patch-fixed advisory as contradictory. Mirrors the
            # _REAL_VERSION_TOKEN gate cve-scan.sh already applies for the same reason.
            for fx in (rec.get('fixed_in') or []):
                if not isinstance(fx, str) or not _REAL_VERSION_TOKEN.match(fx.strip()):
                    continue
                for aff in affected:
                    if not isinstance(aff, dict):
                        continue
                    rng = aff.get('magento_version_range', '')
                    if version_in_range(fx.strip(), rng):
                        errors.append(
                            f"{cve}: fixed_in {fx!r} still falls inside its own affected range "
                            f"{rng!r} — a store on the version that FIXES this advisory would "
                            f"be reported as vulnerable to it. Narrow the range (an upper "
                            f"bound of '2.4.8' means the base release only and already "
                            f"excludes 2.4.8-p1), or correct fixed_in.")

            comps = {aff.get('component') for aff in affected if isinstance(aff, dict)}
            if len(comps) > 1:
                errors.append(
                    f"{cve}: affected ranges mix components {sorted(str(c) for c in comps)} — a "
                    f"record's ranges must all be core or all `component: b2b`, so the matcher "
                    f"has one version space per record.")

            # --- fixed_by_patch (optional): non-empty list of patch objects, each with an id ---
            has_fixed_by_patch = 'fixed_by_patch' in rec
            fixed_by_patch = rec.get('fixed_by_patch')
            if has_fixed_by_patch:
                if (not isinstance(fixed_by_patch, list) or not fixed_by_patch
                        or not all(isinstance(p, dict) for p in fixed_by_patch)):
                    errors.append(
                        f"{cve}: 'fixed_by_patch' must be a non-empty list of patch objects "
                        f"(parse_record produced {fixed_by_patch!r}) — check for a nested "
                        f"mapping or flow-style list instead of `- id: ...` items indented 4 "
                        f"spaces deeper than the `fixed_by_patch:` key")
                else:
                    for p in fixed_by_patch:
                        if not p.get('id'):
                            errors.append(
                                f"{cve}: a 'fixed_by_patch' entry is missing required 'id' "
                                f"(got {p!r})")

            # --- detect (optional): non-empty LIST whose first element is a dict carrying ----
            # file / patched_signature / vulnerable_signature. parse_record has NO concept of a
            # nested mapping: `detect:` written the obvious way (`detect:\n    file: ...`) parses
            # to an empty list SILENTLY, which would disable detection for that CVE and leave a
            # confident false positive in its place. Checking truthiness (not just membership)
            # is exactly what catches that — `[]` is present in `rec` but falsy.
            has_detect = 'detect' in rec
            detect = rec.get('detect')
            if has_detect:
                if (not isinstance(detect, list) or not detect
                        or not isinstance(detect[0], dict)):
                    errors.append(
                        f"{cve}: 'detect' must be a non-empty list whose first element is a "
                        f"mapping (parse_record produced {detect!r}) — this is almost always a "
                        f"`detect:` block written as a nested MAPPING (`detect:\\n    file: "
                        f"...`) instead of a LIST OF OBJECTS (`detect:\\n    - file: ...`); "
                        f"parse_record has no concept of a nested mapping, so the former "
                        f"parses to an empty list SILENTLY and detection is dead for this CVE")
                elif len(detect) > 1:
                    errors.append(
                        f"{cve}: 'detect' has {len(detect)} entries, but patch_state() reads "
                        f"only detect[0] — unconditionally, always — and never looks at "
                        f"detect[1:]. Every entry past the first is silently ignored forever. "
                        f"This is NOT the same shape as 'fixed_by_patch', which legitimately "
                        f"supports multiple entries (the scanner joins all their ids); 'detect' "
                        f"supports exactly ONE marker pair. This is a curation error, not a "
                        f"supported multi-file detection form — collapse this to a single "
                        f"{{file, patched_signature, vulnerable_signature}} entry, or if the "
                        f"advisory truly needs multi-file detection, that requires a scanner "
                        f"change first (see patch_state() in cve-scan.sh), not more list items "
                        f"here.")
                else:
                    d = detect[0]
                    for field in ('file', 'patched_signature', 'vulnerable_signature'):
                        if not d.get(field):
                            errors.append(
                                f"{cve}: 'detect' entry is missing required {field!r}")
                    for label in ('patched_signature', 'vulnerable_signature'):
                        sig = d.get(label)
                        if not sig:
                            continue
                        if sig.startswith("'") and sig.endswith("'"):
                            errors.append(
                                f"{cve}: detect {label} {sig!r} starts and ends with a single "
                                f"quote — parse_record's continuation-key parsing does "
                                f".strip('\"') (DOUBLE quotes only), so a single-quoted value "
                                f"keeps its quotes embedded in the pattern and will silently "
                                f"never match")
                            continue
                        try:
                            compiled = re.compile(sig)
                        except re.error as e:
                            errors.append(
                                f"{cve}: detect {label} {sig!r} does not compile as a regex "
                                f"({e}) — a bad curated regex must fail CI, not silently "
                                f"become PATCH_UNKNOWN for every store forever")
                            continue
                        if compiled.match('') is not None:
                            errors.append(
                                f"{cve}: detect {label} {sig!r} matches the empty string, so "
                                f"it would match every file and suppress all findings — it "
                                f"must require specific text")
                if not has_fixed_by_patch:
                    errors.append(
                        f"{cve}: 'detect' present without 'fixed_by_patch' — a detection "
                        f"marker only means something for an advisory whose fix ships as a "
                        f"patch; on an ordinary version-fixed advisory the scanner ignores "
                        f"'detect' entirely, so a curator's marker would silently do nothing")
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    return errors


def main():
    """CLI entry point: `python3 cve_data_lint.py <path>` — validate a CVE-data YAML
    file and print any problems, exiting non-zero if there are any."""
    if len(sys.argv) != 2:
        print("usage: cve_data_lint.py <path-to-cve-data.yaml>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    text = open(path, encoding='utf-8').read()
    problems = validate_text(text)
    if problems:
        print(f"INVALID {path}")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
