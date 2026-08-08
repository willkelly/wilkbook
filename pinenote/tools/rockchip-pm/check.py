#!/usr/bin/env python3
"""Validate the production-linked, activation-hard-off Rockchip PM stack."""

import re
import sys
from pathlib import Path


PATHS = (
    "arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi",
    "arch/arm64/configs/pinenote_defconfig",
    "drivers/regulator/core.c",
    "drivers/regulator/of_regulator.c",
    "drivers/soc/rockchip/Kconfig",
    "drivers/soc/rockchip/Makefile",
    "drivers/soc/rockchip/rockchip_suspend_activate.c",
    "drivers/soc/rockchip/rockchip_suspend_backend.c",
    "drivers/soc/rockchip/rockchip_suspend_backend.h",
    "drivers/soc/rockchip/rockchip_suspend_executor.c",
    "drivers/soc/rockchip/rockchip_suspend_mode.c",
    "drivers/soc/rockchip/rockchip_suspend_model.c",
    "drivers/soc/rockchip/rockchip_suspend_model.h",
    "drivers/soc/rockchip/rockchip_suspend_of.c",
    "drivers/soc/rockchip/rockchip_suspend_of.h",
    "include/dt-bindings/suspend/rockchip-rk3568.h",
    "include/linux/regulator/consumer.h",
    "include/linux/regulator/of_regulator.h",
    "include/soc/rockchip/rockchip_legacy_sip.h",
)
NEW_PATHS = tuple(path for path in PATHS if path.startswith(
    "drivers/soc/rockchip/rockchip_suspend_")) + (
    "include/dt-bindings/suspend/rockchip-rk3568.h",
    "include/soc/rockchip/rockchip_legacy_sip.h",
)
SUSPEND_INVENTORY = {
    Path(path).name for path in NEW_PATHS
    if path.startswith("drivers/soc/rockchip/")
}
RETIRED = (
    "ROCKCHIP_LEGACY_SIP_GET_VERSION",
    "ROCKCHIP_LEGACY_SIP_GET_SIP_VERSION",
    "0x82000001",
    "0x8200000a",
    "rockchip_legacy_sip_probe_versions",
)
PATCH_REQUIREMENTS = (
    "CONFIG_ROCKCHIP_SUSPEND_MODE=y",
    "CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y",
    'config ROCKCHIP_SUSPEND_MODE_ACTIVATE\n+\tbool "Activate the Rockchip'
    ' BSP suspend-mode policy (issues SIP calls)"\n'
    "+\tdepends on ROCKCHIP_SUSPEND_MODE\n+\tdefault n",
    # The measured PineNote policy, byte-for-byte.  If a rebase changes any
    # of these three, re-run the SIP differential before touching the gate.
    "rockchip,sleep-mode-config = <0x5ec>;",
    "rockchip,wakeup-config = <0x10>;",
    "rockchip,sleep-debug-en = <0x00>;",
    "rockchip_suspend_mode_drv-y := rockchip_suspend_mode.o rockchip_suspend_of.o",
    "\trockchip_suspend_model.o rockchip_suspend_executor.o \\",
    "\trockchip_suspend_backend.o",
    "rockchip_suspend_mode_drv-$(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE) += \\",
    "\trockchip_suspend_activate.o",
    "of_regulator_get_by_node",
    "_regulator_get_common(rdev, dev, \"of-node\", NORMAL_GET)",
    "regulator_set_suspend_enable",
    "regulator_set_suspend_disable",
    "DORMANT policy core bound; activation compiled out",
    "rockchip_suspend_executor_run(&rockchip_suspend_real_ops",
    "arm_smccc_smc(ROCKCHIP_LEGACY_SIP_SUSPEND_MODE",
    "cpu_suspend(0, rockchip_suspend_psci_finish)",
    "__pa_symbol(cpu_resume)",
    "regulator_prepare_attempted = true",
    "cpu_disable_attempted = true",
    "pm_suspend_target_state != PM_SUSPEND_MEM",
    ".prepare = rockchip_suspend_prepare",
    "activation requires sleep-mode and wakeup policy",
    "depends on ARM64 && ARCH_ROCKCHIP && OF && REGULATOR && SUSPEND",
    "regulator_is_equal",
    "regulator_set_suspend_enable_save",
    "regulator_restore_suspend_enable",
    ".complete = rockchip_suspend_complete",
    "rockchip_suspend_backend_rollback",
    "count <= 0",
    "elements <= 0",
    "bank * 32U + args.args[0]",
    "get_device(&rdev->dev)",
    "put_device(&rdev->dev)",
    "rockchip_suspend_model_transaction_rollback",
    "rockchip_suspend_model_transaction_poison",
    ".suppress_bind_attrs = true",
    "builtin_platform_driver(rockchip_suspend_activate_driver)",
    # ultra-suspend firmware-handshake modeling (2026-08-01): the struct
    # member, the exactly-5 validation clause, and the build_prepare
    # override emit are each load-bearing; regulator-list selection must
    # stay derived from the real Linux state.
    "struct rockchip_suspend_model_optional suspend_state_override;",
    "input->suspend_state_override.value != 5",
    "policy->value.suspend_state_override.present ?",
)


class InvalidArtifact(ValueError):
    pass


def reject(message: str) -> None:
    raise InvalidArtifact(message)


def require(text: str, token: str, context: str) -> None:
    if token not in text:
        reject(f"{context} lacks required token: {token}")


