# Pre-share adversarial documentation review — 2026-08-06

Before sharing the repo with a second person, the entire documentation
set (23 docs, ~12k lines, plus the Makefile, LICENSE, and tool listings)
was adversarially reviewed and then swept to match reality. This file is
the record: method, what was fixed, what was deliberately deferred, and
the full findings list.

## Method

Multi-agent, two passes, all findings skeptic-verified before action:

1. **Review** (41 agents): two fresh-eyes personas (a new PineNote owner
   deploying to their own device; a new contributor's AI agent with no
   private context), a mechanical cross-reference auditor, a
   privacy/secrets sweep of the working tree and full git history, and
   eight per-area staleness audits — every claim checked against
   `doc/status.md`, git history, and the code. 110 raw findings were
   reduced to **85 confirmed** (4 blocker, 31 major, 45 minor, 5 nit) by
   a per-file skeptical verification pass (30 refuted, mostly
   cross-agent duplicates), plus a completeness critic.
2. **Apply** (11 agents + main session): the landing layer (README,
   CLAUDE.md, ROADMAP, the new `doc/device-access.md`) was rewritten by
   the main session; eight area agents applied the per-doc findings;
   three re-verification agents then re-audited the result (one
   must-fix found and fixed: the 2026-08-03 unplugged-soak session was
   missing from status.md).

## Headline defects (all fixed)

- **README** was frozen at the 2026-07-04 kernel-bringup state and never
  mentioned the reader flavor — the actual product.
- **CLAUDE.md and doc/power-management.md asserted the inverse of the
  suspend reality** (suspend disabled / activation hard-off / no
  autosuspend), while status.md recorded deep suspend working,
  activation live, and an auto-suspend daemon deployed. The sync
  discipline had broken during the power sprint.
- **doc/status.md itself** was missing every session after 2026-08-03,
  its "Current os2 contents" section described an image three deploys
  old, and it had no current-state summary. Now: a dated Current state
  header, backfilled 2026-08-04..06 entries, and a corrected os2
  section that defers to the newest deploy entry.
- **No path existed for a second person**: no host prerequisites, no
  provision-your-own-device path, device-access conventions living only
  in the author's agent memory, single-user commit conventions, and a
  reader image only the author can SSH into (now documented; see
  deferred items).

## Deliberately deferred (decisions for Will)

1. **Git history rewrite.** *Decided 2026-08-06: no rewrite — residuals
   accepted.* The home Wi-Fi SSID survives in git history and two
   commit messages (tree is scrubbed); the device's Wi-Fi MAC survives
   in three historical blobs; home-LAN IPs appear in history and commit
   messages. Will reviewed the exposure and accepted it for GitHub
   sharing. The load-bearing fact behind that call: verified clean
   everywhere, tree and all 1,201 historical blobs — no PSK,
   passphrase, private key, token, or waveform binary was ever
   committed.
2. **Hosting/access.** *Decided 2026-08-06: GitHub.* The repo will be
   shared via GitHub, so no Forgejo provisioning is needed. With item 1
   decided as accepted, the history can be pushed as-is — nothing
   sequences ahead of the first push anymore.
3. **SSH key parameterization.** `pinenote/systems/pinenote-reader.scm`
   bakes the author's public key as root's only authorized key. Now
   documented in `doc/networking.md` §4.1 with the swap-before-build
   step; the designed `/state`-based authorized_keys mechanism remains
   the right fix and is unimplemented.
4. **Suspend-gate reconciliation.**
   `inspect-pinenote-suspend-gates.sh` still rejects the CPU idle-state
   nodes the shipped (and hardware-proven) kernel carries; the doc
   notes the expected failure. The script needs a reviewed update.
5. **Artifact-root rename.** `/tmp/opencode` is a stale tool name, but
   it is the hard-coded write-containment boundary in eight
   preflight/qemu scripts — renaming must move those scripts in the
   same change. Documented in the Makefile; volatility warning added.
6. **Deployed-image full hash.** The 2026-08-06 os2 image is on record
   only as `1a582179…` (prefix); recover the full SHA-256 from the p7
   staged copy or the device next session.
7. **Committing convention.** CLAUDE.md now carries a proposed
   two-person convention (branch + review for the kernel patches and
   safety docs; direct push for docs/tools; per-operator status.md
   entries). Adjust to taste with the collaborator.
8. **Wi-Fi MAC / flavor closure sizes / private-backup manifest copies**
   — small items recorded in the apply-phase reports; none blocks
   sharing.

The two workflow outputs (full per-finding evidence, per-agent apply
reports, and re-check results) are session artifacts; the durable record
is this file plus the diffs in the 2026-08-06 review commits.

---

<!-- The appendices below are the verbatim confirmed/refuted findings of
     the review pass, generated from the review workflow's structured
     output. Line numbers refer to the pre-fix tree. -->
## Appendix A: confirmed findings (85)


### Blocker

- **[wrong] `CLAUDE.md:133`** — The agent-onboarding file states suspend is disabled and activation is hard-off, while doc/status.md (the declared single source of truth) records deep suspend working, BSP activation LIVE and BOUND, and auto-suspend deployed to os2 — a new agent would start with the project's most safety-loaded fact inverted.
  - *Recommendation:* Rewrite the suspend paragraphs of 'Where we are' to match status.md (deep suspend proven, activation live, auto-suspend deployed, ssh intermittency warning). Structurally: shrink the 110-line status dump to a dated 10-line summary plus a hard pointer to doc/status.md — this is the second time the dump has contradicted the file CLAUDE.md itself declares the single source of truth, and the drift class will recur with two contributors.
- **[stale] `README.md:17`** — The landing page's status is frozen at the 2026-07-04 kernel-bringup session and presents `rootfs-usb-console` as the primary build, hiding that the project is now a deployed KOReader reader image with Wi-Fi/SSH, working deep suspend, and an autosuspend daemon.
  - *Recommendation:* Refresh README status to 2026-08: mark goal 3 achieved, add `make rootfs-reader` as the deployed reading-first target to the quick start, and mention the suspend/power state in one paragraph pointing at doc/status.md and doc/power-management.md.
- **[stale] `doc/power-management.md:970`** — The doc's activation posture is inverted: multiple sections state BSP SIP activation is hard-off/unset and the gate rejects it, but the tree ships activation enabled, the gate now REQUIRES it, and it is live on hardware.
  - *Recommendation:* Rewrite the 'Offline qualification gate', 'BSP SIP compatibility milestone', and 'Current blockers' sections to the post-2026-08-02 reality (activation on, policy 0x5ec/0x10, gate requires it), and move the pre-activation text into a clearly dated historical subsection.
- **[stale] `doc/power-management.md:235`** — The doc asserts no autosuspend exists and no unsupervised code may write /sys/power/state, but a deployed auto-suspend daemon has been sleeping/waking the device on its own since 2026-08-02, making SSH intermittent — a first-session trap for the new person.
  - *Recommendation:* Update the 'E-reader suspend contract' verdict and the ordering list: item 1 is shipped (daemon, config knobs, charging inhibit, press-to-suspend); document the ssh-intermittency/enabled=0 workflow here since this is the doc a contributor will read before touching power.

### Major

- **[structure] `CLAUDE.md:118`** — The committing convention is explicitly single-user ('commit and push to main freely') with no branch/review discipline and no protocol for merging doc/status.md when two people run hardware sessions on two different devices — it breaks the day the collaborator clones.
  - *Recommendation:* Before sharing: replace the Committing section with a two-person convention (short-lived branches or lightweight PRs for anything touching the forward-port patch or safety docs; push-to-main OK for docs), and define the status.md protocol — per-device session entries labeled by device/operator, since 'hardware truth' is now truth about two devices.
