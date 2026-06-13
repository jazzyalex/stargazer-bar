#!/usr/bin/env python3
import argparse
import html
import os
import re
from typing import Dict, List, Optional

STAR_CTA_URL = "https://github.com/jazzyalex/stargazer-bar"


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
            groups.setdefault(current, [])
            continue
        if stripped.startswith("- "):
            groups.setdefault(current, []).append(stripped[2:].strip())

    return groups


def render_html(version: str, groups: Dict[str, List[str]], github_url: str) -> str:
    parts = [f"<h2>What's New in {html.escape(version)}</h2>"]
    order = ["Features", "Bug Fixes", "Fixes", "Improvements", "Changes"]
    headings = [heading for heading in order if groups.get(heading)]
    headings.extend(heading for heading in groups if heading not in headings and groups[heading])

    if not headings:
        parts.append("<p>Small bug fixes and stability improvements.</p>")
    else:
        for heading in headings:
            items = "\n".join(f"<li>{html.escape(item)}</li>" for item in groups[heading])
            parts.append(f"<h3>{html.escape(heading)}</h3>")
            parts.append(f"<ul>\n{items}\n</ul>")

    parts.append(
        f'<p>If Stargazer Bar helps, please <a href="{html.escape(STAR_CTA_URL)}">star it on GitHub</a> '
        "so other maintainers can find it.</p>"
    )
    parts.append(f'<p>Full release notes: <a href="{html.escape(github_url)}">{html.escape(github_url)}</a></p>')
    return "\n".join(parts).strip() + "\n"


def render_text(version: str, groups: Dict[str, List[str]], github_url: str) -> str:
    out = [f"What's New in {version}", ""]
    for heading, items in groups.items():
        if not items:
            continue
        out.append(f"{heading}:")
        out.extend(f"- {item}" for item in items)
        out.append("")
    if len(out) == 2:
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
    html_notes = render_html(args.version, groups, args.github_url)
    text_notes = render_text(args.version, groups, args.github_url)
    write_text(args.out_html, html_notes)
    write_text(args.out_text, text_notes)
    print(text_notes, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
