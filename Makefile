PYTHON ?= python3

.PHONY: validate validate-event validate-puml

validate: validate-event validate-puml

validate-event:
	$(PYTHON) scripts/validate_example_event.py

validate-puml:
	bash scripts/check-puml.sh