- **[portability] `CLAUDE.md:108`** — The safety model bakes Will's personal agent authorization into the shared repo — 'Writing os2 has standing permission' — which a collaborator's agent would read as repo-granted permission to dd their device, and which references a sudo policy and permission state that only exist in Will's environment.
  - *Recommendation:* Rephrase as operator-scoped: 'each operator may grant their own agent standing os2-write permission after the runbook backups exist for THEIR device; the protocol is: confirm os1 is root, os2 unmounted, dd, readback-SHA verify'. Never state permission as a property of the repo.
- **[missing] `README.md`** — The repo's canonical remote is a Forgejo instance on the author's private home LAN, and no document anywhere states where the repository is hosted or how a second person clones from, pulls from, or pushes to it — the collaboration transport itself is undocumented, separately from the already-flagged commit-convention gap.
  - *Recommendation:* Before sharing, decide and write down the transport: either provision the collaborator on the Forgejo instance (their own account/SSH access, reachable off-LAN) or move/mirror the repo, and add a short 'Repo hosting and syncing' note to README.md or CLAUDE.md's Committing section covering where origin lives, how to reach it, and how the two of you exchange commits.
- **[stale] `ROADMAP.md:303`** — The suspend-program bullet in ROADMAP §4 asserts activation is disabled and forbids idle autosuspend until unplugged energy measurements pass — both overtaken by 2026-08-02/03 events, and the stated gate was bypassed without the roadmap recording the decision.
  - *Recommendation:* Refresh §4's suspend and awake-power bullets to the post-2026-08-03 state (mechanism proven; remaining work = unplugged soak, wake attribution, TPS ENABLE question), and either record the decision that superseded the 'no idle autosuspend until...' gate or restore the gate. ROADMAP:4 says 'this file is direction, not status' — trim the embedded status prose to pointers so this drift class stops.
- **[portability] `channels.scm:7`** — Both channels track unpinned `master` and no doc records a known-good guix/nonguix commit, so the collaborator's first build runs against a different, unvalidated world than every build recorded in status.md.
  - *Recommendation:* Pin channels.scm to the last-validated guix and nonguix commits (or record them in doc/building.md with a time-machine invocation) so the collaborator can reproduce a validated build before chasing master.
- **[missing] `doc/building.md:3`** — No host-setup prerequisites exist anywhere: how Guix must be installed, that nonguix module visibility is required, substitute-server setup, or time/disk expectations for a from-source cross kernel build.
  - *Recommendation:* Add a 'Host prerequisites' section to doc/building.md: Guix installation state, channel setup (`guix pull -C channels.scm` or time-machine), nonguix substitute key/server if used, and honest first-build time/disk numbers.
- **[missing] `doc/device-runbook.md:1`** — The runbook is the author's-device ledger (his LAN IP, VCOM 1430000 uV, backups on wkelly-only local/NFS paths) presented as satisfied history, while doc/hardware-deploy.md:10-13 makes that exact checklist a per-session deploy precondition and its stop conditions forbid writing without it — so a collaborator with their own PineNote cannot satisfy the protocol as written; the only provision-your-device guidance is the archived, command-free doc/archive/phase1a-bringup-plan.md:104-190 (backup list, VCOM read, rescue checks), which no current doc points to, and the "Gate 6" title references a ladder defined nowhere current.
  - *Recommendation:* Reframe the doc as "the author's device ledger" and add a provision-YOUR-device path: enable SSH on stock Debian, take each listed backup with explicit dd commands (waveform p2, uboot_env p3, uboot p1, logo p4, first-16M), read your own VCOM and partition map, record your own IP/host key. Retire the orphaned Gate 6 title.
- **[stale] `doc/driver-findings-report.md:93`** — Finding 3 (use-after-free in rockchip_ebc_ctx_free) is presented as an open, unfixed defect, but it has been fixed in-tree since 2026-07-28 — unlike findings 1, 2, and 7, it carries no 'Fixed in-tree' note, so the community-facing report contradicts the very tree it describes.
  - *Recommendation:* Add a 'Fixed in-tree 2026-07-28' note to finding 3 mirroring the format used for findings 1/2/7 (and cite the ASan pin), so the report matches the patch the collaborator will read; the upstream backport ask can stay.
- **[missing] `doc/driver-findings-report.md:1002`** — The inherited resume damage-baseline defect found 2026-08-02 — the suspend_was_requested re-init branch never seeds the kmalloc'd final_atomic_update diff baseline, so post-resume damage is diffed against uninitialised memory and silently dropped by drop-on-match — is a certain, community-relevant driver defect missing from the community-facing report (its newest finding is 2026-08-01), and it is tracked nowhere in the upstream register either.
  - *Recommendation:* Add a dated finding to driver-findings-report.md (mechanism, silence property, in-tree fix via the mutation-tested validate-ebc-resume-baseline-hunk.sh gate, and the honesty caveat that it is not proven to be the whole dead-write explanation), and ensure the register's item 1 umbrella covers it.
- **[wrong] `doc/eink-research.md:33`** — eink-research.md still carries four claims that eink-sota §5 documented as wrong on 2026-07-12, despite the doc being touched twice since — the 'fold corrections on next touch' mechanism silently failed across the whole repo.
  - *Recommendation:* Before sharing, fold eink-sota §5's corrections 1-4 into eink-research.md (each is a one-to-three line edit) and mark them done in the register, or at minimum add a banner in eink-research pointing at the register. A new collaborator is told by CLAUDE.md to read eink-research before display work and will absorb claims the project has already disproven, in a doc they cannot find (see the orphan finding).
- **[wrong] `doc/eink-research.md:258`** — eink-research §8 asserts 'dclk_select semantics confirmed (-1 mode/0=200 MHz/1=250 MHz)' and calls PNDeb's dclk_select=1 'evidence the higher pixel clock is now considered stable', but the project measured on 2026-07-30 that dclk_select=1 is a no-op that rounds back to 200 MHz.
  - *Recommendation:* Annotate §8's two dclk lines the same way §2 got its frame-clock note: the request semantics are 250 MHz but the RK3566 CRU rounds to 200, so dclk_select=1 delivers nothing on this silicon and the PNDeb 'stability evidence' is evidence of a no-op. Without this, a new contributor chasing refresh speed is pointed at a lever the project already measured dead.
- **[structure] `doc/eink-sota.md:1`** — eink-sota.md (886 lines, actively maintained, holds the ranked steal list and the corrections register) is orphaned: it appears in no navigation map, and its own companion doc never mentions it.
  - *Recommendation:* Add eink-sota.md to the CLAUDE.md doc map and README doc list with a one-line differentiation: eink-research.md = curated domain background kept current; eink-sota.md = the 2026-07-12 adversarially-verified state-of-the-art review with the ranked steal list and a corrections register. Add a forward pointer in eink-research.md's header. Do NOT archive either doc: both were updated 2026-07-30, eink-research is cited from six docs, and eink-sota feeds the active pageturn program.
- **[missing] `doc/hardware-deploy.md:10`** — No first-session-on-a-new-device path: deploy preconditions reference the author's backup ledger, IP, and VCOM, with no walkthrough for creating and verifying a collaborator's own backup set or naming the assumed os1 baseline image.
  - *Recommendation:* Add a 'first session on a new device' section: required starting state (which PineNote Debian image/partition layout), how to take and verify the backup set from stock os1, how to read your own VCOM/IP, then hand off to the existing write protocol. Genericize device-runbook.md into a template checklist with Will's inventory as a filled-in example.