def forbid(text: str, token: str, context: str) -> None:
    if token in text:
        reject(f"{context} contains forbidden token: {token}")


def function_body(source: str, name: str) -> str:
    match = re.search(rf"\b{re.escape(name)}\s*\([^;]*?\)\s*\{{", source,
                      re.DOTALL)
    if not match:
        reject(f"source lacks function body: {name}")
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    reject(f"source has unbalanced function body: {name}")


def decode(data: bytes, context: str) -> str:
    if b"\r" in data:
        reject(f"{context} contains CR or CRLF line endings")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InvalidArtifact(f"{context} is not UTF-8") from error


def patch_sections(patch: str) -> dict[str, str]:
    matches = list(re.finditer(
        r"^diff --git a/(\S+) b/(\S+)$", patch, re.MULTILINE))
    paths = []
    sections = {}
    for index, match in enumerate(matches):
        if match.group(1) != match.group(2):
            reject("patch has an asymmetric diff header")
        path = match.group(1)
        paths.append(path)
        end = matches[index + 1].start() if index + 1 < len(matches) else len(patch)
        sections[path] = patch[match.start():end]
    if tuple(paths) != PATHS:
        reject(f"patch path inventory/order differs: {paths}")
    for path, section in sections.items():
        index = re.search(r"^index ([0-9a-f]{40})\.\.([0-9a-f]{40})(?: \d+)?$",
                          section, re.MULTILINE)
        if not index:
            reject(f"{path} lacks canonical full-index metadata")
        if index.group(2) in {"1" * 40, "2" * 40}:
            reject(f"{path} contains a placeholder object ID")
    return sections


def extract_new_file(section: str, path: str) -> str:
    if "new file mode 100644\n" not in section:
        reject(f"{path} is not a normal non-executable new file")
    if f"--- /dev/null\n+++ b/{path}\n" not in section:
        reject(f"{path} lacks canonical new-file markers")
    lines = []
    in_hunk = False
    for line in section.splitlines():
        if line.startswith("@@ "):
            in_hunk = True
            continue
        if in_hunk and line.startswith("+"):
            lines.append(line[1:])
    return "\n".join(lines) + "\n"


def validate_model(sources: dict[str, str]) -> None:
    header = sources["drivers/soc/rockchip/rockchip_suspend_model.h"]
    model = sources["drivers/soc/rockchip/rockchip_suspend_model.c"]
    executor = sources["drivers/soc/rockchip/rockchip_suspend_executor.c"]
    legacy = sources["include/soc/rockchip/rockchip_legacy_sip.h"]
    bindings = sources["include/dt-bindings/suspend/rockchip-rk3568.h"]
    for token in (
        "ROCKCHIP_SUSPEND_MODEL_MAX_GPIOS\t9",
        "ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS\t30",
        "ROCKCHIP_SUSPEND_MODEL_PSCI_FN64_SYSTEM_SUSPEND\t0xc400000e",
        "unsigned long regulator",
        "int (*regulator_finish)(void *context)",
        "struct rockchip_suspend_model_transaction",
        "rockchip_suspend_model_transaction_rollback",
    ):
        require(header, token, "typed model header")
    for name, value in (
        ("ROCKCHIP_LEGACY_SIP_SUSPEND_MODE", "0x82000003"),
        ("ROCKCHIP_LEGACY_SUSPEND_MODE_CONFIG", "0x01"),
        ("ROCKCHIP_LEGACY_WAKEUP_SOURCE_CONFIG", "0x02"),
        ("ROCKCHIP_LEGACY_PWM_REGULATOR_CONFIG", "0x03"),
        ("ROCKCHIP_LEGACY_GPIO_POWER_CONFIG", "0x04"),
        ("ROCKCHIP_LEGACY_SUSPEND_DEBUG_ENABLE", "0x05"),
        ("ROCKCHIP_LEGACY_APIOS_SUSPEND_CONFIG", "0x06"),
        ("ROCKCHIP_LEGACY_VIRTUAL_POWEROFF", "0x07"),
        ("ROCKCHIP_LEGACY_SUSPEND_WFI_TIME_MS", "0x08"),
        ("ROCKCHIP_LEGACY_LINUX_PM_STATE", "0x09"),
    ):
        if not re.search(rf"\b{name}\b[^\n]*\b{value}\b", legacy):
            reject(f"legacy ABI differs: {name}={value}")
    for token in ("RKPM_SLP_WFI", "RKPM_USB_LINESTATE_WKUP_EN",
                  "RKPM_SLP_LDO9_ON"):
        require(bindings, token, "RK3568 suspend bindings")
    for token in (
        "ROCKCHIP_LEGACY_GPIO_POWER_CONFIG, input->gpio_count, 0xffff",
        "rockchip_suspend_model_build_prepare",
        "ROCKCHIP_SUSPEND_MODEL_REGULATOR_PREPARE",
        "ROCKCHIP_SUSPEND_MODEL_DISABLE_SECONDARY_CPUS",
        "ROCKCHIP_SUSPEND_MODEL_PSCI_SYSTEM_SUSPEND",
        "rockchip_suspend_model_transaction_begin",
        "rockchip_suspend_model_transaction_add",
        "rockchip_suspend_model_transaction_rollback",
        "transaction->restores[--retained_at]",
        "transaction->restore_count = original_count - retained_at",
        "transaction->poisoned = true",
    ):
        require(model, token, "typed sequence model")
    for token in (
        "rockchip_suspend_executor_validate_event",
        "regulator_prepare_attempted = true",
        "cpu_disable_attempted = true",
        "ops->enable_secondary_cpus(context)",
        "finish_ret = ops->regulator_finish(context)",
        "rockchip_suspend_sip_status(long status)",
        "rockchip_suspend_psci_status(long status)",
        "case -1:\n\tcase -2:\n\t\treturn -EOPNOTSUPP;",
        "case -4:\n\t\treturn -EFAULT;",
        "case -5:\n\t\treturn -EACCES;",
        "case -6:\n\t\treturn -ETIMEDOUT;",
        "case -9:",
    ):
        require(executor, token, "generic executor")
    for token in ("arm_smccc", "regulator_suspend_", "cpu_suspend(",
                  "suspend_disable_secondary_cpus"):
        forbid(model + executor, token, "host-testable model/executor")


