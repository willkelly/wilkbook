#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "drivers/soc/rockchip/rockchip_suspend_model.c"
#include "drivers/soc/rockchip/rockchip_suspend_executor.c"
#include "rockchip-pm-compiled-fixtures.h"

static void fail(const char *message)
{
	fprintf(stderr, "FAIL: %s\n", message);
	exit(EXIT_FAILURE);
}

static void expect(int condition, const char *message)
{
	if (!condition)
		fail(message);
}

static void unchanged(const void *before, const void *after, size_t size,
	const char *message)
{
	expect(!memcmp(before, after, size), message);
}

static struct rockchip_suspend_model_policy_input input_policy(void)
{
	return (struct rockchip_suspend_model_policy_input) { };
}

static struct rockchip_suspend_model_policy parse(
	const struct rockchip_suspend_model_policy_input *input)
{
	struct rockchip_suspend_model_policy policy;

	expect(!rockchip_suspend_model_parse(&policy, input), "valid policy rejected");
	return policy;
}

static void legacy(const struct rockchip_suspend_model_event *event, u32 control,
	u32 arg1, u32 arg2)
{
	expect(event->kind == ROCKCHIP_SUSPEND_MODEL_LEGACY, "event is not legacy");
	expect(event->legacy.function == ROCKCHIP_LEGACY_SIP_SUSPEND_MODE,
		"legacy event function is not 0x82000003");
	expect(event->legacy.control == control && event->legacy.arg1 == arg1 &&
	       event->legacy.arg2 == arg2, "legacy event arguments differ");
}

static u32 consume_virtual_poweroff_trace(
	const struct rockchip_suspend_model_event *events, u32 count, bool cpu_disable_fails)
{
	u32 i;

	for (i = 0; i < count; i++)
		if (events[i].kind == ROCKCHIP_SUSPEND_MODEL_DISABLE_SECONDARY_CPUS &&
		    cpu_disable_fails)
			return i + 1;
	return count;
}

static void expect_parse_rejected(const struct rockchip_suspend_model_policy_input *input,
	const char *message)
{
	struct rockchip_suspend_model_policy parsed;
	struct rockchip_suspend_model_policy before;

	memset(&parsed, 0x5a, sizeof(parsed));
	before = parsed;
	expect(rockchip_suspend_model_parse(&parsed, input) < 0, message);
	unchanged(&before, &parsed, sizeof(parsed), "parse mutated destination on error");
}

static void test_bindings(void)
{
	const u32 sleep[] = { RKPM_SLP_WFI, RKPM_SLP_ARMOFF, RKPM_SLP_CENTER_OFF,
		RKPM_SLP_ARMOFF_LOGOFF, RKPM_SLP_FROM_UBOOT, RKPM_SLP_PMIC_LP,
		RKPM_SLP_HW_PLLS_OFF, RKPM_SLP_PMUALIVE_32K, RKPM_SLP_OSC_DIS,
		RKPM_SLP_32K_EXT, RKPM_SLP_32K_PVTM };
	const u32 wake[] = { RKPM_CPU0_WKUP_EN, RKPM_CPU1_WKUP_EN, RKPM_CPU2_WKUP_EN,
		RKPM_CPU3_WKUP_EN, RKPM_GPIO_WKUP_EN, RKPM_UART0_WKUP_EN,
		RKPM_SDMMC0_WKUP_EN, RKPM_SDMMC1_WKUP_EN, RKPM_SDMMC2_WKUP_EN,
		RKPM_USB_WKUP_EN, RKPM_PCIE_WKUP_EN, RKPM_VAD_WKUP_EN,
		RKPM_TIMER_WKUP_EN, RKPM_PWM0_WKUP_EN, RKPM_TIMEOUT_WKUP_EN,
		RKPM_SFT_WKUP_EN, RKPM_USB_LINESTATE_WKUP_EN };
	const u32 ldo[] = { RKPM_SLP_LDO1_ON, RKPM_SLP_LDO2_ON, RKPM_SLP_LDO3_ON,
		RKPM_SLP_LDO4_ON, RKPM_SLP_LDO5_ON, RKPM_SLP_LDO6_ON,
		RKPM_SLP_LDO7_ON, RKPM_SLP_LDO8_ON, RKPM_SLP_LDO9_ON };
	u32 i;

	for (i = 0; i < sizeof(sleep) / sizeof(sleep[0]); i++)
		expect(sleep[i] == 1U << i, "sleep binding bit differs");
	for (i = 0; i < sizeof(wake) / sizeof(wake[0]); i++)
		expect(wake[i] == 1U << i, "wake binding bit differs");
	for (i = 0; i < sizeof(ldo) / sizeof(ldo[0]); i++)
		expect(ldo[i] == 1U << i, "LDO binding bit differs");
	expect(ROCKCHIP_LEGACY_SUSPEND_WFI_TIME_MS == 0x08, "control 0x08 changed");
	expect(ROCKCHIP_SUSPEND_MODEL_PSCI_FN64_SYSTEM_SUSPEND == 0xc400000e,
		"PSCI function changed");
}

