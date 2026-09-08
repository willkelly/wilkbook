# Native Book State integration

This directory is the first real vertical join of the accepted Guile SQLite
backend, typed state protocol/adapter, and the optional Book Session state
delegate.  It drives actual native Guile and Python fixture-book subprocesses
through Book Session's socketpair transport and proves save/reopen behavior
across fresh trusted authority processes.  The v2 correction also proves one
actual commit-first lost acknowledgement: the endpoint is closed while the
real adapter result is held before worker publication, then a fresh book
retries the same operation from reopened state without another commit.

It is intentionally **not** a new broker, daemon, generic state framework,
guest runtime, or reader integration.  See `CONTRACT.md` for the authority and
evidence boundaries.

The normal gate is:

```sh
make -C pinenote/tools/book-state-integration check
```

The gate executes only the immutable v2 source snapshot after validating its
fixed roster, complete Scheme/Python source manifest, and accepted core hashes.
Mutation checks cover the Python codec, Guile blocking-I/O helper, altered hash
manifest, unlisted shadow module, and caller-selected source/hash attempt.  The
Python fixture uses an exact-path codec loader under `python -I -S`; Scheme
module origins are checked against the private compiled cache.  The 4,096-byte
NUL regression remains mandatory.  `INPUT-IDENTITIES.txt` records the accepted
boundary; v1 remains unchanged under `build/` as historical evidence.