def validate_production_sources(sources: dict[str, str]) -> None:
    validate_model(sources)
    core = sources["drivers/soc/rockchip/rockchip_suspend_mode.c"]
    parser = sources["drivers/soc/rockchip/rockchip_suspend_of.c"]
    backend = sources["drivers/soc/rockchip/rockchip_suspend_backend.c"]
    activation = sources["drivers/soc/rockchip/rockchip_suspend_activate.c"]
    kconfig = sources["drivers/soc/rockchip/Kconfig"]
    makefile = sources["drivers/soc/rockchip/Makefile"]
    defconfig = sources["arch/arm64/configs/pinenote_defconfig"]
    dts = sources["arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi"]
    regulator_core = sources["drivers/regulator/core.c"]
    regulator_c = sources["drivers/regulator/of_regulator.c"]
    consumer_h = sources["include/linux/regulator/consumer.h"]
    regulator_h = sources["include/linux/regulator/of_regulator.h"]

    # Activation is now ON for the PineNote (deep suspend requires it -- see
    # doc/artifacts/pinenote-sip-sequence-differential-20260802.md).  The
    # symbol must therefore be an EXPLICIT, promptable choice that still
    # defaults off, so no other platform picks it up silently.
    if not re.search(r'config ROCKCHIP_SUSPEND_MODE_ACTIVATE\n'
                     r'\tbool "Activate the Rockchip BSP suspend-mode policy '
                     r'\(issues SIP calls\)"\n'
                     r"\tdepends on ROCKCHIP_SUSPEND_MODE\n\tdefault n\n", kconfig):
        reject("activation Kconfig is not an explicit prompted default-n choice")
    require(kconfig,
            "depends on ARM64 && ARCH_ROCKCHIP && OF && REGULATOR && SUSPEND",
            "Rockchip suspend dependency closure")
    # The help text must keep stating the hazard and the evidence gate.
    for token in ("issue firmware SIP calls", "cfg: 0x0",
                  "verified against a known-working configuration"):
        require(kconfig, token, "activation Kconfig hazard documentation")
    for token in (
        "rockchip_suspend_mode_drv-y := rockchip_suspend_mode.o rockchip_suspend_of.o",
        "rockchip_suspend_model.o rockchip_suspend_executor.o",
        "rockchip_suspend_backend.o",
        "rockchip_suspend_mode_drv-$(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE)",
        "rockchip_suspend_activate.o",
    ):
        require(makefile, token, "Rockchip Kbuild")
    unconditional = makefile.split(
        "rockchip_suspend_mode_drv-$(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE)", 1)[0]
    forbid(unconditional, "rockchip_suspend_activate.o", "default candidate link")
    require(defconfig, "CONFIG_ROCKCHIP_SUSPEND_MODE=y\n", "PineNote defconfig")
    require(defconfig, "CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y\n",
            "PineNote defconfig activation")
    if defconfig.count("CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE") != 1:
        reject("PineNote defconfig activation setting is not unique")

    # The dormant core must still EXIST in-tree (it is what binds on any
    # platform that does not activate), even though the PineNote no longer
    # selects it.
    for token in ("rockchip_suspend_of_require_empty",
                  "DORMANT policy core bound; activation compiled out",
                  "#if !IS_ENABLED(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE)"):
        require(core, token, "dormant core retained")

    # The PineNote DT now carries EXACTLY the three properties measured from
    # os1's booted DTB -- the kernel on which deep demonstrably works on this
    # device -- and whose emitted SIP sequence is differentially verified
    # against the BSP emitter.  Exact values, not merely presence.
    for token in ("rockchip,sleep-mode-config = <0x5ec>;",
                  "rockchip,wakeup-config = <0x10>;",
                  "rockchip,sleep-debug-en = <0x00>;"):
        require(dts, token, "PineNote measured suspend policy")
    # Everything beyond those three stays out of THIS patch's DT hunk --
    # deliberately, and the reason changed on 2026-08-08.  The ultra
    # payload IS adopted now, but it lives whole in
    # linux-pinenote-7.0-ultra-rails.patch: the override and the rail
    # flips are a matched pair (either half alone is a proven-broken
    # configuration -- R10/R11 vs R12), so this pin is what prevents the
    # override from ever being reintroduced here, decoupled from the
    # rails.  validate-ultra-coupling.sh enforces the pair from the other
    # side.
    for token in ("rockchip,power-ctrl", "rockchip,regulator-on-in-",
                  "rockchip,regulator-off-in-", "rockchip,suspend-state-override",
                  "rockchip,virtual-poweroff", "rockchip,pwm-regulator-config",
                  "rockchip,apios-suspend", "-in-mem-lite", "-in-mem-ultra"):
        forbid(dts, token, "PineNote DT stays baseline-deep only")
    for token in ("rockchip_suspend_executor_run", "arm_smccc_smc",
                  "register_pm_notifier", "register_sys_off_handler",
                  "regulator_suspend_", "suspend_disable_secondary_cpus"):
        forbid(core, token, "dormant core")

    for token in (
        "for_each_property_of_node",
        "for_each_child_of_node",
        "of_count_phandle_with_args",
        "of_parse_phandle_with_args",
        "of_alias_get_id",
        "count <= 0",
        "elements <= 0",
        "(u32)alias > (U32_MAX - args.args[0]) / 32U",
        "bank = (u32)alias",
        "bank * 32U + args.args[0]",
        "of_parse_phandle(node, description->name, i)",
        "regulator = of_regulator_get_by_node(dev, provider)",
        "of_node_put(provider)",
        "return PTR_ERR(regulator)",
        "rockchip_suspend_of_put(parsed)",
        "regulator_put((struct regulator *)regulators->on[i])",
        "regulator_put((struct regulator *)regulators->off[i])",
        "regulator_is_equal(regulator",
        "unsupported policy property",
        "static bool rockchip_suspend_metadata_property",
        '!strcmp(name, "compatible") || !strcmp(name, "name") ||',
        '!strcmp(name, "status")',
        "rockchip_suspend_metadata_property(name)",
        "!rockchip_suspend_metadata_property(property->name)",
    ):
        require(parser, token, "strict OF parser")
    if parser.count("regulator_is_equal(regulator") != 2:
        reject("production parser does not check both regulator on/off identities")
    for token in (
        "class_find_device_by_of_node(&regulator_class, np)",
        "get_device(&rdev->dev)",
        "_regulator_get_common(rdev, dev, \"of-node\", NORMAL_GET)",
        "put_device(&rdev->dev)",
        "return ERR_PTR(-EINVAL)",
        "return ERR_PTR(-EPROBE_DEFER)",
        "EXPORT_SYMBOL_GPL(of_regulator_get_by_node)",
    ):
        require(regulator_c, token, "exact-node regulator provider API")
    get_by_node = function_body(regulator_c, "of_regulator_get_by_node")
    get_position = get_by_node.find("get_device(&rdev->dev)")
    common_position = get_by_node.find(
        '_regulator_get_common(rdev, dev, "of-node", NORMAL_GET)')
    put_position = get_by_node.find("put_device(&rdev->dev)")
    if min(get_position, common_position, put_position) < 0 or not (
            get_position < common_position < put_position):
        reject("exact-node provider reference transfer is not get/common/put")
    for token in ("#if IS_ENABLED(CONFIG_OF) && IS_ENABLED(CONFIG_REGULATOR)",
                  "of_regulator_get_by_node"):
        require(regulator_h, token, "public OF regulator API")
    for token in (
        "regulator_set_suspend_enable(struct regulator *regulator",
        "regulator_set_suspend_disable(struct regulator *regulator",
        "regulator_lock(regulator->rdev)",
        "regulator_unlock(regulator->rdev)",
        "EXPORT_SYMBOL_GPL(regulator_set_suspend_enable)",
        "EXPORT_SYMBOL_GPL(regulator_set_suspend_disable)",
        "regulator_set_suspend_enable_save(struct regulator *regulator",
        "regulator_restore_suspend_enable(struct regulator *regulator",
        "EXPORT_SYMBOL_GPL(regulator_set_suspend_enable_save)",
        "EXPORT_SYMBOL_GPL(regulator_restore_suspend_enable)",
    ):
        require(regulator_core, token, "locked regulator consumer wrappers")
    for name, call in (
        ("regulator_set_suspend_enable",
         "ret = regulator_suspend_enable(regulator->rdev, state)"),
        ("regulator_set_suspend_disable",
         "ret = regulator_suspend_disable(regulator->rdev, state)"),
    ):
        wrapper = function_body(regulator_core, name)
        for token in ("regulator_lock(regulator->rdev)", call,
                      "regulator_unlock(regulator->rdev)"):
            require(wrapper, token, f"locked {name} wrapper")
    save_wrapper = function_body(regulator_core,
                                 "regulator_set_suspend_enable_save")
    for token in ("regulator_lock(regulator->rdev)",
                  "*previous = rstate->enabled",
                  "regulator_unlock(regulator->rdev)"):
        require(save_wrapper, token, "transactional regulator save wrapper")
    restore_wrapper = function_body(regulator_core,
                                    "regulator_restore_suspend_enable")
    for token in ("regulator_lock(regulator->rdev)",
                  "rstate->enabled = previous",
                  "regulator_unlock(regulator->rdev)"):
        require(restore_wrapper, token, "transactional regulator restore wrapper")
    for token in ("regulator_set_suspend_enable", "regulator_set_suspend_disable"):
        require(consumer_h, token, "public regulator consumer API")
    for token in ("regulator_set_suspend_enable_save",
                  "regulator_restore_suspend_enable"):
        require(consumer_h, token, "transactional regulator consumer API")

    for forbidden_property in (
        "rockchip,virtual-poweroff",
        "rockchip,regulator-on-in-mem-lite",
        "rockchip,regulator-off-in-mem-lite",
        "rockchip,regulator-on-in-mem-ultra",
        "rockchip,regulator-off-in-mem-ultra",
    ):
        forbid(parser, forbidden_property, "production OF parser")
    # The standing ultra override is ACCEPTED as of 2026-08-08: R12 proved
    # the matched rails+override payload resumes (RTC + power button) at
    # 4.64 mA (doc/artifacts/pinenote-ultra-r12-20260808).  The parser must
    # carry the scalar-table entry, and .prepare must restore the DT
    # snapshot rather than resetting the override to absent.
    require(parser, '"rockchip,suspend-state-override", '
                    'OPTIONAL_OFFSET(suspend_state_override)',
            "production OF parser accepts the standing ultra override")
    require(parser, "dt_state_override",
            "prepare restores the DT override snapshot")

    for token in (
        "consumer = (struct regulator *)regulator",
        "static int rockchip_suspend_regulator_prepare",
        "return -EOPNOTSUPP;",
        "suspend_disable_secondary_cpus",
        "suspend_enable_secondary_cpus",
        "cpu_suspend(0, rockchip_suspend_psci_finish)",
        "__pa_symbol(cpu_resume)",
        "const struct rockchip_suspend_executor_ops rockchip_suspend_real_ops",
        "regulator_set_suspend_enable_save",
        "regulator_restore_suspend_enable",
        "rockchip_suspend_backend_rollback",
        "rockchip_suspend_model_transaction_add",
        "rockchip_suspend_model_transaction_rollback",
    ):
        require(backend, token, "real narrow backend")
    forbid(backend, "of_regulator_get_by_node", "execution-time backend")
    forbid(backend, "regulator_put", "execution-time backend")
    forbid(backend, "struct regulator_dev", "raw regulator backend")
    forbid(backend, "rockchip_suspend_executor_run", "real backend")
    for token in (
        "rockchip_suspend_of_parse",
        "rockchip_suspend_executor_run(&rockchip_suspend_real_ops",
        "rockchip_suspend_model_build_probe",
        "rockchip_suspend_model_build_prepare",
        "pm_suspend_target_state != PM_SUSPEND_MEM",
        ".prepare = rockchip_suspend_prepare",
        ".complete = rockchip_suspend_complete",
        "devm_add_action_or_reset(&pdev->dev, rockchip_suspend_rollback",
        "activation requires sleep-mode and wakeup policy",
        "rockchip_suspend_model_transaction_begin",
        "rockchip_suspend_model_transaction_poison",
        ".suppress_bind_attrs = true",
        "builtin_platform_driver(rockchip_suspend_activate_driver)",
    ):
        require(activation, token, "activation-only call edge")
    forbid(activation, "module_platform_driver(rockchip_suspend_activate_driver)",
           "activation built-in lifecycle")
    probe_body = function_body(activation, "rockchip_suspend_activate_probe")
    for token in ("rockchip_suspend_executor_run", "rockchip_suspend_execute",
                  "rockchip_suspend_model_build_probe",
                  "rockchip_suspend_model_build_prepare",
                  "rockchip_suspend_model_build_virtual_poweroff"):
        forbid(probe_body, token, "activation probe")
    prepare_body = function_body(activation, "rockchip_suspend_prepare")
    state_position = prepare_body.find("pm_suspend_target_state != PM_SUSPEND_MEM")
    probe_position = prepare_body.find("rockchip_suspend_model_build_probe")
    prepare_position = prepare_body.find("rockchip_suspend_model_build_prepare")
    execute_position = prepare_body.find("rockchip_suspend_execute")
    if min(state_position, probe_position, prepare_position, execute_position) < 0:
        reject("active device prepare lacks state/build/execute phases")
    if not state_position < probe_position < prepare_position < execute_position:
        reject("active device prepare phase order is not gate/build/build/execute")
    if probe_position < 0 or prepare_position < 0 or probe_position >= prepare_position:
        reject("device prepare does not execute donor probe before prepare")
    require(core, "#if !IS_ENABLED(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE)",
            "dormant driver ownership")
    complete_body = function_body(activation, "rockchip_suspend_complete")
    for token in ("rockchip_suspend_backend_rollback",
                  "rockchip_suspend_model_transaction_poison"):
        require(complete_body, token, "device PM complete rollback")
    fail_body = function_body(activation, "rockchip_suspend_fail")
    for token in ("rockchip_suspend_model_transaction_poison",
                  "rockchip_suspend_backend_rollback", "return error ? error"):
        require(fail_body, token, "poisoning prepare failure path")
    if prepare_body.count("rockchip_suspend_fail") < 5:
        reject("active device prepare does not poison every failure path")
    rollback_body = function_body(activation, "rockchip_suspend_rollback")
    for token in ("rockchip_suspend_backend_rollback",
                  "rockchip_suspend_model_transaction_poison", "dev_crit"):
        require(rollback_body, token, "activation teardown rollback")

    c_sources = {path: text for path, text in sources.items() if path.endswith(".c")}
    combined = "\n".join(c_sources.values())
    for token in ("register_pm_notifier", "unregister_pm_notifier",
                  "register_sys_off_handler", "devm_register_sys_off_handler",
                  "SYS_OFF_MODE_"):
        forbid(combined, token, "production callback surfaces")

    pm_owners = [
        path for path, text in c_sources.items()
        if path.startswith("drivers/soc/rockchip/rockchip_suspend_") and
        ".pm =" in text
    ]
    if pm_owners != ["drivers/soc/rockchip/rockchip_suspend_activate.c"]:
        reject(f"device PM ownership escapes activation source: {pm_owners}")
    call = re.compile(r"\brockchip_suspend_executor_run\s*\(")
    callers = [path for path, text in c_sources.items()
               if path != "drivers/soc/rockchip/rockchip_suspend_executor.c"
               and call.search(text)]
    if callers != ["drivers/soc/rockchip/rockchip_suspend_activate.c"]:
        reject(f"executor call edge escapes activation source: {callers}")
    for retired in RETIRED:
        if any(retired in text for text in sources.values()):
            reject(f"retired private discovery remains: {retired}")