static void test_probe(void)
{
	struct rockchip_suspend_model_policy_input input = rockchip_pm_compiled_donor;
	struct rockchip_suspend_model_event events[ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS];
	struct rockchip_suspend_model_event before[ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS];
	struct rockchip_suspend_model_policy policy;
	u32 i;

	policy = parse(&input);
	expect(rockchip_suspend_model_build_probe(&policy, events, 4) == 4,
		"donor fixture count differs");
	legacy(&events[0], 0x01, 0x5ec, 0);
	legacy(&events[1], 0x02, 0x10, 0);
	legacy(&events[2], 0x04, 0, 0xffff);
	legacy(&events[3], 0x05, 0, 0);
	input = rockchip_pm_compiled_maximal;
	for (i = 0; i < 9; i++)
		expect(input.gpios[i].number == i && input.gpios[i].flags == 0xa0 + i,
			"compiled maximal GPIO identity or flags differ");
	for (i = 0; i < 3; i++) {
		expect(input.regulators[i].on_count == (i ? 1U : 2U) &&
		       input.regulators[i].off_count == 1,
			"compiled maximal regulator surface differs");
		expect(input.regulators[i].on[0] && input.regulators[i].off[0] &&
		       input.regulators[i].on[0] != input.regulators[i].off[0],
			"compiled maximal regulator identity differs");
	}
	expect(input.suspend_state_override.present &&
	       input.suspend_state_override.value == 5,
		"compiled maximal suspend-state-override differs");
	policy = parse(&input);
	expect(rockchip_suspend_model_build_probe(&policy, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS) == 15, "max probe capacity differs");
	memcpy(before, events, sizeof(events));
	expect(rockchip_suspend_model_build_probe(&policy, events, 14) == -ENOSPC,
		"one-short probe capacity accepted");
	unchanged(before, events, sizeof(events), "short probe mutated output");
	legacy(&events[0], 0x01, 0x7ff, 0);
	legacy(&events[1], 0x02, 0x1ffff, 0);
	legacy(&events[2], 0x03, 0x1ff, 0);
	for (i = 0; i < 9; i++)
		legacy(&events[3 + i], 0x04, i, i);
	legacy(&events[12], 0x04, 9, 0xffff);
	legacy(&events[13], 0x05, 8, 0);
	legacy(&events[14], 0x06, 9, 0);
	for (i = 0; i < 15; i++)
		expect(events[i].legacy.control != ROCKCHIP_LEGACY_SUSPEND_WFI_TIME_MS,
			"builder emitted control 0x08");
}

static void test_prepare_and_virtual_poweroff(void)
{
	struct rockchip_suspend_model_policy_input input = input_policy();
	struct rockchip_suspend_model_event events[ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS];
	struct rockchip_suspend_model_event before[ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS];
	struct rockchip_suspend_model_policy policy;
	u32 state;
	u32 i;
	u32 consumed;

	for (state = 0; state < 3; state++) {
		for (i = 0; i < ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS; i++) {
			input.regulators[state].on[i] = 1000 + state * 100 + i;
			input.regulators[state].off[i] = 2000 + state * 100 + i;
		}
		input.regulators[state].on_count = ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS;
		input.regulators[state].off_count = ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS;
	}
	input.virtual_poweroff = (struct rockchip_suspend_model_optional) { true, 1 };
	policy = parse(&input);
	for (state = 3; state <= 5; state++) {
		expect(rockchip_suspend_model_build_prepare(&policy, state, events,
			ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS) == 61,
			"prepare state count differs");
		legacy(&events[0], 0x09, state, 0);
		for (i = 0; i < ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS; i++) {
			expect(events[1 + i].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
				events[1 + i].regulator.state == state - 3 &&
				events[1 + i].regulator.action == ROCKCHIP_SUSPEND_MODEL_REGULATOR_ENABLE &&
			events[1 + i].regulator.regulator == 1000 + (state - 3) * 100 + i,
				"on regulator list differs");
			expect(events[31 + i].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
				events[31 + i].regulator.state == state - 3 &&
				events[31 + i].regulator.action == ROCKCHIP_SUSPEND_MODEL_REGULATOR_DISABLE &&
			events[31 + i].regulator.regulator == 2000 + (state - 3) * 100 + i,
				"off regulator list differs");
		}
		memcpy(before, events, sizeof(events));
		expect(rockchip_suspend_model_build_prepare(&policy, state, events, 60) == -ENOSPC,
			"one-short prepare capacity accepted");
		unchanged(before, events, sizeof(events), "short prepare mutated output");
	}
	expect(rockchip_suspend_model_build_prepare(&policy, 2, events, 1) == 1,
		"nonselecting state differs");
	legacy(&events[0], 0x09, 2, 0);
	expect(rockchip_suspend_model_build_virtual_poweroff(&policy, events, 4) == 4,
		"virtual poweroff count differs");
	expect(events[0].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR_PREPARE &&
		events[0].regulator_prepare.linux_suspend_state == 3, "prepare event differs");
	expect(events[1].kind == ROCKCHIP_SUSPEND_MODEL_DISABLE_SECONDARY_CPUS,
		"CPU fail-stop event differs");
	legacy(&events[2], 0x07, 0, 1);
	expect(events[3].kind == ROCKCHIP_SUSPEND_MODEL_PSCI_SYSTEM_SUSPEND &&
		events[3].psci.function == ROCKCHIP_SUSPEND_MODEL_PSCI_FN64_SYSTEM_SUSPEND,
		"PSCI descriptive event differs");
	memcpy(before, events, sizeof(events));
	expect(rockchip_suspend_model_build_virtual_poweroff(&policy, NULL, 4) == -EINVAL,
		"enabled virtual poweroff accepted NULL output");
	unchanged(before, events, sizeof(events), "NULL virtual output mutated caller buffer");
	expect(rockchip_suspend_model_build_virtual_poweroff(&policy, events, 3) == -ENOSPC,
		"one-short virtual capacity accepted");
	unchanged(before, events, sizeof(events), "short virtual mutated output");
	consumed = consume_virtual_poweroff_trace(events, 4, true);
	expect(consumed == 2,
		"local CPU-disable fail-stop did not stop after two events");
	legacy(&events[consumed], 0x07, 0, 1);
	expect(events[consumed + 1].kind == ROCKCHIP_SUSPEND_MODEL_PSCI_SYSTEM_SUSPEND,
		"fail-stop trace omitted unconsumed PSCI event");
	expect(consume_virtual_poweroff_trace(events, 4, false) == 4,
		"local successful trace did not consume all events");
	input.virtual_poweroff = (struct rockchip_suspend_model_optional) { };
	policy = parse(&input);
	expect(rockchip_suspend_model_build_virtual_poweroff(&policy, NULL, 0) == 0,
		"absent virtual poweroff differs");
	input.virtual_poweroff = (struct rockchip_suspend_model_optional) { true, 0 };
	policy = parse(&input);
	expect(rockchip_suspend_model_build_virtual_poweroff(&policy, NULL, 0) == 0,
		"zero virtual poweroff differs");
}

