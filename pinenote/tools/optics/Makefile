# E-ink optical-defect detectors -- the analyze half of the optics harness.
#
#   guix shell python python-numpy -- make check
#
# Pure/deterministic: validates the flash/ghost/settle/double-flash classifiers
# against synthetic clips with known injected defects (test_optics.py). No
# camera and no device -- the record half and real-video ingest (homography +
# reflectance normalization) come later; see README.md.

check:
	python3 test_optics.py
	python3 test_epub.py
	python3 test_ingest.py

# Generate the test card (epub + manifest + optional page PNGs) into OUT.
OUT ?= build/testcard
testcard:
	python3 testepub.py $(OUT)

.PHONY: check testcard
