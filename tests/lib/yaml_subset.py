"""Minimal YAML loader for the block subset emit-api-artifacts.sh writes.

PyYAML is not a dependency of this plugin — the extractor and the emitters are
deliberately python3-stdlib only — so the tests need their own reader. This one
parses TEXT and shares no code with the emitter, which is the point: it verifies
what was actually written rather than re-deriving it.

Supported: block mappings, block sequences, 2-space indentation, JSON-quoted
scalars, plain `true`/`false`/`null`/int/float scalars, and the empty `{}` / `[]`
forms. Not supported (and never emitted): anchors, aliases, tags, flow
collections with contents, multi-line/folded scalars, multiple documents.
"""

import json
import re

__all__ = ['load', 'YamlSubsetError']


class YamlSubsetError(ValueError):
    """Raised when the input falls outside the supported subset."""


_KEY_RE = re.compile(r'^(?:"((?:[^"\\]|\\.)*)"|([^:\s"][^:]*?))\s*:(?:\s+(.*))?$')


def _split_key(text):
    """('key', 'rest') for a mapping line, or None when the line is not one."""
    m = _KEY_RE.match(text)
    if not m:
        return None
    key = json.loads('"%s"' % m.group(1)) if m.group(1) is not None else m.group(2)
    return key, (m.group(3) or '').strip()


def _scalar(text):
    text = text.strip()
    if text.startswith('"'):
        try:
            return json.loads(text)
        except ValueError as exc:
            raise YamlSubsetError('bad quoted scalar: %s (%s)' % (text, exc))
    if text == 'true':
        return True
    if text == 'false':
        return False
    if text in ('null', '~', ''):
        return None
    if text == '{}':
        return {}
    if text == '[]':
        return []
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    return text


def _is_seq_line(text):
    return text == '-' or text.startswith('- ')


def _parse_map(lines, pos, indent):
    out = {}
    while pos < len(lines):
        line_indent, text = lines[pos]
        if line_indent != indent or _is_seq_line(text):
            break
        pair = _split_key(text)
        if pair is None:
            raise YamlSubsetError('not a mapping line at %r' % text)
        key, rest = pair
        pos += 1
        if rest:
            out[key] = _scalar(rest)
            continue
        if pos < len(lines) and lines[pos][0] > indent:
            child_indent = lines[pos][0]
            if _is_seq_line(lines[pos][1]):
                out[key], pos = _parse_seq(lines, pos, child_indent)
            else:
                out[key], pos = _parse_map(lines, pos, child_indent)
        else:
            out[key] = None
    return out, pos


def _parse_seq(lines, pos, indent):
    out = []
    while pos < len(lines):
        line_indent, text = lines[pos]
        if line_indent != indent or not _is_seq_line(text):
            break
        content = text[2:].strip() if text.startswith('- ') else ''
        if content and _split_key(content) is not None:
            # A mapping whose first key rides on the dash. Splice a virtual line at
            # the item's own indent so the shared map parser handles the rest.
            spliced = [(indent + 2, content)] + lines[pos + 1:]
            item, consumed = _parse_map(spliced, 0, indent + 2)
            out.append(item)
            pos += consumed
        else:
            out.append(_scalar(content))
            pos += 1
    return out, pos


def load(text):
    """Parse a YAML document from the supported subset into Python data."""
    lines = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith('#') or stripped == '---':
            continue
        lines.append((len(raw) - len(raw.lstrip(' ')), stripped))
    if not lines:
        return None
    base = lines[0][0]
    if _is_seq_line(lines[0][1]):
        value, pos = _parse_seq(lines, 0, base)
    else:
        value, pos = _parse_map(lines, 0, base)
    if pos != len(lines):
        raise YamlSubsetError('unconsumed input at line %d: %r'
                              % (pos + 1, lines[pos][1]))
    return value