static void test_suspend_state_override(void)
{
	struct rockchip_suspend_model_policy_input input = rockchip_pm_compiled_maximal;
	struct rockchip_suspend_model_event events[ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS];
	struct rockchip_suspend_model_event before[ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS];
	struct rockchip_suspend_model_policy policy;
	static const u32 rejected_values[] = { 0, 1, 2, 3, 4, 6, 0xffffffff };
	u32 i;

	/*
	 * The override changes only the 0x09 firmware word; regulator
	 * list selection stays derived from the real Linux state.  The
	 * maximal fixture carries <5>, so prepare at Linux state 3 must
	 * tell firmware 5 while emitting the MEM lists unchanged.
	 */
	policy = parse(&input);
	expect(rockchip_suspend_model_build_prepare(&policy, 3, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS) == 4,
		"override prepare count differs");
	legacy(&events[0], 0x09, 5, 0);
	expect(events[1].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
	       events[1].regulator.state == 0 &&
	       events[1].regulator.action == ROCKCHIP_SUSPEND_MODEL_REGULATOR_ENABLE &&
	       events[1].regulator.regulator == input.regulators[0].on[0],
		"override changed regulator list selection");
	expect(events[2].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
	       events[2].regulator.regulator == input.regulators[0].on[1],
		"override changed regulator list order");
	expect(events[3].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
	       events[3].regulator.action == ROCKCHIP_SUSPEND_MODEL_REGULATOR_DISABLE &&
	       events[3].regulator.regulator == input.regulators[0].off[0],
		"override changed off list");
	/* A nonselecting state still tells firmware the override. */
	expect(rockchip_suspend_model_build_prepare(&policy, 2, events, 1) == 1,
		"override nonselecting count differs");
	legacy(&events[0], 0x09, 5, 0);
	/* One-short capacity stays an error and stays nonmutating. */
	expect(rockchip_suspend_model_build_prepare(&policy, 3, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS) == 4,
		"override recount differs");
	memcpy(before, events, sizeof(events));
	expect(rockchip_suspend_model_build_prepare(&policy, 3, events, 3) == -ENOSPC,
		"override one-short capacity accepted");
	unchanged(before, events, sizeof(events), "override short prepare mutated output");
	/* Every non-5 value is rejected without mutating the destination. */
	for (i = 0; i < sizeof(rejected_values) / sizeof(rejected_values[0]); i++) {
		input = rockchip_pm_compiled_maximal;
		input.suspend_state_override = (struct rockchip_suspend_model_optional) {
			true, rejected_values[i] };
		expect_parse_rejected(&input, "invalid suspend-state-override accepted");
	}
}

