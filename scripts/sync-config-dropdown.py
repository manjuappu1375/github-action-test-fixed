#!/usr/bin/env python3
"""Refresh the workflow_dispatch config choices from configs/*.yaml files."""

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

if not config_files:
    raise SystemExit("No YAML config files found directly under configs/.")

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
    "        options:",
    *(f"          - {json.dumps(path.as_posix())}" for path in config_files),
]
updated = text[:start] + "\n".join(input_block) + text[end:]

if updated != text:
    workflow.write_text(updated)
    print(f"Updated config dropdown with {len(config_files)} file(s).")
else:
    print(f"Config dropdown already has all {len(config_files)} file(s).")
