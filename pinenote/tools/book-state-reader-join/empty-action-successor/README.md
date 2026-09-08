# State-text action successor candidate

This directory is a **join-local candidate**, not a modification or claimed new
acceptance of completion-observer v1. `book-session.scm` is the exact result of
applying `observer-0342-empty-state-text.patch` to the accepted observer source:

```text
0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f  accepted book-session.scm
```

The finite API delta is one trusted constructor:

```scheme
(make-book-session-host-with-state-text-observer FACTORY)
```

Its endpoints allow action and presentation text in the Book State range of
0 through 4,096 UTF-8 bytes. The policy is fixed at trusted host construction;
there is no peer flag, wire-schema change, action-name exception, generic RPC
registry, or caller-selected limit. Existing constructors retain their accepted
nonempty action rule and 2,048-byte action limit. The accepted state protocol,
delegate, adapter, backend, observer semantics, and UI are unchanged.

`test-state-text-action-policy.scm` checks both sides of that boundary. The v2
join gate also reruns the unchanged accepted 227 Book Session, 61 state-session,
and 37 completion-observer tests against this candidate.
