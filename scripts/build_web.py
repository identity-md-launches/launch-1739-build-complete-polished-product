#!/usr/bin/env python3
"""Synchronize the committed ABI with forge output; the frontend is otherwise build-free."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
artifact = root / "out/AgentSkill.sol/AgentSkill.json"
if not artifact.exists():
    raise SystemExit("Run forge build first to generate the authoritative contract ABI.")
abi = json.loads(artifact.read_text())["abi"]
(root / "web/AgentSkill.abi.json").write_text(json.dumps(abi, indent=2) + "\n")
for asset in ("index.html", "styles.css", "app.js", "core.js", "config.js", "mark.svg", "vendor/ethers.min.js"):
    if not (root / "web" / asset).is_file():
        raise SystemExit(f"Missing frontend asset: {asset}")
print("AgentSkill dashboard ready in web/; ABI synchronized. No packages or network needed.")