def validate_patch(patch: str) -> None:
    if not patch.startswith(f"diff --git a/{PATHS[0]} b/{PATHS[0]}\n"):
        reject("patch has content before its first canonical diff")
    sections = patch_sections(patch)
    for token in PATCH_REQUIREMENTS:
        require(patch, token, "canonical patch")
    for retired in RETIRED:
        forbid(patch, retired, "canonical patch")
    sources = {path: extract_new_file(sections[path], path) for path in NEW_PATHS}
    validate_model(sources)
    core = sources["drivers/soc/rockchip/rockchip_suspend_mode.c"]
    activation = sources["drivers/soc/rockchip/rockchip_suspend_activate.c"]
    backend = sources["drivers/soc/rockchip/rockchip_suspend_backend.c"]
    parser = sources["drivers/soc/rockchip/rockchip_suspend_of.c"]
    for token in ("rockchip_suspend_executor_run", "arm_smccc_smc",
                  "register_pm_notifier", "register_sys_off_handler",
                  "regulator_suspend_", "suspend_disable_secondary_cpus"):
        forbid(core, token, "canonical patch dormant core")
    require(activation, "rockchip_suspend_executor_run(&rockchip_suspend_real_ops",
            "canonical patch activation edge")
    for token in ("regulator = of_regulator_get_by_node(dev, provider)",
                  "of_node_put(provider)",
                  "regulator_put((struct regulator *)regulators->on[i])"):
        require(parser, token, "canonical patch retained regulator parser")
    for forbidden_property in ("rockchip,virtual-poweroff", "mem-lite", "mem-ultra"):
        forbid(parser, forbidden_property, "canonical patch production parser")
    # suspend-state-override moved from forbidden to REQUIRED on 2026-08-08
    # (R12); the acceptance-side require lives with the main parser pins.
    require(parser, "suspend-state-override",
            "canonical patch production parser carries the standing override")
    forbid(backend, "of_regulator_get_by_node", "canonical patch backend")
    forbid(backend, "regulator_put", "canonical patch backend")
    forbid(backend, "rockchip_suspend_executor_run", "canonical patch backend")
    probe_body = function_body(activation, "rockchip_suspend_activate_probe")
    for token in ("rockchip_suspend_executor_run", "rockchip_suspend_execute",
                  "rockchip_suspend_model_build_probe"):
        forbid(probe_body, token, "canonical patch activation probe")
    prepare_body = function_body(activation, "rockchip_suspend_prepare")
    state_position = prepare_body.find("pm_suspend_target_state != PM_SUSPEND_MEM")
    probe_position = prepare_body.find("rockchip_suspend_model_build_probe")
    prepare_position = prepare_body.find("rockchip_suspend_model_build_prepare")
    execute_position = prepare_body.find("rockchip_suspend_execute")
    if min(state_position, probe_position, prepare_position, execute_position) < 0 or not (
            state_position < probe_position < prepare_position < execute_position):
        reject("canonical patch active prepare phase order differs")
    require(core, "#if !IS_ENABLED(CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE)",
            "canonical patch dormant ownership")
    for token in ("register_pm_notifier", "unregister_pm_notifier",
                  "register_sys_off_handler", "SYS_OFF_MODE_"):
        forbid("\n".join(sources.values()), token, "canonical patch callback surfaces")


