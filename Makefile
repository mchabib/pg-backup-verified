SCRIPTS := $(wildcard *.sh lib/*.sh tests/*.sh)

.PHONY: lint test integration all

all: lint test integration

lint:
	shellcheck -x $(SCRIPTS)

test:
	bats tests/unit

integration:
	bash tests/integration.sh
