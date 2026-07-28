# PineNote reader BSP PM review-fix artifact — 2026-07-26

This manifest binds the offline validation inputs and results to the exact
`PNGuixRoot` artifact prepared for the separate user-present os2 write protocol.
It is not hardware, firmware-compatibility, suspend, wake, resume, optics, or
power evidence. No device access, os2 write, reboot, suspend request, or real
firmware/SMC/PSCI/regulator/CPU/MMIO action occurred during these gates.

**Binding-evidence correction (2026-07-26): superseded.** This artifact's
source/compiled-DTB gate recorded `compatible` and `status`; Linux OF later
synthesized standard `name = "rockchip-suspend"` in the live node. The then
parser rejected that metadata with `-EINVAL` before binding. This preserves the
artifact's offline facts but it must not be cited as successful binding evidence;
the corrected parser was then host-validated, and its later successful dormant
bind is recorded in the separate `namefix` manifest and `doc/status.md`.

## Source and inputs

- Kernel source worktree base: `5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2`
- Canonical PM patch:
  `pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch`
  - bytes: 53,525
  - SHA-256: `e70c68c0d6dbbce5984e7f52f0f43f8d904a9ec2278bade7ecdb50135c0abbcd`
- Validation-source-set digest: `00f5a9cf6d938693a13bc087d4a6366b1bd338082a84995bfe3f4828a13765a2`
  - algorithm: SHA-256 over 19 sorted relative paths and bytes; each record is
    `u32be(path length) || path || u64be(content length) || content`
  - set: `Makefile`, `pinenote/packages/kernel.scm`, the canonical PM patch,
    non-build files under `pinenote/tools/rockchip-pm/`, and the five PM/source
    suspend preflight scripts
- Device waveform input (never bundled):
  `/home/wkelly/pinenote-backup/2026-07-04-wbf-pull/ebc.wbf`
  - bytes: 2,097,152
  - SHA-256: `ba3d48837efc60353973f867ab15b4fa7dfbec755f6105c6d3e7e8b649c08f3b`

## Guix identities

- Derivation:
  `/gnu/store/0cfvsz1ilb7myzy4iknz0qjblckmn6xg-linux-pinenote-7.0.11-pinenote.drv`
- Kernel:
  `/gnu/store/43aa16pq7hd5p5ahka01yczhrb1fcp8d-linux-pinenote-7.0.11-pinenote`
- Direct reader build:
  `/gnu/store/lsnbn6hws33vip7aqpkdrmfgmmchy33z-system`
- System embedded in the extracted image:
  `/gnu/store/pdqr7rf00bzd4sb1d7mxqmk25qdbn83k-system`
- Packaged KOReader:
  `/gnu/store/4vfdfwz3jjbvw7f6y0kn2kqizni4j5zn-koreader-bin-2026.03`

## Deployment artifact

- Rootfs:
  `/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-reviewfix-20260726/pinenote-reader-PNGuixRoot-20260726.ext4`
  - bytes: 1,945,288,704
  - logical 512-byte sectors: 3,799,392
  - SHA-256: `0d5c432d5db8291d023c8061d364745f820f8391d8264444a19882dc6330fef6`
  - format: raw ext4, label `PNGuixRoot`, no partition table
- Rootfs-matched bundle:
  `/tmp/opencode/pinenote-reader-boot-bundle-bsp-pm-reviewfix-20260726`

| Bundle file | Bytes | SHA-256 |
| --- | ---: | --- |
| `extlinux/Image` | 20,406,784 | `a8b8cb89e0e71bab7aacbcca08c449a70890bbabfc4f251db18b85e4553290dc` |
| `extlinux/rk3566-pinenote-v1.2.dtb` | 62,107 | `9d981579a2bafd56b2c56c215c88b01a6ec2670dafc5d97a7dd949b66e229bf2` |
| `extlinux/initrd.cpio.gz` | 12,842,458 | `db7d08cb6e304fdc87618b523d6848d7ddb4aef2268b200072e184de775065b7` |
| `extlinux/extlinux.conf` | 574 | `85a8bae2ff4dff6d71e9032341a3f41aec8d119ab5ef1ca2a1ef869f6cc4222b` |

