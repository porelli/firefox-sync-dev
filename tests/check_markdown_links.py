#!/usr/bin/env python3
"""Check markdown links and anchors in documentation files."""

import os
import re
import sys
from pathlib import Path
from typing import Set, Tuple, List


def extract_links_and_anchors(content: str, filepath: Path) -> Tuple[List[Tuple[str, int]], Set[str]]:
    """Extract all links and defined anchors from markdown content.

    Returns:
        Tuple of (links with line numbers, set of defined anchors)
    """
    links = []
    anchors = set()

    # Extract links: [text](url) or [text](url#anchor)
    link_pattern = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')
    for i, line in enumerate(content.split('\n'), 1):
        for match in link_pattern.finditer(line):
            links.append((match.group(2), i))

    # Extract heading anchors (GitHub style: lowercase, spaces to dashes, remove special chars)
    heading_pattern = re.compile(r'^#+\s+(.+)$', re.MULTILINE)
    for match in heading_pattern.finditer(content):
        heading = match.group(1)
        # GitHub anchor conversion
        anchor = heading.lower()
        anchor = re.sub(r'[^\w\s-]', '', anchor)
        anchor = re.sub(r'\s+', '-', anchor)
        anchors.add(anchor)

    # Extract explicit anchors: <a name="..."> or <a id="...">
    anchor_pattern = re.compile(r'<a\s+(?:name|id)="([^"]+)"')
    for match in anchor_pattern.finditer(content):
        anchors.add(match.group(1))

    return links, anchors


def check_links(root_path: Path) -> int:
    """Check all markdown files for broken links.

    Returns:
        Number of errors found
    """
    errors = 0
    md_files = {}
    file_anchors = {}

    # Read all markdown files
    for md_file in root_path.glob('*.md'):
        if md_file.name.startswith('.'):
            continue
        content = md_file.read_text(encoding='utf-8')
        links, anchors = extract_links_and_anchors(content, md_file)
        md_files[md_file.name] = links
        file_anchors[md_file.name] = anchors

    # Check each link
    for filename, links in md_files.items():
        for link, line_num in links:
            # Skip external links
            if link.startswith(('http://', 'https://', 'mailto:')):
                continue

            # Normalize repo-relative paths (starting with /)
            if link.startswith('/'):
                link = link[1:]

            # Skip directory links
            if link.endswith('/') and not link.startswith('#'):
                target_dir = root_path / link.rstrip('/')
                if not target_dir.is_dir():
                    print(f"{filename}:{line_num}: broken directory link: {link}")
                    errors += 1
                continue

            # Parse link
            if '#' in link:
                if link.startswith('#'):
                    # Internal anchor
                    anchor = link[1:]
                    if anchor not in file_anchors.get(filename, set()):
                        print(f"{filename}:{line_num}: broken anchor: {link}")
                        errors += 1
                else:
                    # External file with anchor
                    parts = link.split('#', 1)
                    target_file = parts[0]
                    anchor = parts[1] if len(parts) > 1 else None

                    target_path = root_path / target_file
                    if not target_path.exists():
                        print(f"{filename}:{line_num}: broken link: {link} (file not found)")
                        errors += 1
                    elif anchor and target_file in file_anchors:
                        if anchor not in file_anchors[target_file]:
                            print(f"{filename}:{line_num}: broken anchor: {link}")
                            errors += 1
            else:
                # File or directory link without anchor
                target_path = root_path / link
                if not target_path.exists():
                    print(f"{filename}:{line_num}: broken link: {link}")
                    errors += 1

    return errors


def main():
    root = Path(__file__).parent.parent
    print(f"Checking markdown links in {root}")
    errors = check_links(root)

    if errors > 0:
        print(f"\n{errors} error(s) found")
        sys.exit(1)
    else:
        print("All links OK")
        sys.exit(0)


if __name__ == '__main__':
    main()