static void test_rejections_and_nonmutation(void)
{
	struct rockchip_suspend_model_policy_input input = input_policy();
	struct rockchip_suspend_model_policy parsed;
	struct rockchip_suspend_model_policy parsed_before;
	struct rockchip_suspend_model_event events[ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS];
	struct rockchip_suspend_model_event events_before[ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS];
	u32 i;

	for (i = 0; i < 8; i++) {
		switch (i) {
		case 0: input.sleep_mode = (struct rockchip_suspend_model_optional) { true, 0x800 }; break;
		case 1: input.wakeup = (struct rockchip_suspend_model_optional) { true, 0x20000 }; break;
		case 2: input.pwm_regulator = (struct rockchip_suspend_model_optional) { true, 0x200 }; break;
		case 3: input.virtual_poweroff = (struct rockchip_suspend_model_optional) { true, 2 }; break;
		case 4: input.gpio_count = 10; break;
		case 5: input.gpio_count = 1; input.gpios[0].number = 0xffff; break;
		case 6: input.regulators[0].on_count = 31; break;
		case 7: input.regulators[0].on[0] = 0; input.regulators[0].on_count = 1; break;
		}
		expect_parse_rejected(&input, "invalid input accepted");
		input = input_policy();
	}
	input.regulators[0].off[0] = input.regulators[0].off[1] = 1;
	input.regulators[0].off_count = 2;
	expect_parse_rejected(&input, "duplicate off ID accepted");
	input.regulators[0].off_count = 1;
	input.regulators[0].on[0] = 1;
	input.regulators[0].on_count = 1;
	expect_parse_rejected(&input, "on/off overlap accepted");
	input = input_policy();
	input.regulators[0].on[0] = input.regulators[0].on[1] = 1;
	input.regulators[0].on_count = 2;
	expect_parse_rejected(&input, "duplicate on ID accepted");
	input = input_policy();
	input.regulators[0].off_count = 31;
	expect_parse_rejected(&input, "off count overflow accepted");
	input = input_policy();
	input.regulators[0].off[0] = 0;
	input.regulators[0].off_count = 1;
	expect_parse_rejected(&input, "unresolved off ID accepted");
	expect(rockchip_suspend_model_parse(NULL, &input) < 0, "NULL parse output accepted");
	memset(&parsed, 0x5a, sizeof(parsed));
	parsed_before = parsed;
	expect(rockchip_suspend_model_parse(&parsed, NULL) < 0, "NULL parse input accepted");
	unchanged(&parsed_before, &parsed, sizeof(parsed), "NULL parse input mutated output");
	input = input_policy();
	parsed = parse(&input);
	memset(events, 0xa5, sizeof(events)); memcpy(events_before, events, sizeof(events));
	expect(rockchip_suspend_model_build_probe(NULL, events, 1) < 0, "NULL builder policy accepted");
	unchanged(events_before, events, sizeof(events), "NULL builder mutated output");
	expect(rockchip_suspend_model_build_probe(&parsed, NULL, 1) < 0, "NULL event array accepted");
	expect(rockchip_suspend_model_build_prepare(NULL, 3, events, 1) < 0,
		"NULL prepare policy accepted");
	unchanged(events_before, events, sizeof(events), "NULL prepare mutated output");
	expect(rockchip_suspend_model_build_prepare(&parsed, 3, NULL, 1) < 0,
		"NULL prepare event array accepted");
	expect(rockchip_suspend_model_build_virtual_poweroff(NULL, events, 1) < 0,
		"NULL poweroff policy accepted");
	unchanged(events_before, events, sizeof(events), "NULL poweroff mutated output");
	expect(rockchip_suspend_model_build_virtual_poweroff(&parsed, NULL, 1) == 0,
		"disabled poweroff rejected NULL output");
	parsed.value.gpio_count = 10;
	expect(rockchip_suspend_model_build_probe(&parsed, events, 15) < 0, "builder skipped defensive validation");
	unchanged(events_before, events, sizeof(events), "invalid builder mutated output");
	expect(rockchip_suspend_model_build_prepare(&parsed, 3, events, 1) < 0,
		"prepare skipped defensive validation");
	unchanged(events_before, events, sizeof(events), "invalid prepare mutated output");
	expect(rockchip_suspend_model_build_virtual_poweroff(&parsed, events, 1) < 0,
		"poweroff skipped defensive validation");
	unchanged(events_before, events, sizeof(events), "invalid poweroff mutated output");
}

struct fake_executor {
	struct {
		char operation;
		u32 control;
		u32 arg1;
		u32 arg2;
		unsigned long regulator;
		u32 action;
		u32 state;
	} trace[32];
	u32 trace_count;
	u32 operation_calls;
	u32 fail_at_operation;
	int finish_result;
	struct rockchip_suspend_model_transaction *transaction;
	int regulator_previous[ROCKCHIP_SUSPEND_MODEL_MAX_REGULATORS];
	u32 regulator_calls;
};

static int fake_operation(struct fake_executor *fake, char operation)
{
	fake->trace[fake->trace_count++].operation = operation;
	fake->operation_calls++;
	return fake->fail_at_operation == fake->operation_calls ? -EIO : 0;
}

static int fake_sip(void *context, u32 control, u32 arg1, u32 arg2)
{
	struct fake_executor *fake = context;

	fake->trace[fake->trace_count].control = control;
	fake->trace[fake->trace_count].arg1 = arg1;
	fake->trace[fake->trace_count].arg2 = arg2;
	return fake_operation(fake, 'S');
}