def read_tree(root: Path) -> dict[str, str]:
    sources = {}
    for path in PATHS:
        artifact = root / path
        if not artifact.is_file():
            reject(f"source tree lacks required file: {path}")
        sources[path] = decode(artifact.read_bytes(), path)
    source_dir = root / "drivers/soc/rockchip"
    inventory = {
        path.name for path in source_dir.glob("rockchip_suspend*")
        if path.suffix in {".c", ".h"}
    }
    if inventory != SUSPEND_INVENTORY:
        reject(f"Rockchip suspend source inventory differs: {sorted(inventory)}")
    return sources


def expect_patch_rejected(good: str, mutated: str, description: str) -> None:
    if mutated == good:
        raise RuntimeError(f"mutation made no change: {description}")
    try:
        validate_patch(mutated)
    except InvalidArtifact:
        return
    raise RuntimeError(f"validator accepted patch mutation: {description}")


def run_patch_mutations(patch: str) -> None:
    expect_patch_rejected(patch, patch.replace("\n", "\r\n"), "CRLF patch")
    for token in PATCH_REQUIREMENTS:
        expect_patch_rejected(patch, patch.replace(token, "MUTATED"),
                              f"required architecture token {token}")
    first_header = f"diff --git a/{PATHS[0]} b/{PATHS[0]}"
    expect_patch_rejected(patch, patch.replace(first_header,
                          "diff --git a/escape b/escape", 1), "path escape")
    expect_patch_rejected(patch, patch.replace("index ", "index 1111111111111111111111111111111111111111..", 1),
                          "placeholder object ID")
    core_log = '+\tdev_info(&pdev->dev, "DORMANT policy core bound; activation compiled out\\n");'
    expect_patch_rejected(
        patch,
        patch.replace(core_log, '+\trockchip_suspend_executor_run(NULL, NULL, NULL, 0, NULL);\n' + core_log, 1),
        "executor call injected into dormant core",
    )
    activation_probe = (
        "+static int rockchip_suspend_activate_probe(struct platform_device *pdev)\n+{"
    )
    expect_patch_rejected(
        patch,
        patch.replace(activation_probe, activation_probe +
                      "\n+\trockchip_suspend_execute(NULL, NULL, 0);", 1),
        "execution injected into activation probe",
    )
    backend_cast = "+\tconsumer = (struct regulator *)regulator;"
    expect_patch_rejected(
        patch,
        patch.replace(backend_cast,
                      "+\tconsumer = of_regulator_get_by_node(NULL, NULL);", 1),
        "execution-time regulator lookup injected into backend",
    )
    scalar_anchor = "+static const struct rockchip_suspend_of_scalar rockchip_suspend_scalars[] = {"
    expect_patch_rejected(
        patch,
        patch.replace(scalar_anchor, scalar_anchor +
                      '\n+\t{ "rockchip,virtual-poweroff", OPTIONAL_OFFSET(virtual_poweroff) },', 1),
        "virtual poweroff injected into production parser",
    )
    regulator_anchor = "+static const struct rockchip_suspend_of_regulators rockchip_suspend_regulators[] = {"
    expect_patch_rejected(
        patch,
        patch.replace(regulator_anchor, regulator_anchor +
                      '\n+\t{ "rockchip,regulator-on-in-mem-lite", '
                      "ROCKCHIP_SUSPEND_MODEL_MEM_LITE, true },", 1),
        "mem-lite injected into production parser",
    )
    expect_patch_rejected(
        patch,
        patch.replace(activation_probe, activation_probe +
                      "\n+\tregister_pm_notifier(NULL);", 1),
        "PM notifier injected into activation probe",
    )


