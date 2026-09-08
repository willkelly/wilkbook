# Completion observer review brief

## Disposition requested

Review the exact frozen packet as a private, offline, trusted-observer source
successor.  Do not treat it as a UI join or a native-v1 acceptance.

The narrow question is whether one endpoint-owned slot can safely expose typed
Book State backend completions to trusted polling while preserving the accepted
Book Session/delegate/backend authority boundaries.  In particular, try to
find a path that:

1. publishes without an exact reservation or after a lifetime/generation
   change;
2. overwrites, drops silently, or grows beyond one completion;
3. lets presentation/paint/outer authority impersonate a backend result;
4. reports success when encoding, queue insertion, accepted-model handling, or
   observer construction failed;
5. re-runs backend I/O or acknowledgement bookkeeping for a cached reply;
6. lets an observer mutation alter queued bytes, protocol cache, or SQLite;
7. performs backend, transport, or UI I/O while holding an authority mutex; or
8. turns close/backpressure ambiguity into a false `commit-ok` rather than an
   exact retry requirement.

`CONTRACT.md` states the full boundary and `INPUT-IDENTITIES.txt` pins every
accepted external input.  The UI packet is independently accepted but remains
unchanged and unjoined.  The native-v1 execution packet is explicitly
provisional after NI1/NI2 evidence findings; only its immutable accepted-input
copies are used here.