static int fake_regulator(void *context, unsigned long regulator,
	enum rockchip_suspend_model_regulator_action action, u32 state)
{
	struct fake_executor *fake = context;
	u32 regulator_call = fake->regulator_calls++;
	int ret;

	fake->trace[fake->trace_count].regulator = regulator;
	fake->trace[fake->trace_count].action = action;
	fake->trace[fake->trace_count].state = state;
	ret = fake_operation(fake, 'R');
	if (ret || !fake->transaction)
		return ret;
	return rockchip_suspend_model_transaction_add(fake->transaction,
		regulator, state, fake->regulator_previous[regulator_call]);
}

static int fake_prepare(void *context, u32 state)
{
	struct fake_executor *fake = context;

	fake->trace[fake->trace_count].state = state;
	return fake_operation(fake, 'P');
}

static int fake_finish(void *context)
{
	struct fake_executor *fake = context;

	fake->trace[fake->trace_count++].operation = 'F';
	return fake->finish_result;
}

static int fake_disable(void *context)
{
	return fake_operation(context, 'D');
}

static void fake_enable(void *context)
{
	struct fake_executor *fake = context;

	fake->trace[fake->trace_count++].operation = 'E';
}

static int fake_psci(void *context)
{
	return fake_operation(context, 'X');
}

static const struct rockchip_suspend_executor_ops fake_ops = {
	.sip = fake_sip,
	.regulator = fake_regulator,
	.regulator_prepare = fake_prepare,
	.regulator_finish = fake_finish,
	.disable_secondary_cpus = fake_disable,
	.enable_secondary_cpus = fake_enable,
	.psci_system_suspend = fake_psci,
};

static void expect_trace(const struct fake_executor *fake, const char *operations,
	const char *message)
{
	u32 i;

	expect(fake->trace_count == strlen(operations), message);
	for (i = 0; i < fake->trace_count; i++)
		expect(fake->trace[i].operation == operations[i], message);
}

static void test_status_mappings(void)
{
	static const struct { long raw; int mapped; } sip[] = {
		{ 0, 0 }, { -1, -EOPNOTSUPP }, { -2, -EOPNOTSUPP },
		{ -3, -EINVAL }, { -4, -EFAULT }, { -5, -EACCES },
		{ -6, -ETIMEDOUT }, { -7, -EIO }, { 1, -EIO },
	};
	static const struct { long raw; int mapped; } psci[] = {
		{ 0, 0 }, { -1, -EOPNOTSUPP }, { -2, -EINVAL },
		{ -9, -EINVAL }, { -3, -EPERM }, { -4, -EINVAL },
		{ -6, -EINVAL }, { 1, -EINVAL },
	};
	u32 i;

	for (i = 0; i < sizeof(sip) / sizeof(sip[0]); i++)
		expect(rockchip_suspend_sip_status(sip[i].raw) == sip[i].mapped,
			"SIP raw status mapping differs");
	for (i = 0; i < sizeof(psci) / sizeof(psci[0]); i++)
		expect(rockchip_suspend_psci_status(psci[i].raw) == psci[i].mapped,
			"PSCI raw status mapping differs");
}

