# E-ink optical-defect detectors -- the analyze half of the optics harness.
#
#   guix shell python python-numpy -- make check
#
# Pure/deterministic: validates the flash/ghost/settle/double-flash classifiers
# against synthetic clips (test_optics.py), the self-calibrating test card
# (test_epub.py), real-video ingest via a synthetic camera (test_ingest.py), and
# the record/analyze bundle round-trip (test_bundle.py). No camera and no device;
# see README.md ("Recording & bundles"). ffmpeg is needed for the video paths.

check:
	python3 test_optics.py
	python3 test_epub.py
	python3 test_ingest.py
	python3 test_bundle.py

# Generate the test card (epub + manifest + optional page PNGs) into OUT.
OUT ?= build/testcard
testcard:
	python3 testepub.py $(OUT)

.PHONY: check testcard
