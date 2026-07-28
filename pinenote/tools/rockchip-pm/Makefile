PATCH := ../../patches/linux-pinenote-7.0-bsp-sip-probe.patch
EXTRACT := ../wbf/extract-from-patch.py
BUILD := build
CC := gcc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror -g
SANITIZE_CFLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer
CPPFLAGS := -Ishim -I$(BUILD) -I$(BUILD)/include -I$(BUILD)/drivers/soc/rockchip
FIXTURES := fixtures/donor-pinenote-policy.dts fixtures/maximal-policy.dts
DTBS := $(patsubst fixtures/%.dts,$(BUILD)/fixtures/%.dtb,$(FIXTURES))
COMPILED_FIXTURES := $(BUILD)/rockchip-pm-compiled-fixtures.h

EXTRACTED := $(BUILD)/include/soc/rockchip/rockchip_legacy_sip.h \
	$(BUILD)/include/dt-bindings/suspend/rockchip-rk3568.h \
	$(BUILD)/drivers/soc/rockchip/rockchip_suspend_model.h \
	$(BUILD)/drivers/soc/rockchip/rockchip_suspend_model.c \
	$(BUILD)/drivers/soc/rockchip/rockchip_suspend_executor.c

$(EXTRACTED) &: $(PATCH) $(EXTRACT)
	python3 $(EXTRACT) $(PATCH) $(BUILD) \
	  include/soc/rockchip/rockchip_legacy_sip.h \
	  include/dt-bindings/suspend/rockchip-rk3568.h \
	  drivers/soc/rockchip/rockchip_suspend_model.h \
	  drivers/soc/rockchip/rockchip_suspend_model.c \
	  drivers/soc/rockchip/rockchip_suspend_executor.c

$(BUILD)/fixtures/%.dtb: fixtures/%.dts
	@command -v dtc >/dev/null || { echo 'FAIL: dtc is required for compiled PM fixtures' >&2; exit 1; }
	mkdir -p $(@D)
	dtc -I dts -O dtb -o $@ $<

$(COMPILED_FIXTURES): compiled-dtb-policy.py $(DTBS)
	@command -v fdtdump >/dev/null || { echo 'FAIL: fdtdump is required for compiled PM fixtures' >&2; exit 1; }
	mkdir -p $(@D)
	python3 compiled-dtb-policy.py --header $@ $(word 1,$(DTBS)) $(word 2,$(DTBS))

$(BUILD)/rockchip-pm-test: rockchip-pm-test.c $(EXTRACTED) $(COMPILED_FIXTURES) \
	shim/linux/errno.h shim/linux/types.h
	$(CC) $(CFLAGS) $(SANITIZE_CFLAGS) $(CPPFLAGS) -o $@ rockchip-pm-test.c

check: $(BUILD)/rockchip-pm-test
	./$(BUILD)/rockchip-pm-test
	python3 test-compiled-dtb-policy.py
	python3 check.py $(PATCH)
	sh ../../scripts/preflight/test-validate-rockchip-pm-source.sh

activation-positive-check: $(BUILD)/rockchip-pm-test
	./$(BUILD)/rockchip-pm-test --activation-positive
	python3 check.py $(PATCH)

clean:
	rm -rf $(BUILD)

.PHONY: activation-positive-check check clean
