#!/usr/bin/env python3

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_PATH = ROOT / "docs" / "examples" / "order-created-integration-event.json"
SCHEMA_PATH = ROOT / "docs" / "examples" / "order-created-integration-event.schema.json"


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def validate_with_json_schema(example: dict, schema: dict) -> None:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(example), key=lambda e: list(e.absolute_path))
    if errors:
        message = "\n".join(
            f"- {'/'.join(map(str, err.absolute_path)) or '<root>'}: {err.message}"
            for err in errors
        )
        raise ValueError(f"JSON Schema validation failed:\n{message}")


def validate_business_rules(example: dict) -> None:
    payload = example["payload"]
    if not isinstance(payload["items"], list) or not payload["items"]:
        raise ValueError("payload.items must be a non-empty list")


def main() -> int:
    example = load_json(EXAMPLE_PATH)
    schema = load_json(SCHEMA_PATH)

    validate_with_json_schema(example, schema)
    validate_business_rules(example)

    print("Event example looks OK.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
