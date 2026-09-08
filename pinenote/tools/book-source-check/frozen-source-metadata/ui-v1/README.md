# Native baseline UI dependency

These two files are exact extractions from commit
`399764fa53d4e54bdcfaf84c362d4d1debf35f4c`. The accepted observer/native join
pins that UI manifest. The current QEMU fixture subsequently changed its startup
notice handling, so the native source map retains these historical bytes rather
than changing the accepted observer's dependency claim. Other files in the UI
view remain byte-identical canonical sources.

The current fixture is tested by `pinenote/tools/book-state-guest/run-tests.sh`;
the human device plugin has separate real-KOReader tests under
`pinenote/tools/book-state-device/`. A passing native baseline does not cover
those newer adapters.