static void test_executor(void)
{
	struct rockchip_suspend_model_event events[] = {
		{ .kind = ROCKCHIP_SUSPEND_MODEL_REGULATOR_PREPARE,
		  .regulator_prepare = { 3 } },
		{ .kind = ROCKCHIP_SUSPEND_MODEL_REGULATOR,
		  .regulator = { ROCKCHIP_SUSPEND_MODEL_MEM,
			ROCKCHIP_SUSPEND_MODEL_REGULATOR_DISABLE, 0x1234 } },
		{ .kind = ROCKCHIP_SUSPEND_MODEL_DISABLE_SECONDARY_CPUS },
		{ .kind = ROCKCHIP_SUSPEND_MODEL_LEGACY,
		  .legacy = { ROCKCHIP_LEGACY_SIP_SUSPEND_MODE,
			ROCKCHIP_LEGACY_VIRTUAL_POWEROFF, 7, 1 } },
		{ .kind = ROCKCHIP_SUSPEND_MODEL_PSCI_SYSTEM_SUSPEND,
		  .psci = { ROCKCHIP_SUSPEND_MODEL_PSCI_FN64_SYSTEM_SUSPEND } },
	};
	struct fake_executor fake;
	u32 failed;
	int position;

	for (position = 0; position < 5; position++) {
		memset(&fake, 0, sizeof(fake));
		fake.fail_at_operation = position + 1;
		expect(rockchip_suspend_executor_run(&fake_ops, &fake, events, 5,
			&failed) == -EIO,
			"executor did not stop at injected failure");
		expect(failed == (u32)position, "executor reported wrong failure index");
		expect(fake.operation_calls == (u32)position + 1,
			"executor retried after failure");
		if (position == 0)
			expect_trace(&fake, "PF", "prepare failure did not finish");
		else if (position == 1)
			expect_trace(&fake, "PRF", "regulator failure unwind differs");
		else if (position == 2)
			expect_trace(&fake, "PRDEF", "CPU-disable failure did not thaw");
		else if (position == 3)
			expect_trace(&fake, "PRDSEF", "SIP failure unwind differs");
		else
			expect_trace(&fake, "PRDSXEF", "PSCI failure unwind differs");
	}
	memset(&fake, 0, sizeof(fake));
	expect(!rockchip_suspend_executor_run(&fake_ops, &fake, events, 5, &failed),
		"executor rejected valid virtual poweroff");
	expect_trace(&fake, "PRDSXEF", "PSCI success-return unwind order differs");
	expect(fake.trace[1].regulator == 0x1234 &&
		fake.trace[1].action == ROCKCHIP_SUSPEND_MODEL_REGULATOR_DISABLE &&
		fake.trace[1].state == ROCKCHIP_SUSPEND_MODEL_MEM,
		"regulator identity/action/state differ");
	expect(fake.trace[3].control == ROCKCHIP_LEGACY_VIRTUAL_POWEROFF &&
		fake.trace[3].arg1 == 7 && fake.trace[3].arg2 == 1,
		"exact SIP arguments differ");
	expect(failed == 5, "successful returning path failure index differs");
	expect(rockchip_suspend_executor_run(&fake_ops, &fake, NULL, 0, &failed) == -EINVAL,
		"executor accepted empty action array");
	{
		struct rockchip_suspend_executor_ops incomplete = fake_ops;

		memset(&fake, 0, sizeof(fake));
		incomplete.regulator_finish = NULL;
		expect(rockchip_suspend_executor_run(&incomplete, &fake, events, 4,
			&failed) == -EOPNOTSUPP,
			"executor prepared regulators without unwind callback");
		expect(fake.trace_count == 0 && failed == 0,
			"prevalidation failure executed an operation");
		incomplete = fake_ops;
		incomplete.enable_secondary_cpus = NULL;
		expect(rockchip_suspend_executor_run(&incomplete, &fake, events, 5,
			&failed) == -EOPNOTSUPP,
			"executor disabled CPUs without unwind callback");
		expect(fake.trace_count == 0 && failed == 2,
			"late prevalidation failure executed an operation");
	}
	memset(&fake, 0, sizeof(fake));
	fake.fail_at_operation = 4;
	fake.finish_result = -ETIMEDOUT;
	expect(rockchip_suspend_executor_run(&fake_ops, &fake, events, 5,
		&failed) == -EIO && failed == 3,
		"unwind failure replaced first operational failure");
	memset(&fake, 0, sizeof(fake));
	fake.finish_result = -ETIMEDOUT;
	expect(rockchip_suspend_executor_run(&fake_ops, &fake, events, 5,
		&failed) == -ETIMEDOUT && failed == 5,
		"successful operations did not return finish failure at count index");
}

static void test_pm_prepare_order(void)
{
	struct rockchip_suspend_model_event events[ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS];
	struct rockchip_suspend_model_policy policy = parse(&rockchip_pm_compiled_donor);
	struct fake_executor fake = { };
	u32 failed;
	int count;

	count = rockchip_suspend_model_build_probe(&policy, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS);
	expect(!rockchip_suspend_executor_run(&fake_ops, &fake, events, count, &failed),
		"donor probe sequence execution failed");
	count = rockchip_suspend_model_build_prepare(&policy, 3, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS);
	expect(!rockchip_suspend_executor_run(&fake_ops, &fake, events, count, &failed),
		"donor prepare sequence execution failed");
	expect_trace(&fake, "SSSSS", "probe-before-prepare complete order differs");
	expect(fake.trace[0].control == ROCKCHIP_LEGACY_SUSPEND_MODE_CONFIG &&
		fake.trace[0].arg1 == 0x5ec && fake.trace[0].arg2 == 0,
		"sleep-mode SIP arguments differ");
	expect(fake.trace[1].control == ROCKCHIP_LEGACY_WAKEUP_SOURCE_CONFIG &&
		fake.trace[1].arg1 == 0x10 && fake.trace[1].arg2 == 0,
		"wakeup SIP arguments differ");
	expect(fake.trace[2].control == ROCKCHIP_LEGACY_GPIO_POWER_CONFIG &&
		fake.trace[2].arg1 == 0 && fake.trace[2].arg2 == 0xffff,
		"GPIO terminator SIP arguments differ");
	expect(fake.trace[3].control == ROCKCHIP_LEGACY_SUSPEND_DEBUG_ENABLE &&
		fake.trace[3].arg1 == 0 && fake.trace[3].arg2 == 0,
		"sleep-debug SIP arguments differ");
	expect(fake.trace[4].control == ROCKCHIP_LEGACY_LINUX_PM_STATE &&
		fake.trace[4].arg1 == 3 && fake.trace[4].arg2 == 0,
		"Linux PM-state SIP arguments differ");
}

struct fake_restore {
	unsigned long trace[8];
	u32 states[8];
	int previous[8];
	u32 trace_count;
	unsigned long fail_once[2];
};