The bundle `Image` and DTB byte-match the named kernel output. The three binary
boot payloads were dumped from the exact ext4 and compared byte-for-byte; the
embedded and staged extlinux configurations both select those payloads and
`root=PNGuixRoot` (the staged file is generated, so it is checked semantically).

## Packaged hard-off evidence

Files dumped from the exact ext4 are under
`/tmp/opencode/pinenote-reader-packaged-evidence-bsp-pm-reviewfix-20260726`.

| File | SHA-256 |
| --- | --- |
| `kernel.config` | `310958576631a4e0add34afcf931ecfceee1fe43ef7309385448e9409d8d609c` |
| `System.map` | `f19f72b6de8329274b274bdfd50c4683fdd4fb62794cc4f1ed919b6470d28d60` |
| `suspend_policy.lua` | `25712167ce722b4ee26628e97f0cb8f344b8449288a27bf9a131a9f59f5183b7` |
| `device.lua` | `7f9f638e101a2cb32598d3b0f625f055048d62a1da390852d5dcc40ea59c35fb` |

The packaged config enables the production-linked core and omits hidden
activation. `System.map` contains parser/backend/executor symbols and omits the
activation prepare/complete callbacks. The policy is exactly `return false\n`,
and the restricted Lua harness proves `device.lua` follows the injected policy.
The compiled DT has one enabled policy-free `/rockchip-suspend` node, exactly
the approved cover/RK817 wake sources, and no CPU idle-state nodes/references.

## Commands and results

All commands below exited zero. Negative-fixture `FAIL:` lines from mutation
suites are expected rejection evidence, not aggregate failures.

1. Full host rung:
   `make wbf-check ebc-logic-check rastersim-check koreader-input-check orientation-check optics-check power-check rockchip-pm-check suspend-check WBF=/home/wkelly/pinenote-backup/2026-07-04-wbf-pull/ebc.wbf`
2. Source/config inspection:
   `guix shell git python -- pinenote/scripts/preflight/inspect-kernel-source.sh /tmp/opencode/linux-7.0.11-executor-work /gnu/store/43aa16pq7hd5p5ahka01yczhrb1fcp8d-linux-pinenote-7.0.11-pinenote/.config`
3. Guix ladder: `make kernel-drv`, `make kernel`, `make packages`, `make reader`,
   and `make rootfs-reader ARTIFACTS=/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-reviewfix-20260726`
4. Rootfs/bundle inspection: `inspect-rootfs-image.sh`,
   `stage-boot-bundle-from-rootfs.sh`, and `inspect-boot-bundle.sh` against the
   paths above
5. Packaged DT/config/Lua gates: `inspect-pinenote-battery-dtb.sh` and
   `inspect-pinenote-suspend-gates.sh` against the dumped packaged evidence
6. Complete mock-helper gate with the built firmware-support, diagnostics, and
   EBC-test package paths
7. QEMU rung 4:
   `make qemu-virt-check ROOTFS=...reviewfix...ext4 WAVEFORM=.../ebc.wbf`
   - PASS log: `/tmp/opencode/pinenote-virt-assert-315700.log`
8. QEMU rung 4v:
   `make qemu-virt-visual ROOTFS=...reviewfix...ext4 WAVEFORM=.../ebc.wbf`
   - PASS screenshots/logs: `/tmp/opencode/pinenote-virt-visual-315687`

Rung 4 reached every required kernel/initrd/root/service sentinel and powered
off cleanly. Rung 4v reached login, bound virtio-gpu, produced a non-uniform
1872x1404 KOReader frame, and changed the screen after a scripted tap.

## Remaining boundary

This image was written to os2 with exact-range readback verification and booted,
but Linux OF's synthesized standard `name` metadata exposed the parser bug
recorded above and left the driver unbound. It is superseded by the separate
`namefix` artifact and must not be written again as the active candidate.
Activation, active DT policy, firmware compatibility, PineNote
suspend-state/resume dependencies, DDR retention, physical wake, regulator
behavior on hardware, EBC repair, and suspend energy remain unproven. Suspend
stays disabled.
