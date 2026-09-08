# Focused independent review request — exact post-V9 final binding

This review remains pending and is not required for the bounded author campaign.
The accepted V8 guest/V6 checker and V8 image reviews remain parent-only facts;
do not relabel them as successor review.

Review only the V9 filesystem declaration, the post-V9 compiled-service and UI
coordination fixes, their connected checks, the author-built image/payload
binding, and the source-fixed consumer. Do not rerun
producer design review or execute QEMU, runsc, ARM, or KOReader.

## Fixed inputs

```text
a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19  accepted parent V8/V6 source review
1a014ece021a59c12daebaa811938496754bf4e6e6b14679f89045ed37e51d53  accepted parent V8 image review document
082d078491dc72bba54cade339daa57dccf9ec4e93ffa49f2d76bf18ea64419a  successor source packet (author)
65bff26e399dae844b2b228b2ce07ce44bca793ac506c0123271531e330e79cf  successor source replay evidence (author)
9c6b55822571c5c69f6b06ed48a58f7987cbda53e072b741122995ac7e65cfe8  successor image/payload evidence (author)
1239c6e2187f66adc81e2faf54bc4e8aeba38a6b42f830985674c65d7a05689e  version-neutral 88-field binding table
```

## Requested decisions

1. Confirm `%state-file-system` uses exactly
   `(flags '(no-atime no-dev no-suid no-exec))`, has no `options` value, and
   retains the exact runtime `/proc/mounts` four-flag gate.
2. Confirm the V9→successor snapshot delta contains only the eleven expected
   records and preserves 134 source inputs, 19 project modules, and nine
   executable local-file assets.
3. Compare all 88 fields across the author table, private `BUNDLE.scm`, and
   source `image-binding.scm`. The schema remains version-neutral and closed
   across exactly eight roles.
4. Authenticate image `cbnpv8rx…` / `2839f9fc…`, embedded system
   `m42a8cc7… -> a4qgl0y3…`, payload manifest `0336260c…`, and outer manifest
   `22cc91b2…`. Confirm `PAYLOAD.sha256` is not build status.
5. Confirm callers supply only a canonical private bundle location. They cannot
   supply hashes, status, review claims, or alternate artifact authorities.
6. Confirm the accepted graph/OFD handoff, two fresh boots, A→B semantics,
   strict joins, four boundary records, static-Bash scrub, 23-file runtime
   capsule, generic `FAIL:` rejection, and `300/360/5/5/420/12` bounds remain.

## Finite replay

From the final immutable source copy:

```sh
./run-host-tests.sh \
  --v9-bundle "$PACKET/production-bundle" \
  --image-author-packet /tmp/opencode/book-state-image-post-v9-volume-ui-fix-author-20260907-v1
```

The gate performs read-only authentication and model tests only. Please issue a
finite verdict for this exact post-V9 successor, explicitly preserving the narrower
scope of all parent reviews.
