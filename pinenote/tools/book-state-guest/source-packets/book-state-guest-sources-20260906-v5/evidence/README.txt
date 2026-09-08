This evidence is source/static/derivation evidence only.

canonical-source-static.log is the fresh-candidate private-capsule gate.
frozen-replay.log repeats that gate from this packet's capsule.
capsule-check.log verifies exact private copies, modes, hashes, and views.
derive-system.log lowers the system without realizing it.
requisites.txt and requisites-check.log cover its exact 2,786-node graph.
namespace-* repeats lowering/query with the checkout and ambient /tmp hidden.
v4-v5-source-manifest.diff is the complete canonical source change roster;
v4-v5-authority.diff shows the authority's only two added wiring lines.
image-requisites.txt records the computed but unrealized raw-image graph.
image-prerequisites-dry-run.log records the exact 34 derivations still missing;
neither the kernel nor source-built gVisor is among them.

The Guile/Python boundary probes were parsed/compiled but not executed. Their
storage/UI denial claims require the separately authorized ARM/gVisor boot.
No image, kernel, gVisor, QEMU, runsc, ARM, network, mount, SSH, device, or
hardware execution occurred.
