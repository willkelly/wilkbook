#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
inspector="$script_dir/inspect-pinenote-battery-dtb.sh"

if ! command -v dtc >/dev/null 2>&1; then
  printf 'FAIL: dtc is required for generated-DTB inspector tests\n' >&2
  exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-inspect-pinenote-battery-dtb.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

write_fixture() {
  profile=$1
  monitored=$2
  compatible=$3
  fixture=$4
  cat >"$fixture" <<EOF
/dts-v1/;

/ {
	#address-cells = <1>;
	#size-cells = <0>;
	compatible = $compatible;

	battery: battery {
		phandle = <1>;
		compatible = "simple-battery";
		charge-full-design-microamp-hours = <4000000>;
		charge-term-current-microamp = <300000>;
		constant-charge-current-max-microamp = <2000000>;
		constant-charge-voltage-max-microvolt = <4200000>;
		factory-internal-resistance-micro-ohms = <96000>;
		voltage-max-design-microvolt = <4200000>;
		voltage-min-design-microvolt = <3500000>;
		ocv-capacity-celsius = <20>;
		ocv-capacity-table-0 = <$profile>;
	};

	wrong: wrong-battery {
		phandle = <2>;
		compatible = "simple-battery";
	};

	pmic-bus {
		#address-cells = <1>;
		#size-cells = <0>;
		pmic@20 {
			reg = <0x20>;
			charger {
				monitored-battery = <$monitored>;
				rockchip,resistor-sense-micro-ohms = <10000>;
				rockchip,sleep-enter-current-microamp = <150000>;
				rockchip,sleep-filter-current-microamp = <100000>;
			};
		};
	};
};
EOF
}

profile='4168000 100 4109000 95 4066000 90 4023000 85 3985000 80 3954000 75 3924000 70 3897000 65 3866000 60 3826000 55 3804000 50 3789000 45 3777000 40 3770000 35 3763000 30 3750000 25 3732000 20 3710000 15 3680000 10 3670000 5 3500000 0'
write_fixture "$profile" '&battery' '"pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"' "$tmpdir/good.dts"
write_fixture "$profile" '&wrong' '"pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"' "$tmpdir/wrong-phandle.dts"
write_fixture '4168000 99' '&battery' '"pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"' "$tmpdir/wrong-profile.dts"
write_fixture "$profile" '&battery' '"vendor,other-tablet"' "$tmpdir/wrong-compatible.dts"

for fixture in good wrong-phandle wrong-profile wrong-compatible; do
  dtc -I dts -O dtb -o "$tmpdir/$fixture.dtb" "$tmpdir/$fixture.dts"
done

sh "$inspector" "$tmpdir/good.dtb"
if sh "$inspector" "$tmpdir/wrong-phandle.dtb"; then
  printf 'FAIL: inspector accepted wrong monitored-battery phandle\n' >&2
  exit 1
fi
if sh "$inspector" "$tmpdir/wrong-profile.dtb"; then
  printf 'FAIL: inspector accepted wrong OCV profile\n' >&2
  exit 1
fi
if sh "$inspector" "$tmpdir/wrong-compatible.dtb"; then
  printf 'FAIL: inspector accepted wrong root compatible\n' >&2
  exit 1
fi

printf 'PASS: generated-DTB inspector rejects wrong compatible, phandle, and profile fixtures\n'