static int fake_restore_record(void *context,
	const struct rockchip_suspend_model_restore *restore)
{
	struct fake_restore *fake = context;
	u32 i;

	fake->trace[fake->trace_count] = restore->target;
	fake->states[fake->trace_count] = restore->state;
	fake->previous[fake->trace_count++] = restore->previous;
	for (i = 0; i < sizeof(fake->fail_once) / sizeof(fake->fail_once[0]); i++) {
		if (fake->fail_once[i] != restore->target)
			continue;
		fake->fail_once[i] = 0;
		return i ? -EIO : -ETIMEDOUT;
	}

	return 0;
}

static void test_transaction_retry_and_poison(void)
{
	struct rockchip_suspend_model_transaction transaction = { };
	struct fake_restore fake = {
		.fail_once = { 3, 1 },
	};
	u32 actions = 0;

	expect(!rockchip_suspend_model_transaction_begin(&transaction),
		"clean transaction did not begin");
	expect(!rockchip_suspend_model_transaction_add(&transaction, 1, 3, 10) &&
	       !rockchip_suspend_model_transaction_add(&transaction, 2, 3, 20) &&
	       !rockchip_suspend_model_transaction_add(&transaction, 3, 3, 30),
		"valid restore records were rejected");
	expect(rockchip_suspend_model_transaction_begin(&transaction) == -EBUSY,
		"outstanding restore records allowed a new transaction");
	expect(rockchip_suspend_model_transaction_rollback(&transaction,
		fake_restore_record, &fake) == -ETIMEDOUT,
		"rollback did not preserve the first reverse-order failure");
	expect(fake.trace_count == 3 && fake.trace[0] == 3 && fake.trace[1] == 2 &&
	       fake.trace[2] == 1, "rollback was not best-effort reverse order");
	expect(transaction.restore_count == 2 &&
	       transaction.restores[0].target == 1 &&
	       transaction.restores[1].target == 3,
		"failed restore records were not retained for reverse retry");
	expect(!rockchip_suspend_model_transaction_rollback(&transaction,
		fake_restore_record, &fake), "retained restore retry failed");
	expect(fake.trace_count == 5 && fake.trace[3] == 3 && fake.trace[4] == 1,
		"restore retry order differs");
	expect(!transaction.restore_count, "successful retry retained restore records");
	rockchip_suspend_model_transaction_poison(&transaction);
	if (!rockchip_suspend_model_transaction_begin(&transaction))
		actions++;
	expect(!actions, "poisoned retry executed an action");
	expect(rockchip_suspend_model_transaction_begin(&transaction) == -EIO,
		"poisoned lifecycle was reset without reboot");
}

