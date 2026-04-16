#!/usr/bin/env python3

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_PATH = ROOT / "docs" / "examples" / "order-created-integration-event.json"
SCHEMA_PATH = ROOT / "docs" / "examples" / "order-created-integration-event.schema.json"


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def assert_required(obj: dict, required: list[str], label: str) -> None:
    missing = [key for key in required if key not in obj]
    if missing:
        raise ValueError(f"{label} is missing required fields: {', '.join(missing)}")


def main() -> int:
    example = load_json(EXAMPLE_PATH)
    schema = load_json(SCHEMA_PATH)

    assert_required(example, schema["required"], "event")

    if example["eventType"] != schema["properties"]["eventType"]["const"]:
        raise ValueError("eventType does not match schema const")
    if example["aggregateType"] != schema["properties"]["aggregateType"]["const"]:
        raise ValueError("aggregateType does not match schema const")

    payload = example["payload"]
    payload_required = schema["properties"]["payload"]["required"]
    assert_required(payload, payload_required, "payload")

    if not isinstance(payload["items"], list) or not payload["items"]:
        raise ValueError("payload.items must be a non-empty list")

    item_required = schema["properties"]["payload"]["properties"]["items"]["items"]["required"]
    for index, item in enumerate(payload["items"], start=1):
        assert_required(item, item_required, f"payload.items[{index}]")
        if item["quantity"] < 1:
            raise ValueError(f"payload.items[{index}].quantity must be >= 1")
        if item["price"] < 0:
            raise ValueError(f"payload.items[{index}].price must be >= 0")

    headers = example["headers"]
    headers_required = schema["properties"]["headers"]["required"]
    assert_required(headers, headers_required, "headers")

    print("Event example looks OK.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
