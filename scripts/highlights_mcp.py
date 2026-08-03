#!/usr/bin/env python3
"""
highlights_mcp — MCP server on top of Chat Marker highlights.

Lets Claude search everything you marked up with the marker in the browser: by
topic, by source, by date, by words. And pull together collections that
summaries grow out of.

Before every request the server picks up fresh exports from ~/Downloads on its
own and rebuilds the library in Google Drive if anything changed.

Installed by install.sh. By hand — only if something broke:

    python3 -m venv ~/.chatmarker/venv
    ~/.chatmarker/venv/bin/pip install "mcp[cli]" openpyxl

Claude Desktop config (~/Library/Application Support/Claude/claude_desktop_config.json):
    {
      "mcpServers": {
        "highlights": {
          "command": "/Users/<you>/.chatmarker/venv/bin/python",
          "args": ["/Users/<you>/.chatmarker/highlights_mcp.py"]
        }
      }
    }
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("highlights")

NO_TAG = "no topic"
TAG_RE = re.compile(r"#([^\W\d_][\w-]{1,39})", re.UNICODE)


# ------------------------------------------------------------------ sources

def _drive_roots() -> list[Path]:
    home = Path.home()
    out: list[Path] = []
    cloud = home / "Library" / "CloudStorage"
    if cloud.is_dir():
        for d in sorted(cloud.glob("GoogleDrive-*")):
            for inner in ("My Drive",):
                if (d / inner).is_dir():
                    out.append(d / inner / "AI Highlights")
    for legacy in (home / "Google Drive" / "My Drive", home / "Google Drive"):
        if legacy.is_dir():
            out.append(legacy / "AI Highlights")
    return out


def _sources() -> list[Path]:
    """Every place highlights can live. Overridden by HIGHLIGHTS_PATH."""
    env = os.environ.get("HIGHLIGHTS_PATH", "").strip()
    if env:
        return [Path(p).expanduser() for p in env.split(":") if p.strip()]
    out = [r / "00 Inbox" for r in _drive_roots()]
    out.append(Path.home() / "Downloads")
    return out


DEFAULT_PATH = ", ".join(str(p) for p in _sources())


def _files() -> list[Path]:
    found: list[Path] = []
    for p in _sources():
        try:
            if p.is_dir():
                for pat in ("highlights*.json", "desktop*.json"):
                    found += list(p.glob(pat))
            elif p.exists() and p.suffix == ".json":
                found.append(p)
        except OSError:
            continue
    uniq = {f.resolve(): f for f in found}

    def mtime(f: Path) -> float:
        try:
            return f.stat().st_mtime
        except OSError:      # file was taken away while we looked — no reason to crash
            return 0.0

    return sorted((f for f in uniq.values() if mtime(f)), key=mtime, reverse=True)


_CACHE: dict[str, Any] = {"sig": None, "items": []}


def _load_raw() -> list[dict[str, Any]]:
    """Read with an mtime cache: on a big library a full JSON reparse on every
    tool call takes seconds, and the files rarely change."""
    files = _files()
    try:
        sig = tuple((str(f), f.stat().st_mtime_ns, f.stat().st_size) for f in files)
    except OSError:
        sig = None
    if sig is not None and sig == _CACHE["sig"]:
        return _CACHE["items"]

    items = _read_files(files)
    if sig is not None:
        _CACHE["sig"] = sig
        _CACHE["items"] = items
    return items


def _read_files(files) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        for h in (data if isinstance(data, list) else data.get("highlights", [])):
            hid = h.get("id")
            if not hid or hid in seen:
                continue
            seen.add(hid)
            out.append(h)
    out.sort(key=lambda h: h.get("createdAt", ""), reverse=True)
    return out


def _doc_topics() -> set[str]:
    """Topics that have a live document going: the flag is set in the browser."""
    docs: set[str] = set()
    decided: set[str] = set()
    for f in _files():
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        for t in (data.get("tags", []) if isinstance(data, dict) else []):
            name = str(t.get("name") or "").strip().lower()
            if not name or name in decided:
                continue
            decided.add(name)
            if t.get("doc"):
                docs.add(name)
    return docs


# --------------------------------------------------------------- auto-build

_LAST_SYNC = {"at": 0.0}
_COOLDOWN = 3.0


def _sync(force: bool = False) -> dict | None:
    now = time.monotonic()
    if not force and now - _LAST_SYNC["at"] < _COOLDOWN:
        return None
    _LAST_SYNC["at"] = now
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import library  # import deferred on purpose
        return library.run(do_ingest=True, force=force, quiet=True)
    except SystemExit:
        return None   # Google Drive isn't ready yet
    except Exception:
        return None   # the build isn't critical, search works anyway


# ------------------------------------------------------------------ parsing

SPA_HOSTS = re.compile(r"(^|\.)(claude\.ai|chatgpt\.com|chat\.openai\.com|gemini\.google\.com|aistudio\.google\.com)$", re.I)


def fragment_url(h: dict) -> str:
    """A link that opens the source and scrolls to exactly this spot.

    The browser's stock text fragments: page#:~:text=chunk
    We don't add context — the start and the end are enough, and the way
    neighbouring blocks get merged in the index makes prefix/suffix unreliable.
    """
    raw = h.get("url") or ""
    url = raw.split("#")[0]
    if not url:
        return ""
    try:
        from urllib.parse import urlparse, quote
        parsed = urlparse(raw)
        if parsed.scheme == "file":
            return raw         # desktop highlight: file://…#page=N from the viewer
        if parsed.scheme not in ("http", "https"):
            return ""          # javascript: and the rest from untrusted exports
        if SPA_HOSTS.search(parsed.hostname or ""):
            return url
    except Exception:
        return ""

    ex = re.sub(r"\s+", " ", (h.get("anchor") or {}).get("exact") or h.get("text") or "").strip()
    if not ex:
        return url

    enc = lambda t: quote(t, safe="").replace("-", "%2D")
    if len(ex) > 70:
        head = re.sub(r"\s\S*$", "", ex[:40])
        tail = re.sub(r"^\S*\s", "", ex[-40:])
        directive = f"{enc(head)},{enc(tail)}"
    else:
        directive = enc(ex)
    return f"{url}#:~:text={directive}"


def _tags(h: dict[str, Any]) -> list[str]:
    """Topics of a highlight. New format — the tag field, old — hashtags in the note."""
    raw = h.get("tag")
    if isinstance(raw, str) and raw.strip():
        return [raw.strip().lower()]
    slug = h.get("slug")
    if isinstance(slug, str) and slug.strip():
        return [slug.strip().lower()]
    many = h.get("tags")
    if isinstance(many, list) and many:
        return [str(t).strip().lower() for t in many if str(t).strip()]
    return sorted({m.group(1).lower() for m in TAG_RE.finditer(h.get("note") or "")})


def _local(iso: str) -> str:
    """Highlight time in the local zone — createdAt is stored in UTC."""
    try:
        dt = datetime.fromisoformat((iso or "").replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")
    except Exception:
        return (iso or "")[:16].replace("T", " ")


# ---------------------------------------------------------- highlight color
#
# You pick the color with a hotkey, so you should be able to ask "show me
# everything red". The browser writes hex, the desktop writes a word; we boil
# both down to a hue name and let you filter by it.

_COLOR_WORDS = {
    "red": "red", "crimson": "red",
    "pink": "pink",
    "orange": "orange",
    "yellow": "yellow",
    "green": "green",
    "teal": "teal", "cyan": "teal", "turquoise": "teal",
    "blue": "blue",
    "purple": "purple", "violet": "purple",
    "brown": "brown",
    "gray": "gray", "grey": "gray",
}

_COLOR_EN = {
    "red": "red", "pink": "pink", "orange": "orange", "yellow": "yellow",
    "green": "green", "teal": "teal", "blue": "blue", "purple": "purple",
    "brown": "brown", "gray": "gray",
}


def _hue_name(color: str) -> str:
    """Hue name for a hex color or a named color from a desktop capture."""
    c = str(color or "").strip().lower()
    if c in ("yellow", "green", "blue", "red"):
        return c
    m = re.fullmatch(r"#([0-9a-f]{6})", c)
    if not m:
        return ""
    r, g, b = (int(m.group(1)[i:i + 2], 16) / 255 for i in (0, 2, 4))
    mx, mn = max(r, g, b), min(r, g, b)
    light = (mx + mn) / 2
    if mx == mn:
        return "gray"
    d = mx - mn
    sat = d / (2 - mx - mn) if light > 0.5 else d / (mx + mn)
    if sat < 0.15:
        return "gray"
    if mx == r:
        h = ((g - b) / d) % 6
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    h *= 60
    if h < 15 or h >= 345:
        return "red"
    if h < 45:
        return "brown" if sat < 0.4 else "orange"
    if h < 70:
        return "yellow"
    if h < 160:
        return "green"
    if h < 200:
        return "teal"
    if h < 255:
        return "blue"
    if h < 300:
        return "purple"
    return "pink"


def _fmt(h: dict[str, Any], index: int | None = None) -> str:
    head = f"[{index}] " if index is not None else ""
    tags = _tags(h)
    label = " ".join("#" + t for t in tags) if tags else NO_TAG
    hue = _hue_name(h.get("color") or "")
    if hue and hue != "gray":
        label += ", " + _COLOR_EN.get(hue, hue)
    when = (h.get("createdAt") or "")[:10]
    lines = [
        f"{head}({label}, {when}) source: {h.get('title') or h.get('conv')}",
        "> " + (h.get("text", "") or "").strip().replace("\n", "\n> "),
    ]
    if h.get("note"):
        lines.append(f"note: {h['note']}")
    fu = fragment_url(h)
    if fu:
        lines.append(f"jump to: {fu}")
    return "\n".join(lines)


# -------------------------------------------------------------------- tools

@mcp.tool()
def search_highlights(
    query: str = "",
    tag: str = "",
    color: str = "",
    source: str = "",
    site: str = "",
    since: str = "",
    untagged: bool = False,
    limit: int = 25,
) -> str:
    """Find saved highlights — from AI chats, articles, any page.

    query    — words to look for in the highlight text and the note (case doesn't matter);
    tag      — topic without the hash, for example "hiring";
    color    — highlight color: "red", "green", "yellow", "blue"…
               (a color name, or a hex like #ef9a9a);
    source   — part of the page or chat title;
    site     — domain, for example "stratechery.com";
    since    — YYYY-MM-DD date, return only newer ones;
    untagged — only the ones saved without a topic;
    limit    — how many to return at most.
    """
    _sync()
    items = _load_raw()

    if tag:
        t = tag.lstrip("#").lower()
        items = [h for h in items if t in _tags(h)]
    if color:
        want = color.strip().lower()
        if want.startswith("#"):
            items = [h for h in items if str(h.get("color") or "").lower() == want]
        else:
            canon = _COLOR_WORDS.get(want, "")
            if not canon:
                known = ", ".join(sorted({_COLOR_EN[v] for v in _COLOR_WORDS.values()}))
                return f"Didn't recognize the color \"{color}\". I know: {known} — or a hex like #ef9a9a."
            items = [h for h in items if _hue_name(h.get("color") or "") == canon]
    if untagged:
        items = [h for h in items if not _tags(h)]
    if source:
        s = source.lower()
        items = [h for h in items if s in (h.get("title") or "").lower()]
    if site:
        d = site.lower()
        items = [h for h in items
                 if d in (h.get("host") or "").lower() or d in (h.get("url") or "").lower()]
    if since:
        items = [h for h in items if (h.get("createdAt") or "") >= since]
    if query:
        words = [w for w in re.split(r"\s+", query.lower()) if w]

        def hit(h: dict[str, Any]) -> bool:
            blob = ((h.get("text") or "") + " " + (h.get("note") or "")).lower()
            return all(w in blob for w in words)

        items = [h for h in items if hit(h)]

    if not items:
        return ("Nothing found. The highlights may not be exported from the browser yet — "
                f"hit \"Export to library\" in the side panel. Looking in: {DEFAULT_PATH}")

    shown = items[: max(1, limit)]
    header = f"Found {len(items)}, showing {len(shown)}:\n"
    return header + "\n\n".join(_fmt(h, i + 1) for i, h in enumerate(shown))


@mcp.tool()
def list_topics() -> str:
    """Show the topics and how many highlights are in each."""
    _sync()
    items = _load_raw()
    counts: dict[str, int] = {}
    untagged = 0
    for h in items:
        tg = _tags(h)
        if not tg:
            untagged += 1
        for t in tg:
            counts[t] = counts.get(t, 0) + 1
    if not counts and not untagged:
        return "No highlights yet."
    if not counts:
        return f"No topics yet, no topic: {untagged}. A topic is created in the browser when you highlight."
    rows = sorted(counts.items(), key=lambda kv: -kv[1])
    docs = _doc_topics()
    body = "\n".join(f"{n:>3}  #{t}" + ("   📄 live document" if t in docs else "") for t, n in rows)
    return body + f"\n\nNo topic: {untagged}" + (
        "\n📄 — a .docx is built for the topic in the \"06 Documents\" folder in Google Drive." if docs else "")


@mcp.tool()
def list_sources() -> str:
    """Show where the highlights came from: pages, articles, chats."""
    _sync()
    items = _load_raw()
    if not items:
        return "No highlights yet."
    counts: dict[str, int] = {}
    latest: dict[str, str] = {}
    hosts: dict[str, int] = {}
    for h in items:
        key = h.get("title") or h.get("conv") or "?"
        counts[key] = counts.get(key, 0) + 1
        latest[key] = max(latest.get(key, ""), h.get("createdAt") or "")
        host = h.get("host") or ""
        if host:
            hosts[host] = hosts.get(host, 0) + 1
    rows = sorted(counts.items(), key=lambda kv: latest[kv[0]], reverse=True)
    body = "\n".join(f"{n:>3}  {title}  (latest {latest[title][:10]})" for title, n in rows[:40])
    if hosts:
        top = ", ".join(f"{h} — {n}" for h, n in sorted(hosts.items(), key=lambda kv: -kv[1])[:10])
        body += f"\n\nBy site: {top}"
    return body


@mcp.tool()
def refresh_library() -> str:
    """Force-pull the fresh exports out of Downloads and rebuild the library
    in Google Drive: topics, sources, index, spreadsheet and dashboard."""
    r = _sync(force=True)
    if r is None:
        return ("Couldn't rebuild. Most likely Google Drive isn't ready yet — "
                "check that the app is running and the \"AI Highlights\" folder shows up in Finder.")
    parts = []
    if r["moved"]:
        parts.append(f"exports taken in: {r['moved']}")
    if r["rebuilt"]:
        parts.append(f"built {r['items']} highlights, {r['topics']} topics, {r['sources']} sources")
        if r.get("untagged"):
            parts.append(f"no topic: {r['untagged']}")
        if not r["xlsx"]:
            parts.append("didn't build the spreadsheet — no openpyxl")
    elif r.get("skipped"):
        parts.append("nothing changed since last time")
    else:
        parts.append("no highlights yet")
    return "; ".join(parts) + f"\nFolder: {r['root']}"


@mcp.tool()
def get_topic_map(topic: str = "", limit: int = 60) -> str:
    """Show a topic's highlights in the order they were marked — with the date,
    the position in the document and the notes. That's a ready-made train of
    thought, easy to build a summary out of.

    topic — topic without the hash; empty — all highlights in a row.
    """
    _sync()
    items = _load_raw()
    if topic:
        t = topic.lstrip("#").lower()
        items = [h for h in items if t in _tags(h)]
    items = sorted(items, key=lambda h: h.get("createdAt") or "")
    total = len(items)
    if not items:
        return f"No highlights for topic \"{topic}\"."
    shown = items[-max(1, limit):]        # tail: recent ones matter more for a summary

    head = f"Topic \"{topic or 'all'}\", {total} in total"
    if len(shown) < total:
        head += (f". Showing the last {len(shown)} by time — the start of the topic isn't shown, "
                 f"for the full picture call again with limit={total}.")
    else:
        head += ", all in the order they were marked:"
    lines = [head, ""]
    items = shown
    prev = None
    for i, h in enumerate(items, 1):
        when = _local(h.get("createdAt") or "")
        try:
            cur = datetime.fromisoformat((h.get("createdAt") or "").replace("Z", "+00:00"))
            if prev and (cur - prev).total_seconds() > 30 * 60:
                lines.append(f"    — break, new session {when} —")
            prev = cur
        except Exception:
            pass
        pos = h.get("pos")
        where = f", {int(pos * 100)}% into the document" if isinstance(pos, (int, float)) else ""
        lines.append(f"[{i}] {when} · {h.get('title') or ''}{where}")
        lines.append("    " + (h.get("text") or "").strip().replace("\n", " ")[:400])
        if h.get("note"):
            lines.append(f"    note: {h['note']}")
        fu = fragment_url(h)
        if fu:
            lines.append(f"    jump to: {fu}")
    return "\n".join(lines)


@mcp.tool()
def stats() -> str:
    """Overview: how many highlights there are in total, how they spread across topics, sites and time."""
    _sync()
    items = _load_raw()
    if not items:
        return f"Empty. Looking in: {DEFAULT_PATH}"

    by_tag: dict[str, int] = {}
    by_month: dict[str, int] = {}
    by_host: dict[str, int] = {}
    with_note = untagged = 0
    for h in items:
        tg = _tags(h)
        if not tg:
            untagged += 1
        for t in tg:
            by_tag[t] = by_tag.get(t, 0) + 1
        month = (h.get("createdAt") or "")[:7]
        by_month[month] = by_month.get(month, 0) + 1
        host = h.get("host") or ""
        if host:
            by_host[host] = by_host.get(host, 0) + 1
        if h.get("note"):
            with_note += 1

    parts = [
        f"Highlights in total: {len(items)} (with notes: {with_note}, no topic: {untagged})",
        "By topic: " + (", ".join(f"#{k} — {v}" for k, v in sorted(by_tag.items(), key=lambda kv: -kv[1])[:15]) or "no topics"),
    ]
    if by_host:
        parts.append("By site: " + ", ".join(f"{k} — {v}" for k, v in sorted(by_host.items(), key=lambda kv: -kv[1])[:10]))
    parts.append("By month: " + ", ".join(f"{k} — {v}" for k, v in sorted(by_month.items(), reverse=True)[:12]))
    parts.append("Source files: " + (", ".join(str(f) for f in _files()[:6]) or "none"))
    return "\n".join(parts)


@mcp.tool()
def build_digest(topic: str, limit: int = 40) -> str:
    """Collect a topic's highlights into one markdown block, ready to be worked
    up into a summary, a draft or a note.

    topic — a topic, or just words; limit — how many to take at most.
    """
    _sync()
    items = _load_raw()
    t = topic.lstrip("#").lower().strip()

    exact = [h for h in items if t in _tags(h)]
    if exact:
        picked = exact
    else:
        words = [w for w in re.split(r"\s+", t) if w]
        picked = [
            h for h in items
            if all(w in ((h.get("text") or "") + " " + (h.get("note") or "") + " " +
                         (h.get("title") or "")).lower() for w in words)
        ] if words else items

    total = len(picked)
    picked = picked[: max(1, limit)]
    if not picked:
        return f"Found no highlights for topic \"{topic}\"."

    by_src: dict[str, list[dict[str, Any]]] = {}
    for h in picked:
        by_src.setdefault(h.get("title") or h.get("conv") or "?", []).append(h)

    tail = (f"took the {len(picked)} most recent out of {total} — for the full set use limit={total}"
            if len(picked) < total else f"{total} in total")
    out = [f"# Highlights on topic: {topic}",
           f"_built {datetime.now():%Y-%m-%d}, {tail}_", ""]
    for src, hs in by_src.items():
        out.append(f"## {src}")
        url = next((h.get("url") for h in hs if h.get("url")), "")
        if url:
            out.append(f"[{url}]({url})\n")
        for h in hs:
            out.append("> " + (h.get("text") or "").strip().replace("\n", "\n> "))
            if h.get("note"):
                out.append(f"\n**Note:** {h['note']}")
            tg = _tags(h)
            out.append(f"\n`{' '.join('#' + x for x in tg) if tg else NO_TAG}`\n")
        out.append("")
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run()
