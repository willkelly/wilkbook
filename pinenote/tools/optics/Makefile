# E-ink optical-defect detectors -- the analyze half of the optics harness.
#
#   guix shell python python-numpy -- make check
#
# Pure/deterministic: validates the flash/ghost/settle/double-flash classifiers
# against synthetic clips (test_optics.py), the self-calibrating test card
# (test_epub.py), real-video ingest via a synthetic camera (test_ingest.py), the
# record/analyze bundle round-trip (test_bundle.py), the on-device drivers'
# command layer against a fake transport (test_driver.py), and the
# reconstructed 2026-07-12 evidence-audit passes plus their re-check of the
# COMMITTED dataset (test_audit.py). No camera and no device; see README.md
# ("Recording & bundles"). ffmpeg for the video paths.

check:
	python3 test_optics.py
	python3 test_epub.py
	python3 test_ingest.py
	python3 test_bundle.py
	python3 test_driver.py
	python3 test_audit.py

# Re-run the committed-data half of the 2026-07-12 evidence audit on its own:
# stdlib only, no numpy, no ffmpeg, no video. See audit.py's docstring for what
# it can and cannot re-check.
audit-dataset:
	python3 audit.py dataset

# Generate the test card (epub + manifest + optional page PNGs) into OUT.
OUT ?= build/testcard
testcard:
	python3 testepub.py $(OUT)

.PHONY: check testcard audit-dataset
