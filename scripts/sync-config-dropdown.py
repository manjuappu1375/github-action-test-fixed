#!/usr/bin/env python3
"""Regenerate workflow_dispatch config choices from configs/*.yaml files."""

import json
import re
from pathlib import Path


workflow = Path(".github/workflows/provision.yml")
config_dir = Path("configs")
config_files = sorted(
    (
        path
        for path in config_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".yaml", ".yml"}
    ),
    key=lambda path: path.name.lower(),
)

invalid = [
    path.name
    for path in config_files
    if not re.fullmatch(r"[A-Za-z0-9._-]+", path.name)
]
if invalid:
    raise SystemExit(
        "Config filenames must contain only letters, numbers, dots, "
        f"underscores, and hyphens: {', '.join(invalid)}"
    )

text = workflow.read_text()
start = text.index("      config_file:\n")
end = text.index("\n\npermissions:", start)
input_block = [
    "      config_file:",
    "        description: 'Config YAML to provision from the selected branch'",
    "        type: choice",
    "        required: true",
]
if config_files:
    input_block.append("        options:")
    input_block.extend(
        f"          - {json.dumps(path.as_posix())}" for path in config_files
    )
else:
    input_block = [
        "      config_file:",
        "        description: 'No config YAML files currently exist under configs/'",
        "        type: string",
        "        required: false",
    ]

updated = text[:start] + "\n".join(input_block) + text[end:]
if updated != text:
    workflow.write_text(updated)
    print(f"Updated workflow dropdown with {len(config_files)} config file(s).")
else:
    print(f"Workflow dropdown is already current ({len(config_files)} config file(s)).")