- **[stale] `doc/hardware-deploy.md:89`** — The one-shot EBC barrier campaign section still reads as a pending procedure — calling the damage producer "still only a hypothesis" and directing the operator to settle the 2026-07-29 panel question — although the campaign PASSED on 2026-07-30 with the producer measured and the panel anomaly closed, and the doc was committed twice afterward (2026-08-02) without a completion marker.
  - *Recommendation:* Add the same completed/replay banner the defio sweep section has, replace the hypothesis wording with the measured result, and note that the deployed cmdline now carries vt.global_cursor_default=0 (pinenote/images/pinenote-initramfs.scm:248) so operators verify it instead of rediscovering the cursor-damage failure mode.
- **[stale] `doc/kernel-forward-port.md:55`** — The kernel-packaging doc documents only 2 of the 6 patches applied to linux-pinenote and says 'two kernel packages' where kernel.scm defines three; a collaborator following its refresh procedure would rebase the forward-port patch unaware the other four (st-accel-pm, cpuidle-psci incl. its wedge risk, vdd-cpu-auto-pfm, dmc-static-low) exist and also need carrying.
  - *Recommendation:* Add a patch-inventory section listing all six patches with one-line purposes and pointers to their owning docs (power-management.md, upstream-register.md items 8/10), state which patches a full refresh must NOT swallow, and update 'The two kernel packages' to cover linux-pinenote-debug. This is the doc a collaborator refreshing the kernel will follow first.
- **[portability] `doc/kernel-forward-port.md:7`** — CLAUDE.md tells readers the standing device-access conventions live 'in the agent's memory and doc/kernel-forward-port.md', but this doc contains only os1 dmesg-signature oracle data — the actual conventions exist solely in the author's private agent-memory file, which will not transfer to the collaborator.
  - *Recommendation:* Extract the durable, non-address conventions from the agent-memory file into the repo (either a device-access section here or doc/device-runbook.md) and fix the CLAUDE.md pointer. Honor the author's standing request that the reader's static IP not be written into repo docs. Without this, the collaborator's agents cannot follow the project's core 'exhaust the oracle before a hardware session' discipline.
- **[stale] `doc/kernel-forward-port.md:93`** — Four 'unproven on hardware' annotations describe features that status.md records as hardware-proven — two of them for over a month — misleading a new contributor about validation state and inviting redundant hardware-session planning.
  - *Recommendation:* Sweep the doc for 'unproven'/'waits for' annotations and update all four against status.md; consider a standing header note that status.md wins on hardware-proof currency.
- **[stale] `doc/koreader-spike.md:112`** — Section 4 ('what actually ships') describes the pre-publish-on-call refresh architecture: it says refreshPartialImp is a no-op riding deferred-io, which the shipped device target has not done since 2026-07-31.
  - *Recommendation:* Either rewrite §4/§5 to match the publish-on-call architecture with a pointer to doc/refresh-policy.md, or add a dated superseded banner on §4/§5 pointing there. Without one of these, the new collaborator's mental model of the refresh path will be exactly the architecture the 2026-08-01 flagship fix replaced.
- **[missing] `doc/networking.md:313`** — The implemented-state section (§4.1) never mentions that the reader image hardcodes the author's personal SSH key as root's only authorized key, so a collaborator who builds the unmodified reader flavor gets a device they can never SSH into, with no doc telling them to swap the key first.
  - *Recommendation:* Document the baked key in §4.1 with an explicit "replace with your own public key before building" step (or implement the /state authorized_keys path the doc itself recommends). Note the workaround: the ACM console's passwordless-sudo reader shell can append a key post-boot, but that costs part of a hardware session.
- **[stale] `doc/networking.md:444`** — §6's validation ledger still lists wlan0 module autoload, rfkill state, MAC stability, and the os1 supplicant/interface-name harvest as open device-needing checks although they were resolved on 2026-07-10 — and the doc's own rule ("unlabelled items in §6 remain open") invites a collaborator to spend a scarce hardware/oracle session re-answering answered questions.
  - *Recommendation:* Label these four items RESOLVED 2026-07-10 with pointers to the status.md evidence, leaving the genuinely open items (regdomain selection, /state partition reality, SSH host-key persistence across reflash, USB-ECM gadget) as the remaining ledger.
- **[stale] `doc/pageturn-program.md:27`** — The doc still presents the portrait double-refresh / 50 ms deferred-io window as an open defect with pending fix candidates, but it was fixed on glass 2026-08-01 (publish-on-call, defio_delay_ms=250) — the doc predates the fix and was never updated.
  - *Recommendation:* Add a dated status banner at the top (the opening "The working plan…" gives a new reader no currency signal) stating: the portrait two-pass defect is FIXED on glass 2026-08-01 via publish-on-call (see refresh-policy.md); the §0 cost model (50 ms flush, 750 ms felt) describes the pre-fix image; the single-flush-paint candidate and the d1 stagger caveat are retired. Annotate rather than rewrite — the ranked table still has live content (a, b, e4, d1).
- **[stale] `doc/pageturn-program.md:343`** — Candidate d2 (post-flush wash alignment) is still ranked #2 as an untried userspace-timing candidate, but it was implemented driver-side in publish-on-call (ioctl drains deferred-io + damage worker before arming the wash) and hardware-proven on the 2026-08-01 image.
  - *Recommendation:* Mark d2 DONE in the table and sequencing with a pointer to refresh-policy.md's publish-on-call §3 (the mechanism differs from the doc's proposed ioctl-delay: it is a driver-side drain, not a userspace timing heuristic).
- **[wrong] `doc/power-management.md:22`** — The 2026-08-06 summary declares the awake row 'closed as far as software can take it' with 163.1 mA as an 'irreducible static floor', which the same doc contradicts 170 lines later with two measured software levers (~30 mA vdd_cpu, ~24.8 mA DDR) off that same floor.
  - *Recommendation:* Rewrite the 2026-08-06 summary note: the peripheral teardown closed the switch-things-off half, but the 'irreducible' claim was falsified the same day; state the current ledger (163 floor minus ~17 realized vdd_cpu minus ~25 DDR).
