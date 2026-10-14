.PHONY: check build serve

build:
	forge build
	python3 scripts/build_web.py

check:
	forge fmt --check
	forge build
	FOUNDRY_FUZZ_SEED=0xd9abfe71f2055d0868d0a24539113f27a9d2c4acc16d0d4273df17ed8888b709 forge test
	node --test test/frontend/*.test.mjs

serve:
	python3 scripts/serve.py
