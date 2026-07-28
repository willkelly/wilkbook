PATCH ?= ../../patches/linux-pinenote-7.0-forward-port.patch
EXTRACT ?= ../wbf/extract-from-patch.py
BUILD ?= build
CC := gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror -g
CPPFLAGS := -I$(BUILD)/include/uapi
HEADER := $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h

all: $(BUILD)/pinenote-ebc-sleep-frame-test $(BUILD)/ebc-barrier-test $(BUILD)/ack-wait-test $(BUILD)/signal-guard-test $(BUILD)/reader-scan-test

$(HEADER): $(PATCH) $(EXTRACT) shim/drm.h
	python3 $(EXTRACT) $(PATCH) $(BUILD) include/uapi/drm/rockchip_ebc_drm.h
	cp shim/drm.h $(BUILD)/include/uapi/drm/drm.h

$(BUILD)/abi-check: $(HEADER) shim/drm.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -x c -fsyntax-only -include drm/rockchip_ebc_drm.h /dev/null
	touch $@

$(BUILD)/pinenote-ebc-sleep-frame-test: pinenote-ebc-sleep-frame-test.c ebc-barrier.c ebc-barrier.h ack-wait.c ack-wait.h signal-guard.c signal-guard.h reader-scan.c reader-scan.h $(BUILD)/abi-check
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ pinenote-ebc-sleep-frame-test.c ebc-barrier.c ack-wait.c signal-guard.c reader-scan.c

$(BUILD)/ebc-barrier-test: ebc-barrier-test.c ebc-barrier.c ebc-barrier.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ ebc-barrier-test.c ebc-barrier.c

$(BUILD)/ack-wait-test: ack-wait-test.c ack-wait.c ack-wait.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ ack-wait-test.c ack-wait.c

$(BUILD)/signal-guard-test: signal-guard-test.c signal-guard.c signal-guard.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ signal-guard-test.c signal-guard.c

$(BUILD)/reader-scan-test: reader-scan-test.c reader-scan.c reader-scan.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ reader-scan-test.c reader-scan.c

check: all
	./$(BUILD)/ebc-barrier-test
	timeout 5s ./$(BUILD)/ack-wait-test
	timeout 5s ./$(BUILD)/signal-guard-test
	./$(BUILD)/reader-scan-test
	./$(BUILD)/pinenote-ebc-sleep-frame-test --help >/dev/null
	@./$(BUILD)/pinenote-ebc-sleep-frame-test --invalid >/dev/null 2>&1; test $$? -eq 2
	@! grep -Eq '/sys/power|/dev/(input|mmc|ttyS)|/boot/|/lib/firmware|/sys/class' pinenote-ebc-sleep-frame-test.c ebc-barrier.c
	@! grep -q 'pinenote-ebc-barrier-test-service' ../../services/*.scm
	@echo "ebc-barrier: static safety checks passed"

install: $(BUILD)/pinenote-ebc-sleep-frame-test
	install -Dm755 $(BUILD)/pinenote-ebc-sleep-frame-test $(DESTDIR)$(PREFIX)/bin/pinenote-ebc-sleep-frame-test

clean:
	rm -rf $(BUILD)

.PHONY: all check install clean