- **[stale] `doc/power-management.md:172`** — The DDR DVFS 'Linux-side integration plan' is stale: the driver landed the same day (wilkbook_dmc + input-driven boost policy, after the doc's last edit), and the 'design doc' whose static-low architecture it cites does not exist anywhere in the repo.
  - *Recommendation:* Replace the 'plan' sentence with the landed design (dmc driver, boost-on-input policy, service names) and either check in the design doc or point at pinenote/tools/ddr-dvfs-test/{procedure,protocol}.md.
- **[wrong] `doc/power-management.md:351`** — The documented suspend gate rejects CPU idle-state DT nodes, but the shipped kernel now adds them (hardware-proven with deep suspend 4/4), so the doc's own 'against a built image' gate invocation fails against the current build with no explanation.
  - *Recommendation:* Reconcile gate and kernel (update inspect-pinenote-suspend-gates.sh to accept the reviewed CPU_SLEEP node), then update the doc's gate description; until then add a note that the built-DTB invocation is expected to fail on idle-states.
- **[structure] `doc/power-management.md:3`** — The doc's framing prevents distinguishing measured-on-hardware from planned: the opening still calls it 'the first, read-only power-management slice', and present-tense standing rules deep in the doc ('the first actual suspend remains outside this slice', 'nothing suspends until the qualification ladder says so') contradict the dated results at the top.
  - *Recommendation:* Replace the opening with a current-state abstract (what is hardware-proven, what is planned, date), and sweep the present-tense 'standing rule' sentences: either retire them or date-scope them as historical.
- **[privacy] `doc/status.md:2151`** — The home Wi-Fi SSID `<home-ssid>` is committed in doc/status.md and in at least two commit messages — geolocatable via wardriving databases (WiGLE) and squarely in the review's 'embarrassing to share' class.
  - *Recommendation:* Fine for the trusted collaborator. Before public: replace the SSID with `<home-ssid>` in doc/status.md, and decide now whether to rewrite history (cheapest before the collaborator has clones) or accept the residual in old blobs and commit messages.
- **[stale] `doc/status.md:3`** — The declared single source of hardware truth is missing every hardware session after 2026-08-03: the entire awake-power/DDR/cpuidle program of 2026-08-05/06 exists only in doc/power-management.md and doc/artifacts/, and status.md's power numbers are superseded.
  - *Recommendation:* Backfill dated entries for the 2026-08-05 and 2026-08-06 sessions (or add an explicit pointer entry stating that power-program hardware truth continues in doc/power-management.md and the awake-levers artifact), and bump 'Last updated', before the collaborator relies on it.
- **[structure] `doc/status.md:1`** — A new reader cannot learn 'where the project is today' in 5 minutes: 2742 lines with no current-state summary, the newest-first ordering is never stated, the only section titled 'Summary' is a mid-July parity table, and entry styles are mixed so there is no usable TOC.
  - *Recommendation:* Before sharing: add a ~20-line dated 'Current state' header (what is proven, what is on os2, current power numbers, next action) plus one line stating 'entries below are newest-first; sections after the Summary table are historical'; retitle '## Summary' to something like '## 6.6-vs-7.0 parity (historical, 2026-07)'.
- **[stale] `doc/status.md:1989`** — The '## Current os2 contents' section — the only heading promising current device state — is three deployments stale and contradicts the top of its own file, claiming a 2026-07-28 image that 'has not booted' and that 'suspend remains disabled'.
  - *Recommendation:* Update the section to the current os2 image (or replace its body with 'see the newest deploy entry at the top of this file') so the heading can never silently rot again.
- **[stale] `doc/upstream-register.md:183`** — Item 7's verification state is three days and two register commits behind hardware truth: the fix it calls 'built but unproven on glass' was hardware-proven on 2026-08-02, and the same session measured that finding 1 (G1) was NOT what the device hit — the dead-write window was substantially the probe's own black-on-black no-op writes.
  - *Recommendation:* Rewrite item 7's status: condition (1) is discharged with a nuanced answer (fix proven on glass; the device symptom was reattributed to no-op probes plus the resume damage-baseline defect). The two core-DRM source findings (unawaited resume_work, discarded -EBUSY) survive as mainline observations, but the row should say the local motivation weakened and re-scope what remains to verify (drm-misc-next check plus baseline gate).

### Minor

- **[portability] `CLAUDE.md:96`** — CLAUDE.md:96 points to 'the agent's memory' — dead for a collaborator — but doc/device-runbook.md:104-158 already documents the os1 SSH access conventions (host/IP, user, host-key note, safe read-only ops); only the pointer and the chroot recipe are missing from the repo.
  - *Recommendation:* Move the standing conventions out of agent memory into doc/device-runbook.md (the device access/inventory doc): read-only oracle rules, the post-mortem /var/log/messages harvest procedure, and the chroot test recipe. Change CLAUDE.md:96 to point only at repo files.
- **[wrong] `CLAUDE.md:123`** — The status dump's header date '(2026-08-01)' is internally wrong — the section itself contains 2026-08-02 hardware results and a 2026-08-04 harness update, so even its staleness is mislabeled.
  - *Recommendation:* Update the header date whenever the section is touched (or drop the date and rely on the pointer to doc/status.md's own 'Last updated' line, per the blocker finding's restructure).
- **[stale] `CLAUDE.md:87`** — The forward-port-patch gate lists only three host suites, omitting `make suspend-check`, whose structural gates over the TPS65185 PM hunk and the fbdev resume barrier are — per testing.md itself — the only behavioral check for patch code behind undefined config guards.
  - *Recommendation:* Update CLAUDE.md:87 and worked-examples case study 3 step 5 to add `suspend-check` (or to reference testing.md's rung-1 list as the authoritative gate set) so the first-change path matches the current ladder.
- **[structure] `CLAUDE.md:127`** — The onboarding path uses project jargon before or without any definition — 'final4', 'ABBAs', 'wash', and 'os1 oracle' at first use — and 'final4' and 'ABBA' are never defined anywhere in the repo.
  - *Recommendation:* Add a 6-8 line glossary to CLAUDE.md (os1/os2 slots, oracle, wash, ABBA, rung, final4/quirk:) or expand each term at first use; cheap fix that removes the biggest cold-start friction in an otherwise well-linked doc set.
- **[missing] `CLAUDE.md:40`** — The doc map omits 7 of 22 docs (including the actively updated doc/power-management.md) and the archive/artifacts/datasets subtrees, though all are reachable via CLAUDE.md:235, ROADMAP/testing.md cross-references, or ls doc/.
  - *Recommendation:* Add the seven docs and the three doc/ subtrees to the doc map with one-line descriptions; power-management.md especially, since the active program lives there.
- **[wrong] `LICENSE:1`** — Blanket AGPL-3.0 LICENSE with no per-component licensing statement anywhere in the repo; kernel-derived patch content is GPL-2.0 per its own SPDX headers and vendored KOReader Lua is upstream AGPL-3.0 — needs a README Licensing section before public sharing, but low-stakes for one trusted collaborator.
  - *Recommendation:* Add a 'Licensing' section to README.md: channel/tools code AGPL-3.0; pinenote/patches/* kernel-derived, GPL-2.0 per the in-patch SPDX headers; vendored/verbatim KOReader Lua under upstream AGPL-3.0. Low stakes for one trusted collaborator, but must be fixed before any public sharing.
- **[stale] `README.md:61`** — README (5) and CLAUDE.md (3) enumerate a fraction of the 12 pinenote/tools/ dirs; doc/testing.md itself lists only 8 (missing optics, ebc-damage-probe, ddr-sip-probe, ddr-dvfs-test)
  - *Recommendation:* Update both lists to name all 12 tools or, better, stop enumerating and point at doc/testing.md's table — then keep that table complete (see the testing.md finding).
- **[structure] `README.md:63`** — doc/artifacts/ (~804K, hardware-session evidence) and doc/datasets/ (~1.4M optics dataset) are committed — 191 files — but explained in no map: README's Layout mentions only `archive/`, CLAUDE.md's doc map neither, and doc/artifacts/ has no top-level index.
  - *Recommendation:* Add both trees to README Layout and the CLAUDE.md doc map (one line each: 'committed hardware-session evidence' / 'committed derived optics dataset'), and add a short doc/artifacts/README.md indexing the loose files and naming convention.
- **[structure] `README.md:63`** — README's doc list omits several current docs (networking.md, refresh-policy.md, power-management.md, upstream-register.md, worked-examples.md, eink-sota.md, pageturn-program.md, optics-dataset-2026-07.md, hrdl-evaluation.md)
- **[wrong] `README.md:45`** — Both onboarding files count 'two kernel packages' while pinenote/packages/kernel.scm defines three — linux-pinenote-debug is missing, though the Makefile builds it via the reader-debug flavor (the same defect already confirmed for doc/kernel-forward-port.md exists in the two files every newcomer reads first).
  - *Recommendation:* Fix the count in both files when they get their already-flagged rewrites; name linux-pinenote-debug and its reader-debug purpose so a collaborator grepping kernel.scm isn't surprised by an undocumented third kernel.
- **[structure] `README.md:63`** — No doc gives the human collaborator a task-ordered onboarding path (host setup → build reader → device provisioning → deploy): README points into doc/ via testing.md/kernel-forward-port.md and defers to CLAUDE.md, whose CLAUDE→ROADMAP→status.md sequence is explicitly agent-addressed and fronts ~3,400 lines before any build or deploy instruction.
  - *Recommendation:* Add a short 'New here? Do this in order' list to README.md for the human collaborator (host setup → build reader → device provisioning/backups → deploy → then the philosophy docs), and make CLAUDE.md's sequence explicitly the agent-context path rather than the contributor path.
- **[stale] `ROADMAP.md:62`** — An open ROADMAP checkbox asks for work already done (usb-console flavors are in the pinenote-flavors table), while the flavors table itself now omits the reader-debug flavor that the Makefile builds.
  - *Recommendation:* Split the checkbox: tick the 'add usb-console flavors' half, keep 're-measure closure sizes' open; add a reader-debug row to doc/pinenote-flavors.md noting it is the EXTRACT_FBS diagnostic-kernel variant.
- **[structure] `ROADMAP.md`** — ROADMAP declares 'this file is direction, not status' yet section 4's suspend/barrier and awake-power bullets carry ~60-70 lines of dated status prose duplicating doc/status.md, creating a third sync point whose drift finding #1 demonstrates.
- **[stale] `doc/building.md:28`** — building.md's examples and 'validated primary' sentence steer to usb-console and never mention the reader flavor, the current deploy target — though the sentence is literally true and line 12 links the flavor matrix that names reader.
  - *Recommendation:* Point the flavor examples and the 'validated primary' sentence at the reader flavor; keep usb-console as the bring-up/debug fallback.
- **[portability] `doc/building.md:4`** — The canonical artifact root is /tmp/opencode — a volatile tmpdir named after a previous coding tool — documented as the doc's contract and hardcoded as the Makefile default, and the qemu-virt recipes hardcode it even when ARTIFACTS is overridden, so rootfs artifacts a deploy later references can vanish on any host reboot.
  - *Recommendation:* Move the default to a gitignored repo-local artifacts/ directory (or XDG cache), make the qemu recipes honor $(ARTIFACTS), and update building.md; at minimum add a note telling the collaborator to set ARTIFACTS and that /tmp contents do not survive a reboot.
- **[portability] `doc/building.md`** — channels.scm is consumed by nothing in the build path — every make target calls the operator's ambient `guix` directly and no doc or Makefile ever invokes `guix time-machine -C channels.scm` or tells the collaborator to pull with the repo's channel file — so even fixing the confirmed unpinned-channels finding by pinning channels.scm would not change what `make reader` actually builds against.
  - *Recommendation:* When pinning channels, also wire the pin into the workflow: document (or add a Makefile variable for) `guix time-machine -C channels.scm -- system build …`, or state explicitly in doc/building.md that builds use the ambient `guix pull` generation and record which generation validated each image.
- **[portability] `doc/building.md`** — Every hardware-validated reader image includes non-redistributable, personally-licensed MB Type fonts staged from a gitignored directory, so a collaborator's fresh-clone build silently produces a typographically different image from everything status.md validated — and the mechanism is documented only in pinenote/fonts/README.md, which no doc map, build doc, or flavor doc references.
  - *Recommendation:* Add one sentence to doc/building.md (and the reader row of doc/pinenote-flavors.md) pointing at pinenote/fonts/README.md: fonts under pinenote/fonts/local/ are optional, never committed, and absent on a fresh clone — KOReader falls back to its bundled Noto fonts, so the collaborator's image will differ visually from the validated sessions.
- **[privacy] `doc/device-runbook.md:10`** — Personal-environment details are embedded across the docs — home-LAN IPs (<lan-ip>/.143/.144/.145 in 7+ docs and commit messages), the home Wi-Fi SSID `<home-ssid>` (doc/status.md:2145,2151), /home/wkelly paths in 24 tracked files (including all optics-dataset JSON bundle_path fields and two guix.scm example commands), the personal NFS host `nastyboy` (device-runbook.md:40,61), and device SSH host-key fingerprints (status.md:1184,1215,1238) — no credentials or keys committed; fine for one trusted collaborator, scrub before wider sharing.
  - *Recommendation:* Fine for the single trusted collaborator; before wider sharing, replace literal LAN IPs with a placeholder convention (e.g. $PINENOTE_HOST, as doc/power-management.md:848 already does with root@PINENOTE) and generalize the backup-root paths. Doubles as the portability fix for finding 6.
- **[stale] `doc/driver-findings-report.md:999`** — The 2026-08-01 suspend-ctx finding says the in-tree worker-bracket fix is pinned only by a host regression, but it passed on hardware the next day (suspend ladder rungs 1–2 on s2idle, panel recovered without reboot) — the community report understates the fix's proof status.
  - *Recommendation:* Append one dated sentence to the finding recording the 2026-08-02 hardware proof — it materially strengthens the community report.
- **[wrong] `doc/driver-findings-report.md:131`** — The cross-reference "pinenote/tools/ebc-logic/README.md (Findings a–c)" is broken: the README's findings section uses numbered findings 1–6+, with no lettered labels.
  - *Recommendation:* Update the reference to the README's current numbering (findings 1–2 for the report's 5–7 section).
- **[stale] `doc/eink-research.md:150`** — The §5 KOReader paragraph reads as if KOReader on wilkbook is future work ('proven on PineNote via hrdl's image', 'long-term, a native framebuffer target would give...'), but KOReader has run on wilkbook's own image since 2026-07-04 with a pinenote device target that is now hardware-proven with pen/finger input and publish-on-call refresh.
  - *Recommendation:* Add a one-line annotation (the doc's own convention, cf. the §2 frame-clock note and §8's 2026-07-12 EXTRACT_FBS correction): KOReader landed on wilkbook 2026-07-04; the fbdev + publish-on-call device target is the shipped design; the DRM-native framebuffer_rockchip.lua remains an open long-term idea. Easy workaround exists (status.md is authoritative), hence minor.
- **[portability] `doc/hardware-deploy.md:12`** — Session preconditions hardcode the author's LAN address and UART device node as if universal, so a collaborator cannot satisfy the stated preconditions verbatim on their own network or host.
  - *Recommendation:* Parameterize as <os1-ip> / <uart-dev> with a short note on discovering the device's address and pinning the lease; keep the author's concrete values in the device-runbook ledger instead.
- **[stale] `doc/hrdl-evaluation.md:441`** — Not an archive candidate — other current docs cite it as standing strategy — but §5 frames the corruption hunt in the present tense as the active track, while no status.md entry newer than 2026-07-12 touches the hunt and the outcome of the landed finding-2 fix's promised corruption A/B is recorded nowhere.
  - *Recommendation:* Keep in doc/ (do not archive; four docs link into it and §3.3 is cited as current strategy). Add one dated note to §5: the hunt has been dormant since 2026-07-12, the finding-2 fix has been deployed since A.2.8-dbg, and whether corruption recurred on the fixed kernel is the open question — pointing at status.md for currency. The 'Status: evaluation complete, 2026-07-12' header already dates the rest correctly.
- **[stale] `doc/kernel-forward-port.md:450`** — The pinned-quirks section still says the host tools 'surfaced seven latent issues' (as-of 2026-07-04), but the ebc-logic README it defers to now records nine findings — including the hardware-found 2026-07-29 refresh-starvation hang — so the refresh checklist ('check whether their trees already fix any of these before re-pinning') omits the newest pinned quirks.
  - *Recommendation:* Update the count and add the starvation finding (it is exactly the class a rebase must re-check against hrdl/ayakael trees); state explicitly that numbering follows doc/driver-findings-report.md, or drop local numbers and cite the report's.
- **[missing] `doc/kernel-forward-port.md:223`** — The per-refresh record ROADMAP promises to keep in this doc (base version, conflicts, config deltas) does not exist, and the doc never plainly states the current base kernel version the patches apply to.
  - *Recommendation:* Add a short 'Refresh record' section stating the current base (7.0.11, nonguix linux) and start logging refreshes there; the ROADMAP checkbox is unchecked so this is a known debt, but it should be paid before a second person starts refreshing patches.
- **[portability] `doc/kernel-forward-port.md:256`** — The canonical BSP-patch regeneration recipe hardcodes a session-scratch worktree path from the author's machine and never documents how to construct that applied worktree, making the recipe unrunnable as written for the collaborator.
  - *Recommendation:* Replace the literal path with a placeholder and add one sentence on constructing the worktree (vanilla 7.0.11 checkout at 5e2c0c5659cc with the BSP edits applied on top).
- **[archive-candidate] `doc/koreader-spike.md`** — The doc is a completed spike/decision record (first light 2026-07-05, last hardware update 2026-07-19) whose enduring content is the §3 cage/SDL dead-end; it fits the doc/archive/ convention once §4/§5 are superseded.
  - *Recommendation:* Two acceptable moves: (a) keep in doc/ but fix §4/§5 (see the stale finding) so it remains an honest live reference for pinenote-flavors.md; or (b) move to doc/archive/ with an archive/README.md entry preserving §3's do-not-retry conclusion, and repoint pinenote-flavors.md:14 at doc/refresh-policy.md + doc/status.md. Do not archive without doing one of these — §3 is the only record of why the SDL/Wayland path is structurally impossible.
- **[wrong] `doc/optics-dataset-2026-07.md:448`** — §5.3 (and §3.7) direct third-party auditors to the superseded refresh_threshold reading as authoritative — "whole screen-areas, ~every 60 turns" — but that correction was itself over-corrected on 2026-07-12: units are pixels against a half-panel constant, so threshold 60 fires ~every 30 turns.
  - *Recommendation:* Add a short dated note to §3.7 and §5.3: the units question was re-resolved 2026-07-12 (pixels / half-panel / ~30 turns); the authoritative statement is refresh-policy.md's Context bullet and pageturn-program.md ground truth 7, not finding 8 / commit 3610f49. Without it, a collaborator auditing the dataset adopts the wrong driver-parameter semantics.
- **[missing] `doc/optics-dataset-2026-07.md:547`** — The evidence behind refresh-policy findings 11-13 (idlewasher-accept*, veritas bundles) and the finding-12 v3 reports exists only in the gitignored build/bundles on Will's capture workstation — the committed dataset stops at armB (no report), so the new collaborator cannot audit any post-catalog finding from the repo.
  - *Recommendation:* Before sharing, either run the promised dataset refresh (fold in armB report, armB2, armC, idlewasher-accept*, veritas, and the v3 reports) or add one sentence to the addendum stating plainly that findings 10-13's derived files are workstation-only and reproducible from the videos on request. The doc's opening framing as a point-in-time third-party review guide is otherwise exactly right and it should stay in doc/ (not archive) as the audit companion to the committed doc/datasets/ tree.
- **[stale] `doc/pageturn-program.md:360`** — Internal contradiction: §3.3 sequencing still schedules e2 ("piggyback on any session, with the ×1.25 caveat recorded") while the ranked table three paragraphs earlier marks e2 REJECTED as a no-op on this kernel.
  - *Recommendation:* Delete item 5 from the §3.3 sequencing list (or mark it "retired 2026-07-30, see table").
- **[stale] `doc/pinenote-flavors.md:14`** — Flavor table omits reader-debug and the reader row's "usb-console plus KOReader" misstates composition (no ttyS2 auto-login getty; adds Wi-Fi/dhcpcd/key-only SSH, noted only in the Notes section); closure-size staleness is already self-hedged in-doc and tracked in ROADMAP.md.
  - *Recommendation:* Re-measure closures for the current flavor set (at least reader), add a reader-debug row flagged temporary per the Makefile comment ("remove with the debug patch when done"), and correct the reader row to state its real composition (no ttyS2 auto-login getty, plus Wi-Fi/dhcpcd/key-only SSH).
- **[missing] `doc/power-management.md:479`** — The qualification-ladder section is stale — it ends at the 2026-08-01 rung-2 FAIL with 'Deep untested by rule' and a pending retry that has since run and passed; the outcome is recorded in doc/status.md:116-156 and three committed artifact dirs, so it is discoverable, but the section's closing text now misstates history.
  - *Recommendation:* Append the 2026-08-02 ladder session (rung 2 PASS, rung 3 hang→activation→PASS, cfg 0x0 vs 0x5ec table) to the ladder section so the procedure and its outcome live together.
- **[missing] `doc/power-management.md:179`** — Deep-suspend draw appears as both 19.3 mA (:20, :70) and 20.6 mA (:179) without a dated reconciliation; the 2026-08-06 audit's conclusions live in the committed awake-levers artifact README, which the doc already cites.
  - *Recommendation:* Fold Addendum 2 of the awake-levers artifact into the doc: adopt 20.6 mA as the current rail-floor number (noting 19.3 was the 2026-08-02 A/B), and record the peripherals-exonerated and driver-unbind-skips-suspend-hook findings where the ultra-suspend/rail-kill program is discussed.
- **[stale] `doc/power-management.md:19`** — The targets table's awake-floor figure (171.6 mA, 23.3 h) is superseded by the accepted vdd_cpu auto-PFM boot: settled reader idle is now 156.9 mA (~25.5 h), a number the doc itself quotes later without updating the table.
  - *Recommendation:* Refresh the table's measured column with the 2026-08-06 realized numbers and a date, keeping the (unchanged) verdicts.
- **[stale] `doc/refresh-policy.md:733`** — The "Rollout precisely" paragraph still asserts "The single-pass portrait page turn itself is unproven on glass until the sweep session runs…" two paragraphs after the doc records that exact proof (8/8 single-pass, 2026-08-01).
  - *Recommendation:* Rewrite the rollout paragraph in past tense or strike the "unproven on glass" sentence with a "(proven above, 2026-08-01)" note; keep the drain-broken diagnostic signature, which is still useful.
- **[stale] `doc/refresh-policy.md:290`** — The "Open questions (updated)" block still poses the deep-clean-action trigger design and "harvest next hardware session" as open, but both were answered later in the same document (finding 11's on-glass-validated idle-washer owns the deep-clean cadence; the 2026-07-11 optics campaign did the harvests).
  - *Recommendation:* Date-stamp the block "(as of 2026-07-05)" or prune the answered bullets with pointers to findings 11-13. In a 1000-line append-only doc a mid-file 'open questions' list that is no longer open is a trap for a new reader.
- **[privacy] `doc/status.md`** — The PineNote's real Wi-Fi MAC address (<device-mac>) survives in three historical doc/status.md blobs even though it was deliberately scrubbed from the tree on 2026-07-11.
  - *Recommendation:* Fine for the trusted collaborator. If the repo goes public, honoring the existing scrub intent requires a history rewrite (git filter-repo) or an explicit decision to accept the residual; bundle this with the SSID commit-message rewrite decision.
- **[stale] `doc/status.md:745`** — The retracted 'UART receives nothing from ttyS2 (verified)' claim in the 2026-08-01 entry is left standing with no in-place supersession marker, although the doc applies such markers elsewhere.
  - *Recommendation:* Add an in-place bracket at :745, e.g. "[RETRACTED 2026-08-02 — test artifact; UART works at 1500000, see the 2026-08-02 rung-3 entry]", matching the convention used on the 2026-07-29 entry.
- **[stale] `doc/status.md:2714`** — '## Next sessions' is a stale mid-July action list ('no corrective device session is queued') that no longer reflects the queued work stated at the top of the file or in the power program.
  - *Recommendation:* Refresh the section to the actual queue (unplugged soak, DDR DVFS integration per power-management.md) or delete it and point at ROADMAP.md; a truth doc should not carry a stale next-actions list.
- **[stale] `doc/testing.md:51`** — testing.md's host-tools table omits 4 of 12 pinenote/tools entries (optics — despite optics-check being in its own rung-1 command — plus device-side ebc-damage-probe, ddr-dvfs-test, ddr-sip-probe), and ddr-dvfs-test lacks the README.md line 71 promises.
  - *Recommendation:* Add table rows for optics, ebc-damage-probe, ddr-dvfs-test, and ddr-sip-probe (the last two are device-side/supervised, which the table should say), and give ddr-dvfs-test a README.md or amend the blanket claim.
- **[structure] `doc/testing.md:58`** — The host-tool table's 'Ladder rung' column mixes two numbering schemes, and neither matches the validation ladder defined later in the same document.
  - *Recommendation:* Pick one scheme: either drop the column (the table already has a Run column), or relabel it 'ROADMAP §3 rung' and leave it blank for tools not in that ladder.
- **[structure] `doc/testing.md:138`** — There is no aggregate make target for the full host suite; the only 'run everything green' record is the hand-enumerated 11-target command inside rung 1's prose, which must be kept in sync with the Makefile by hand.
  - *Recommendation:* Add a `check-host` (or `check`) aggregate target to the Makefile and have testing.md's rung 1 reference it; add an optics row to the host-tool table. Answer to the review question: yes, testing.md does give one runnable command today, but only as transcribable prose.
- **[stale] `doc/upstream-register.md:103`** — Item 3 (deferred-io flush period) still frames the knob as an unbuilt technique note, but since 2026-07-31/08-01 our tree implements it as the `defio_delay_ms` module parameter with a hardware-proven result (portrait double-refresh fixed, 8/8 single-pass turns) — the row hasn't recorded that the offer to hrdl now comes with an implementation and measured numbers.
  - *Recommendation:* Update item 3: the technique note is now backed by an in-tree implementation and a hardware-measured UX win; that changes its value and readiness (arguably 'ready' as a footnote to item 1).
- **[stale] `doc/worked-examples.md:137`** — Case study 3's gate list for forward-port patch edits omits the patch-coupled structural gates added since July: `make suspend-check` validates specific patch hunks and the host tools cannot see config-guarded code.
  - *Recommendation:* Add `make suspend-check` (the patch structural gates) to step 5 of case study 3 and cross-reference testing.md's #ifdef caveat. The rest of the doc is current and replayable.
- **[privacy] `pinenote/systems/pinenote-reader.scm:139`** — The reader flavor hardcodes Will's personal SSH public key (wkelly@pop-os) as the only root authorized key; a collaborator building the flavor verbatim gets an image only Will can SSH into. Not a secret leak, and doc/networking.md's own sketch (line 281) acknowledges the inline-key variant with a 'better: read /state' note — parameterize (read from /state or a gitignored local file) before wider sharing.
  - *Recommendation:* Parameterize before sharing: read the authorized key from the data partition per networking.md's own design, or from a gitignored local file (the pinenote/fonts/local/ idiom). Fine for the trusted collaborator if flagged; fix before public.

### Nit

- **[privacy] `.gitignore:1`** — Verified clean (auditor's negative results, for the synthesis): no Wi-Fi PSK/passphrase, no private key, no token/API key, no waveform binary, and no >500KB blob exists anywhere in the working tree OR the full 1,201-blob git object history; all six tool build/ dirs are gitignored and WBF is only ever an external make variable.
  - *Recommendation:* No action. Safe to share with the collaborator today from a secrets standpoint; the public-release checklist is only the SSID/MAC/IP/pubkey items above.
- **[portability] `doc/device-runbook.md:89`** — The ledger's pointer to the 2026-07-25 firmware-comparison extraction lives under volatile /tmp, so the referenced owner-only evidence disappears on the next host reboot despite being cited as the durable record of the BSP-ATF byte-identity result.
  - *Recommendation:* Copy the text manifest and SHA list into the durable backup roots alongside the 2026-05-08/2026-05-10 sets and update the pointer; the binaries stay uncommitted per policy.
- **[stale] `doc/driver-findings-report.md:849`** — The starvation finding's patch line references have drifted after the 2026-08-01+ patch edits: EBC_FRAME_TIMEOUT is defined at patch:2980 (not 2981) and used at patch:4434 (not 4289), a 145-line drift a community reader following the refs will hit.
  - *Recommendation:* Refresh the patch line refs (or switch to function-relative references, which the doc already uses elsewhere and which survive rebases).
- **[stale] `doc/driver-findings-report.md:3`** — The report's header still reads "Status: draft, 2026-07-04" and the register's item 1 describes it as "Seven latent driver issues", though the document now spans roughly a dozen findings through 2026-08-01 including the flagship starvation finding — underselling the doc a collaborator lands on.
  - *Recommendation:* Bump the header date/status line and reword register item 1's headline to reflect the current scope (host-suite findings plus live hardware findings).
- **[stale] `doc/eink-sota.md:691`** — §3 says EXTRACT_FBS 'is stubbed in our 7.0 kernel' with an 'once ported' framing, while the pointer it cites records the port as LANDED the same day in the debug kernel — internally confusing though not strictly false.
  - *Recommendation:* Reword to 'stubbed in the primary kernel; ported in linux-pinenote-debug 2026-07-12 (pageturn-program §5.2)'. One-line fix.

## Appendix B: refuted findings (30)

Killed by the skeptic-verification pass (mostly cross-agent duplicates; a few false claims):

- `README.md` — README is a month stale: it presents usb-console as the thing to build and KOReader as future work, while the reader flavor is the deployed product, so a new pe
  - *Refutation:* duplicate of #1 (status/quick-start staleness) plus duplicate of #2 (tools list); #1 carries the stronger, fully verified evidence chain.
- `README.md` — README's doc list omits doc/worked-examples.md, which CLAUDE.md designates as required reading before a first non-trivial change; a human collaborator scanning 
  - *Refutation:* duplicate of #8 — worked-examples.md is one of the docs #8's broader omission finding already covers, and README:67-68's 'read CLAUDE.md first' chain reaches it.
- `README.md` — The Status section is headed '(2026-07)', stops at the 2026-07-04 kernel-parity milestone, and presents the reader as future work ('eventually a reading-first d
  - *Refutation:* duplicate of #1.
- `README.md` — Quick start presents 'make rootfs-usb-console' as the validated primary and never mentions the reader flavor ('make rootfs-reader'), which is the actual product
  - *Refutation:* duplicate of #1, which already includes the quick-start/rootfs-reader evidence.
- `README.md` — The tools list names only wbf, ebc-logic, rastersim, orientation, koreader-input — omitting 7 of the 12 actual pinenote/tools/ directories (ddr-dvfs-test, ddr-s
  - *Refutation:* duplicate of #2.
- `README.md` — doc/artifacts/ and doc/datasets/ directories exist but are not mentioned in README's Layout or CLAUDE.md's doc map; unclear to a new person what they are and wh
  - *Refutation:* duplicate of #3.
- `CLAUDE.md` — CLAUDE.md — which README tells contributors to read first — asserts suspend is disabled and any suspend attempt is far off, the opposite of the recorded hardwar
  - *Refutation:* duplicate of #2, which carries the same contradiction plus the commit-postdates-truth fact and the ssh-intermittency hazard.
- `CLAUDE.md` — CLAUDE.md points new agents at 'the agent's memory' for the standing device-access conventions — a file on the author's machine that does not ship with the repo
  - *Refutation:* duplicate of #3.
- `CLAUDE.md` — The doc map — the index a new agent navigates by — omits 7 of the 22 docs, including doc/power-management.md, the most recently updated doc in the repo and the 
  - *Refutation:* duplicate of #11.
- `CLAUDE.md` — The agent-onboarding file's 'Where we are' section states deep suspend hangs and suspend is disabled, contradicting the declared source of truth which records d
  - *Refutation:* duplicate of #2.
- `CLAUDE.md` — CLAUDE.md's 'Where we are' asserts deep suspend hangs and suspend is deliberately disabled, directly contradicting status.md's hardware-proven rung-3 PASS and l
  - *Refutation:* duplicate of #2.
- `CLAUDE.md` — CLAUDE.md's 'Where we are' still claims suspend is deliberately disabled, activation hard-off, and rung 3 hung at bl31 cfg 0x0 — all overturned on 2026-08-02 wh
  - *Refutation:* duplicate of #2.
- `CLAUDE.md` — The 'Doc map' omits power-management.md (which CLAUDE.md itself cites elsewhere), eink-sota.md, pageturn-program.md, optics-dataset-2026-07.md, hrdl-evaluation.
  - *Refutation:* duplicate of #11.
- `CLAUDE.md` — Committing section says 'Single-user repo; commit and push to main freely' — false the moment a second person joins; no collaboration/review/status-update conve
  - *Refutation:* duplicate of #4.
- `CLAUDE.md` — The os1-oracle section says the standing device-access conventions live 'in the agent's memory' — a new contributor's agent has no such memory; the conventions 
  - *Refutation:* duplicate of #3.
- `CLAUDE.md` — 'Where we are (2026-08-01)' header predates content inside it (2026-08-02 suspend rungs, 2026-08-04 fbdev test note) and the section has grown into a second sta
  - *Refutation:* duplicate of #6 (the date defect) with its second-status-page point already covered by #2's restructure recommendation.
- `doc/status.md` — The declared single source of hardware truth is three-plus hardware sessions behind: the 2026-08-05/06 cpuidle, vdd_cpu auto-PFM, and DDR-DVFS device results li
  - *Refutation:* duplicate of #3, which carries the stronger and fully verified evidence (superseded power figures, per-commit --stat checks).
- `ROADMAP.md` — ROADMAP's suspend-program item — doc #2 in the recommended reading order — still states activation is disabled and forbids idle autosuspend, both reversed on ha
  - *Refutation:* duplicate of #1
- `doc/testing.md` — The host-tool inventory table omits three real tools — ebc-damage-probe (used by deployed campaign procedures) and the 2026-08-05/06 ddr-sip-probe / ddr-dvfs-te
  - *Refutation:* duplicate of #1 — same table-omission defect, and #1 is the stronger phrasing (adds optics, which is genuinely a host tool wired into the rung-1 command, plus the README claim).
- `doc/testing.md` — Only two of the three 2026-08 instrument-correction lessons made it into testing.md: the no-op-write lesson (a zero IRQ delta means nothing when the written con
  - *Refutation:* Category is 'missing' and the content exists discoverably: doc/status.md:217-223 records the no-op-write/fb-rows-changed lesson in full (status.md is the designated source of hardware truth) and CLAUD
- `doc/ebc-harness-spike.md` — Three completed spike/evaluation docs sit in doc/ despite the repo having doc/archive/ for exactly this: ebc-harness-spike.md, hrdl-evaluation.md, and koreader-
  - *Refutation:* The 'concluded and superseded' premise is false: hrdl-evaluation.md §3.3 is 'the standing strategy' (doc/upstream-register.md:372), ebc-harness-spike.md is the build plan for ROADMAP rung 7(b) which i
- `doc/ebc-harness-spike.md` — A fulfilled 2026-07-04 scoping spike (option (a) built the same day, per its own banner) that is nonetheless still cited as live normative reference — its §2 re
  - *Refutation:* Not a defect: the finding itself verifies the doc is honest (same-day banner confirmed at lines 3-7), all five live citations are real (ebc-logic README:12/176/262, testing.md:135, ROADMAP:148, worked
- `doc/device-runbook.md` — Home-network details are scattered through the docs: the author's LAN IPs and a personal NFS path ('nastyboy') — harmless for one trusted collaborator, but wort
  - *Refutation:* duplicate of #2 — same IPs (runbook:10,40) and nastyboy NFS path, same tier and recommendation, with less coverage than #2.
- `doc/device-runbook.md` — There is no 'bring up YOUR device' path: the runbook is Will's single-device ledger (his VCOM, his backups on his home dir and NFS, his DHCP lease), and no doc 
  - *Refutation:* duplicate of #7 — same missing-onboarding claim over the same evidence (runbook:39-40,103, testing.md:127); #7 is stronger because it also pins the hardware-deploy.md:10-13 precondition dependency and
- `doc/device-runbook.md` — Committed docs and artifacts expose home-LAN IP addresses but no credentials; the mechanical privacy scan found no SSIDs, PSKs, passwords, or MAC addresses anyw
  - *Refutation:* duplicate of #2, and its central claim is false: the mechanical scan missed the committed home Wi-Fi SSID `<home-ssid>` at doc/status.md:2145 and 2151 ("Wi-Fi credentials for SSID `<home-ssid>` 
- `doc/device-runbook.md` — Home-LAN IPs of the device (<lan-ip>/.143/.144/.145) appear across seven docs plus commit messages; individually low-risk RFC1918 data, but together with 
  - *Refutation:* duplicate of #2 — its verified unique material (SSID at status.md:2151, host-key fingerprints at status.md:1184/1215/1238) is folded into #2's corrected summary, and its "historical MAC" claim is unve
- `doc/device-runbook.md` — Username and infrastructure paths leak throughout: /home/wkelly/... in 24 tracked files (including all 22 committed optics-dataset JSONs' `bundle_path`) and the
  - *Refutation:* duplicate of #2 — same privacy tier over the same runbook lines 39-40/60-61; its evidence checks out (exactly 24 tracked files match /home/wkelly, including the 22 dataset JSONs' bundle_path and both 
- `doc/device-runbook.md` — The device's per-device VCOM calibration value (1430000 uV) is committed in the runbook checklist — no privacy risk, but a new contributor may copy Will's VCOM 
  - *Refutation:* duplicate of #7 — the quoted VCOM line (runbook:103), the CLAUDE.md per-device policy, and the phase1a VCOM-read procedure (doc/archive/phase1a-bringup-plan.md:~110) all verify, but #7 cites the same 
- `LICENSE` — Repo LICENSE is AGPL-3.0, but the highest-value artifact is a Linux kernel patch (GPL-2.0 code); no per-component licensing statement found yet in README — veri
  - *Refutation:* duplicate of #0 — same defect, weaker phrasing (self-described unverified seed observation); #0 carries the confirmed evidence.
- `doc/eink-sota.md` — Correction 8 in eink-sota's register targets 'pinenote/tools/optics/README.md', a file that does not exist, so the correction can never be folded as written.
  - *Refutation:* pinenote/tools/optics/README.md exists, is git-tracked, and actively maintained (commits be43d06, 77447d5); the finding's directory listing was wrong, and the missing IEC citation is just the pending 
