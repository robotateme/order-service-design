#!/usr/bin/env bash
set -euo pipefail

count=0

for file in *.puml; do
  [ -e "$file" ] || {
    echo "No .puml files found"
    exit 1
  }

  start_count="$(grep -c '@startuml' "$file")"
  end_count="$(grep -c '@enduml' "$file")"

  if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    echo "$file: expected one @startuml and one @enduml"
    exit 1
  fi

  count=$((count + 1))
done

echo "Checked $count PlantUML files."
