from __future__ import annotations

import json
from pathlib import Path
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, JsonValue


class Payload(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    datacenter: dict[str, JsonValue]
    contracts: dict[str, dict[str, JsonValue]]


root = Path.cwd()
payload_path = root / ".chapar-payload.json"
payload = Payload.model_validate_json(payload_path.read_text(encoding="utf-8"))
_ = (root / "datacenter.json").write_text(
    json.dumps(payload.datacenter, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
for target, contract in sorted(payload.contracts.items()):
    target_root = root / "targets" / target
    target_root.mkdir(parents=True)
    _ = (target_root / "contract.json").write_text(
        json.dumps(contract, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
payload_path.unlink()