def expect_sources_rejected(sources: dict[str, str], path: str, token: str) -> None:
    mutated = dict(sources)
    if token not in mutated[path]:
        raise RuntimeError(f"source mutation token missing: {path}: {token}")
    mutated[path] = mutated[path].replace(token, "MUTATED", 1)
    try:
        validate_production_sources(mutated)
    except InvalidArtifact:
        return
    raise RuntimeError(f"validator accepted source mutation: {path}: {token}")


def expect_source_rewrite_rejected(sources: dict[str, str], path: str,
                                   old: str, new: str, description: str) -> None:
    mutated = dict(sources)
    if old not in mutated[path]:
        raise RuntimeError(f"source rewrite anchor missing: {description}")
    mutated[path] = mutated[path].replace(old, new, 1)
    try:
        validate_production_sources(mutated)
    except InvalidArtifact:
        return
    raise RuntimeError(f"validator accepted source rewrite: {description}")


def run_source_mutations(sources: dict[str, str]) -> None:
    for path, token in (
        ("drivers/soc/rockchip/Kconfig", "default n"),
        ("drivers/soc/rockchip/Kconfig",
         "depends on ARM64 && ARCH_ROCKCHIP && OF && REGULATOR && SUSPEND"),
        ("drivers/soc/rockchip/Makefile", "rockchip_suspend_backend.o"),
        ("arch/arm64/configs/pinenote_defconfig",
         "# CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE is not set"),
        ("drivers/regulator/of_regulator.c",
         "_regulator_get_common(rdev, dev, \"of-node\", NORMAL_GET)"),
        ("drivers/regulator/of_regulator.c", "get_device(&rdev->dev)"),
        ("drivers/regulator/of_regulator.c", "put_device(&rdev->dev)"),
        ("drivers/regulator/core.c",
         "ret = regulator_suspend_enable(regulator->rdev, state)"),
        ("drivers/regulator/core.c", "*previous = rstate->enabled"),
        ("drivers/regulator/core.c", "rstate->enabled = previous"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c",
         "regulator = of_regulator_get_by_node(dev, provider)"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c",
         "regulator_put((struct regulator *)regulators->on[i])"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c",
         "regulator_is_equal(regulator"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c", "count <= 0"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c", "elements <= 0"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c", "bank = (u32)alias"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c",
         "bank * 32U + args.args[0]"),
        ("drivers/soc/rockchip/rockchip_suspend_of.c", '"name"'),
        ("drivers/soc/rockchip/rockchip_suspend_model.c",
         "transaction->restores[--retained_at]"),
        ("drivers/soc/rockchip/rockchip_suspend_model.c",
         "transaction->restore_count = original_count - retained_at"),
        ("drivers/soc/rockchip/rockchip_suspend_model.c",
         "transaction->poisoned = true"),
        ("drivers/soc/rockchip/rockchip_suspend_executor.c",
         "cpu_disable_attempted = true"),
        ("drivers/soc/rockchip/rockchip_suspend_executor.c",
         "case -9:"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         "pm_suspend_target_state != PM_SUSPEND_MEM"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         ".prepare = rockchip_suspend_prepare"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         ".complete = rockchip_suspend_complete"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         ".suppress_bind_attrs = true"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         "builtin_platform_driver(rockchip_suspend_activate_driver)"),
        ("drivers/soc/rockchip/rockchip_suspend_activate.c",
         "rockchip_suspend_model_transaction_poison"),
        ("drivers/soc/rockchip/rockchip_suspend_backend.c",
         "return -EOPNOTSUPP;"),
        ("drivers/soc/rockchip/rockchip_suspend_backend.c",
         "regulator_restore_suspend_enable"),
    ):
        expect_sources_rejected(sources, path, token)
    activation_path = "drivers/soc/rockchip/rockchip_suspend_activate.c"
    anchor = "static int rockchip_suspend_activate_probe(struct platform_device *pdev)\n{"
    expect_source_rewrite_rejected(
        sources, activation_path, anchor,
        anchor + "\n\trockchip_suspend_execute(NULL, NULL, 0);",
        "execution injected into activation probe",
    )
    scalar_anchor = "static const struct rockchip_suspend_of_scalar rockchip_suspend_scalars[] = {"
    expect_source_rewrite_rejected(
        sources, "drivers/soc/rockchip/rockchip_suspend_of.c", scalar_anchor,
        scalar_anchor + '\n\t{ "rockchip,virtual-poweroff", OPTIONAL_OFFSET(virtual_poweroff) },',
        "virtual poweroff restored to production parser",
    )
    regulator_anchor = "static const struct rockchip_suspend_of_regulators rockchip_suspend_regulators[] = {"
    expect_source_rewrite_rejected(
        sources, "drivers/soc/rockchip/rockchip_suspend_of.c", regulator_anchor,
        regulator_anchor + '\n\t{ "rockchip,regulator-on-in-mem-lite", '
        "ROCKCHIP_SUSPEND_MODEL_MEM_LITE, true },",
        "mem-lite restored to production parser",
    )
    expect_source_rewrite_rejected(
        sources, "drivers/soc/rockchip/rockchip_suspend_of.c", "count <= 0",
        "count < 0", "present empty power-ctrl accepted",
    )
    expect_source_rewrite_rejected(
        sources, "drivers/soc/rockchip/rockchip_suspend_of.c", "elements <= 0",
        "elements < 0", "present empty regulator list accepted",
    )
    expect_source_rewrite_rejected(
        sources, "drivers/soc/rockchip/rockchip_suspend_of.c",
        "bank * 32U + args.args[0]", "alias * 32 + args.args[0]",
        "signed GPIO alias arithmetic restored",
    )
    expect_source_rewrite_rejected(
        sources, "drivers/regulator/of_regulator.c",
        "get_device(&rdev->dev);\n\tregulator = _regulator_get_common",
        "regulator = _regulator_get_common",
        "provider reference transfer get removed",
    )
    expect_source_rewrite_rejected(
        sources, "drivers/regulator/of_regulator.c",
        "put_device(&rdev->dev);\n\n\treturn regulator;", "return regulator;",
        "provider lookup reference put removed",
    )
    expect_source_rewrite_rejected(
        sources, activation_path, ".suppress_bind_attrs = true,", "",
        "userspace activation unbind restored",
    )
    expect_source_rewrite_rejected(
        sources, activation_path,
        "builtin_platform_driver(rockchip_suspend_activate_driver);",
        "module_platform_driver(rockchip_suspend_activate_driver);",
        "activation made unloadable",
    )