static void test_activation_positive(void)
{
	struct rockchip_suspend_model_event events[
		ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS +
		ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS];
	struct rockchip_suspend_model_policy policy = parse(&rockchip_pm_compiled_maximal);
	struct fake_executor fake = { };
	static const struct { u32 control; u32 arg1; u32 arg2; } probe[] = {
		{ 0x01, 0x7ff, 0 }, { 0x02, 0x1ffff, 0 }, { 0x03, 0x1ff, 0 },
		{ 0x04, 0, 0 }, { 0x04, 1, 1 }, { 0x04, 2, 2 },
		{ 0x04, 3, 3 }, { 0x04, 4, 4 }, { 0x04, 5, 5 },
		{ 0x04, 6, 6 }, { 0x04, 7, 7 }, { 0x04, 8, 8 },
		{ 0x04, 9, 0xffff }, { 0x05, 8, 0 }, { 0x06, 9, 0 },
	};
	u32 failed;
	u32 i;
	int probe_count;
	int prepare_count;

	probe_count = rockchip_suspend_model_build_probe(&policy, events,
		ROCKCHIP_SUSPEND_MODEL_MAX_PROBE_EVENTS);
	expect(probe_count == (int)(sizeof(probe) / sizeof(probe[0])),
		"activation-positive probe action count differs");
	for (i = 0; i < (u32)probe_count; i++)
		legacy(&events[i], probe[i].control, probe[i].arg1, probe[i].arg2);
	prepare_count = rockchip_suspend_model_build_prepare(&policy, 3,
		&events[probe_count], ROCKCHIP_SUSPEND_MODEL_MAX_PREPARE_EVENTS);
	expect(prepare_count == 4, "activation-positive MEM action count differs");
	/*
	 * The maximal fixture carries rockchip,suspend-state-override = <5>:
	 * the firmware word is the ultra override while the MEM regulator
	 * actions below stay selected from the real Linux state 3.
	 */
	legacy(&events[probe_count], ROCKCHIP_LEGACY_LINUX_PM_STATE, 5, 0);
	for (i = 0; i < 2; i++) {
		expect(events[probe_count + 1 + i].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
		       events[probe_count + 1 + i].regulator.state == ROCKCHIP_SUSPEND_MODEL_MEM &&
		       events[probe_count + 1 + i].regulator.action ==
		       ROCKCHIP_SUSPEND_MODEL_REGULATOR_ENABLE &&
		       events[probe_count + 1 + i].regulator.regulator ==
		       rockchip_pm_compiled_maximal.regulators[ROCKCHIP_SUSPEND_MODEL_MEM].on[i],
			"activation-positive MEM enable arguments differ");
	}
	expect(events[probe_count + 3].kind == ROCKCHIP_SUSPEND_MODEL_REGULATOR &&
	       events[probe_count + 3].regulator.state == ROCKCHIP_SUSPEND_MODEL_MEM &&
	       events[probe_count + 3].regulator.action ==
	       ROCKCHIP_SUSPEND_MODEL_REGULATOR_DISABLE &&
	       events[probe_count + 3].regulator.regulator ==
	       rockchip_pm_compiled_maximal.regulators[ROCKCHIP_SUSPEND_MODEL_MEM].off[0],
		"activation-positive MEM disable arguments differ");
	expect(!rockchip_suspend_executor_run(&fake_ops, &fake, events,
		probe_count + prepare_count, &failed),
		"activation-positive fake execution failed");
	expect_trace(&fake, "SSSSSSSSSSSSSSSSRRR",
		"activation-positive fake action order differs");
	expect(fake.operation_calls == 19 && failed == 19,
		"activation-positive fake completion differs");
	for (i = 0; i < (u32)probe_count; i++)
		expect(fake.trace[i].control == probe[i].control &&
		       fake.trace[i].arg1 == probe[i].arg1 && fake.trace[i].arg2 == probe[i].arg2,
			"activation-positive fake probe arguments differ");
	expect(fake.trace[probe_count].control == ROCKCHIP_LEGACY_LINUX_PM_STATE &&
	       fake.trace[probe_count].arg1 == 5 && fake.trace[probe_count].arg2 == 0,
		"activation-positive firmware word is not the ultra override");
	for (i = 0; i < 3; i++)
		expect(fake.trace[probe_count + 1 + i].regulator ==
		       events[probe_count + 1 + i].regulator.regulator &&
		       fake.trace[probe_count + 1 + i].action ==
		       events[probe_count + 1 + i].regulator.action &&
		       fake.trace[probe_count + 1 + i].state ==
		       events[probe_count + 1 + i].regulator.state,
			"activation-positive fake MEM arguments differ");

	for (i = 0; i < 3; i++) {
		struct rockchip_suspend_model_transaction transaction = { };
		struct fake_restore restore = { };
		static const char *failure_traces[] = {
			"SSSSSSSSSSSSSSSSR",
			"SSSSSSSSSSSSSSSSRR",
			"SSSSSSSSSSSSSSSSRRR",
		};
		u32 restored;

		memset(&fake, 0, sizeof(fake));
		expect(!rockchip_suspend_model_transaction_begin(&transaction),
			"activation-positive transaction setup failed");
		fake.transaction = &transaction;
		fake.regulator_previous[0] = 11;
		fake.regulator_previous[1] = 22;
		fake.regulator_previous[2] = 33;
		fake.fail_at_operation = 17 + i;
		expect(rockchip_suspend_executor_run(&fake_ops, &fake, events,
			probe_count + prepare_count, &failed) == -EIO &&
			failed == 16 + i,
			"activation-positive injected MEM failure differs");
		expect_trace(&fake, failure_traces[i],
			"activation-positive failure executed a later action");
		expect(fake.operation_calls == 17 + i,
			"activation-positive failure retried or executed a later action");
		expect(transaction.restore_count == i,
			"activation-positive restore set does not match completed mutations");
		expect(!rockchip_suspend_model_transaction_rollback(&transaction,
			fake_restore_record, &restore),
			"activation-positive unwind failed");
		expect(restore.trace_count == i,
			"activation-positive reverse unwind count differs");
		for (restored = 0; restored < i; restored++) {
			u32 source = i - restored - 1;

			expect(restore.trace[restored] ==
			       rockchip_pm_compiled_maximal.regulators[0].on[source] &&
			       restore.states[restored] == ROCKCHIP_SUSPEND_MODEL_MEM &&
			       restore.previous[restored] == 11 * (int)(source + 1),
				"activation-positive reverse unwind arguments differ");
		}
		rockchip_suspend_model_transaction_poison(&transaction);
		expect(rockchip_suspend_model_transaction_begin(&transaction) == -EIO &&
		       restore.trace_count == i,
			"activation-positive poisoned retry executed an action");
	}
}

int main(int argc, char **argv)
{
	if (argc == 2 && !strcmp(argv[1], "--activation-positive")) {
		test_activation_positive();
		puts("RESULT: activation-positive fake-only Rockchip PM scenario PASS");
		return 0;
	}
	expect(argc == 1, "unknown test mode");
	test_bindings();
	test_probe();
	test_prepare_and_virtual_poweroff();
	test_suspend_state_override();
	test_rejections_and_nonmutation();
	test_status_mappings();
	test_executor();
	test_pm_prepare_order();
	test_transaction_retry_and_poison();
	puts("RESULT: extracted Rockchip PM model and fake executor tests PASS");
	return 0;
}
