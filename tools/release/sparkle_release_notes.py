#!/usr/bin/env python3
"""Generate Sparkle + GitHub release notes from docs/CHANGELOG.md.

The HTML output is embedded into the Sparkle appcast <description> and rendered
in the in-app update dialog (WebKit), so it carries an inline <style> block with
Apple system typography, a dark-mode media query, and real inline-markdown
rendering (**bold**, `code`, [links]). The plaintext output feeds the GitHub
release, where Markdown renders natively.
"""
import argparse
import html
import os
import re
from typing import Dict, List, Optional

STAR_CTA_URL = "https://github.com/jazzyalex/stargazer-bar"

_BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
_CODE_RE = re.compile(r"`([^`]+)`")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Heading order + display labels. "Highlights" leads and is tinted blue; the rest
# render as muted uppercase section labels. Aliases map CHANGELOG headings we
# accept onto a single canonical bucket.
_HEADING_ORDER = ["Highlights", "Features", "Improvements", "Fixes", "Changes"]
_HEADING_ALIASES = {"Bug Fixes": "Fixes", "Bugfixes": "Fixes"}


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def write_text(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def changelog_sections(markdown: str) -> Dict[str, str]:
    sections: Dict[str, List[str]] = {}
    current: Optional[str] = None
    header = re.compile(r"^##\s+\[([0-9]+(?:\.[0-9]+){1,3})\](?:\s+-\s+.*)?$")

    for line in markdown.splitlines():
        match = header.match(line.strip())
        if match:
            current = match.group(1)
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line.rstrip())

    return {version: "\n".join(lines).strip() for version, lines in sections.items()}


def grouped_bullets(section: str) -> Dict[str, List[str]]:
    groups: Dict[str, List[str]] = {}
    current = "Changes"

    for line in section.splitlines():
        stripped = line.strip()
        if stripped.startswith("### "):
            current = stripped.removeprefix("### ").strip()
            current = _HEADING_ALIASES.get(current, current)
            groups.setdefault(current, [])
            continue
        if stripped.startswith("- "):
            groups.setdefault(current, []).append(stripped[2:].strip())

    return groups


def ordered_headings(groups: Dict[str, List[str]]) -> List[str]:
    headings = [h for h in _HEADING_ORDER if groups.get(h)]
    headings.extend(h for h in groups if h not in headings and groups[h])
    return headings


def _md_inline_html(text: str) -> str:
    """Escape, then render inline markdown (**bold**, `code`, [text](url)) to HTML."""
    t = html.escape(text)
    t = _LINK_RE.sub(r'<a href="\2">\1</a>', t)
    t = _BOLD_RE.sub(r"<strong>\1</strong>", t)
    t = _CODE_RE.sub(r"<code>\1</code>", t)
    return t


def _render_list(items: List[str], cls: str = "") -> str:
    if not items:
        return ""
    li = "\n".join(f"<li>{_md_inline_html(x)}</li>" for x in items)
    cls_attr = f' class="{cls}"' if cls else ""
    return f"<ul{cls_attr}>\n{li}\n</ul>"


_NOTES_STYLE = """<style>
.rn { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; font-size: 13px; line-height: 1.55; color: #1d1d1f; -webkit-font-smoothing: antialiased; padding: 2px; }
.rn h2 { font-size: 18px; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 2px; }
.rn h3 { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: #86868b; margin: 18px 0 6px; }
.rn h3.hl { color: #0071e3; }
.rn ul { margin: 0; padding-left: 18px; }
.rn li { margin: 5px 0; }
.rn ul.highlights li { margin: 9px 0; }
.rn strong { font-weight: 650; }
.rn code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; background: rgba(0,0,0,0.06); padding: 1px 5px; border-radius: 5px; }
.rn a { color: #0071e3; text-decoration: none; }
.rn .more { color: #86868b; font-size: 12px; margin-top: 16px; }
@media (prefers-color-scheme: dark) {
  .rn { color: #f5f5f7; }
  .rn h3 { color: #98989d; }
  .rn h3.hl { color: #2997ff; }
  .rn code { background: rgba(255,255,255,0.13); }
  .rn a { color: #2997ff; }
}
</style>"""


def render_html(version: str, groups: Dict[str, List[str]], github_url: str) -> str:
    parts: List[str] = [_NOTES_STYLE, '<div class="rn">', f"<h2>What's New in {html.escape(version)}</h2>"]

    headings = ordered_headings(groups)
    if not headings:
        parts.append("<p>Small bug fixes and stability improvements.</p>")
    else:
        for heading in headings:
            is_highlights = heading == "Highlights"
            head_cls = ' class="hl"' if is_highlights else ""
            list_cls = "highlights" if is_highlights else ""
            parts.append(f"<h3{head_cls}>{html.escape(heading)}</h3>")
            parts.append(_render_list(groups[heading], cls=list_cls))

    parts.append(
        f'<p class="more">If Stargazer Bar helps, please '
        f'<a href="{html.escape(STAR_CTA_URL)}">star it on GitHub</a> so other maintainers can find it.</p>'
    )
    parts.append(f'<p class="more">Full release notes: <a href="{html.escape(github_url)}">{html.escape(github_url)}</a></p>')
    parts.append("</div>")
    return "\n".join(parts).strip() + "\n"


def render_text(version: str, groups: Dict[str, List[str]], github_url: str) -> str:
    out = [f"What's New in {version}", ""]
    headings = ordered_headings(groups)
    for heading in headings:
        out.append(f"{heading}:")
        out.extend(f"- {item}" for item in groups[heading])
        out.append("")
    if not headings:
        out.extend(["Changes:", "- Small bug fixes and stability improvements.", ""])
    out.append(f"Star Stargazer Bar on GitHub: {STAR_CTA_URL}")
    out.append(f"Full release notes: {github_url}")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Create Sparkle release notes from docs/CHANGELOG.md.")
    parser.add_argument("--version", required=True)
    parser.add_argument("--changelog", required=True)
    parser.add_argument("--github-url", required=True)
    parser.add_argument("--out-html", required=True)
    parser.add_argument("--out-text", required=True)
    args = parser.parse_args()

    sections = changelog_sections(read_text(args.changelog))
    if args.version not in sections:
        raise SystemExit(f"ERROR: {args.changelog} missing section for [{args.version}]")

    groups = grouped_bullets(sections[args.version])
    write_text(args.out_html, render_html(args.version, groups, args.github_url))
    text_notes = render_text(args.version, groups, args.github_url)
    write_text(args.out_text, text_notes)
    print(text_notes, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
