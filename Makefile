# Convenience targets for the catallactics channel.

.PHONY: check build lint pins clean

check:
	./tests/check-static.sh

build:
	./tests/build-all.sh

lint:
	./tests/lint.sh

pins:
	./tests/check-channel-pins.sh

clean:
	rm -rf .substitute-cache .substitute-site .substitute-nars result result-* built-paths.txt .build-status
