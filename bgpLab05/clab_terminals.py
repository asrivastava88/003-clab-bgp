#!/usr/bin/env python3
"""Generate .vscode/tasks.json: one terminal per containerlab node (tab = node name)
plus a compound '<lab>: open all' task. Run on the containerlab host.

Usage: python3 clab_terminals.py <lab-name>
# lab name will be in the "*.clab.yml" file Eg: bgp-lab02.clab.yml
# name: bgp-lab02

Also run the script from your workspace root. Sometimes, you may have to reload the VSCode.

Do this before containerlab destroy
Kill the terminals first
Ctrl+Shift+P → Terminal: Kill All Terminals
"""
import json
import pathlib
import subprocess
import sys

# clab kind -> exec command (no SSH/password needed)
EXEC = {"arista_ceos": "Cli", "sonic-vs": "vtysh", "linux": "bash"}

lab = sys.argv[1]
fmt = '{{.Label "clab-node-name"}}|{{.Names}}|{{.Label "clab-node-kind"}}'
out = subprocess.run(
    ["docker", "ps", "--filter", f"label=containerlab={lab}", "--format", fmt],
    capture_output=True, text=True, check=True,
).stdout
nodes = sorted(line.split("|") for line in out.splitlines() if line)
if not nodes:
    sys.exit(f"No running containers for lab '{lab}'")

tasks = [
    {
        "label": name,
        "type": "shell",
        "command": f"docker exec -it {cname} {EXEC.get(kind, 'sh')}",
        "problemMatcher": [],
        "presentation": {"panel": "dedicated", "reveal": "always", "focus": False},
    }
    for name, cname, kind in nodes
]
tasks.append({
    "label": f"{lab}: open all",
    "dependsOn": [n[0] for n in nodes],
    "dependsOrder": "parallel",
    "problemMatcher": [],
})

vsc = pathlib.Path(".vscode")
vsc.mkdir(exist_ok=True)
(vsc / "tasks.json").write_text(json.dumps({"version": "2.0.0", "tasks": tasks}, indent=2))
print(f"{len(nodes)} nodes -> .vscode/tasks.json  (run task: '{lab}: open all')")