def validate_host_test_semantics() -> None:
    test = Path(__file__).with_name("rockchip-pm-test.c").read_text()
    for token in (
        "legacy event function is not 0x82000003",
        "one-short probe capacity accepted",
        "one-short prepare capacity accepted",
        "one-short virtual capacity accepted",
        "executor rejected valid virtual poweroff",
        "executor did not stop at injected failure",
        "executor prepared regulators without unwind callback",
        "executor disabled CPUs without unwind callback",
        "SIP raw status mapping differs",
        "PSCI raw status mapping differs",
        "prevalidation failure executed an operation",
        "late prevalidation failure executed an operation",
        "CPU-disable failure did not thaw",
        "prepare failure did not finish",
        "PSCI success-return unwind order differs",
        "regulator identity/action/state differ",
        "exact SIP arguments differ",
        "probe-before-prepare complete order differs",
        "unwind failure replaced first operational failure",
        "successful operations did not return finish failure at count index",
        "rollback did not preserve the first reverse-order failure",
        "rollback was not best-effort reverse order",
        "failed restore records were not retained for reverse retry",
        "poisoned retry executed an action",
        "poisoned lifecycle was reset without reboot",
        "compiled maximal suspend-state-override differs",
        "override prepare count differs",
        "override changed regulator list selection",
        "override one-short capacity accepted",
        "invalid suspend-state-override accepted",
        "activation-positive firmware word is not the ultra override",
    ):
        require(test, token, "host C tests")


def main() -> int:
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--source-tree":
            sources = read_tree(Path(sys.argv[2]))
            validate_production_sources(sources)
            run_source_mutations(sources)
            print("RESULT: Rockchip PM applied-source and mutation validation PASS")
            return 0
        if len(sys.argv) != 2:
            print(f"usage: {Path(sys.argv[0]).name} PATCH | --source-tree ROOT",
                  file=sys.stderr)
            return 2
        artifact = Path(sys.argv[1]).read_bytes()
        patch = decode(artifact, "canonical patch")
        validate_patch(patch)
        run_patch_mutations(patch)
        validate_host_test_semantics()
    except (InvalidArtifact, OSError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("RESULT: Rockchip PM canonical patch and mutation validation PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
