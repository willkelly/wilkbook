#!/usr/bin/env python3
"""Record and enforce the no-NIC network namespace used for Bazel analysis."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path
from typing import Any


class NamespaceError(Exception):
    """The required network namespace boundary is absent or incomplete."""


FORBIDDEN_NETWORK_VARIABLES = (
    "ALL_PROXY",
    "FTP_PROXY",
    "GOINSECURE",
    "GONOPROXY",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "all_proxy",
    "ftp_proxy",
    "https_proxy",
    "http_proxy",
    "no_proxy",
)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise NamespaceError(f"cannot inspect {path}: {error}") from error


def interface_inventory() -> list[dict[str, Any]]:
    root = Path("/sys/class/net")
    result = []
    for ifindex, name in sorted(socket.if_nameindex(), key=lambda item: item[1]):
        path = root / name
        details = {
            "address": None,
            "operstate": None,
            "type": None,
        }
        if path.is_dir():
            details = {
                "address": read_text(path / "address"),
                "operstate": read_text(path / "operstate"),
                "type": int(read_text(path / "type")),
            }
        result.append(
            {
                **details,
                "ifindex": ifindex,
                "name": name,
            }
        )
    return result


def ipv4_routes() -> list[dict[str, str]]:
    lines = read_text(Path("/proc/net/route")).splitlines()
    if not lines:
        return []
    fields = lines[0].split()
    return [dict(zip(fields, line.split(), strict=False)) for line in lines[1:] if line.strip()]


def ipv6_routes() -> list[dict[str, str]]:
    result = []
    for line in read_text(Path("/proc/net/ipv6_route")).splitlines():
        fields = line.split()
        if len(fields) != 10:
            raise NamespaceError(f"unexpected /proc/net/ipv6_route row: {line}")
        result.append(
            {
                "destination": fields[0],
                "destination_prefix": fields[1],
                "flags": fields[8],
                "interface": fields[9],
                "metric": fields[5],
                "next_hop": fields[4],
                "source": fields[2],
                "source_prefix": fields[3],
            }
        )
    return result


def snapshot() -> dict[str, Any]:
    try:
        identity = os.readlink("/proc/self/ns/net")
    except OSError as error:
        raise NamespaceError(f"cannot inspect network namespace identity: {error}") from error
    return {
        "interfaces": interface_inventory(),
        "ipv4_routes": ipv4_routes(),
        "ipv6_routes": ipv6_routes(),
        "namespace": identity,
    }


def external_interfaces(state: dict[str, Any]) -> list[str]:
    return sorted(item["name"] for item in state["interfaces"] if item["name"] != "lo")


def external_routes(state: dict[str, Any]) -> list[dict[str, str]]:
    result = [item for item in state["ipv4_routes"] if item.get("Iface") != "lo"]
    result.extend(item for item in state["ipv6_routes"] if item.get("interface") != "lo")
    return result


def validate_state(state: Any, context: str) -> dict[str, Any]:
    if not isinstance(state, dict) or set(state) != {
        "interfaces",
        "ipv4_routes",
        "ipv6_routes",
        "namespace",
    }:
        raise NamespaceError(f"invalid {context} namespace snapshot")
    if not isinstance(state["namespace"], str) or not state["namespace"].startswith("net:["):
        raise NamespaceError(f"invalid {context} namespace identity")
    for key in ("interfaces", "ipv4_routes", "ipv6_routes"):
        if not isinstance(state[key], list):
            raise NamespaceError(f"invalid {context} {key} inventory")
    return state


def load_snapshot(path: Path, context: str) -> dict[str, Any]:
    try:
        return validate_state(json.loads(path.read_text(encoding="utf-8")), context)
    except (OSError, json.JSONDecodeError) as error:
        raise NamespaceError(f"cannot read {context} namespace snapshot: {error}") from error


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def assert_isolated(outer_path: Path, evidence_path: Path) -> str:
    outer = load_snapshot(outer_path, "outer")
    inner = validate_state(snapshot(), "inner")
    if inner["namespace"] == outer["namespace"]:
        raise NamespaceError("network namespace did not change from the outer process")
    names = sorted(item["name"] for item in inner["interfaces"])
    if names != ["lo"]:
        raise NamespaceError(f"isolated namespace has non-loopback interfaces: {names}")
    routes = external_routes(inner)
    if routes:
        raise NamespaceError("isolated namespace has external routes")
    evidence = {
        "assertions": {
            "external_interfaces": [],
            "external_routes": [],
            "namespace_changed": True,
            "only_loopback_interface": True,
        },
        "inner": inner,
        "outer": outer,
        "schema": 1,
    }
    write_json(evidence_path, evidence)
    return inner["namespace"]


def append_exec_event(path: Path, label: str, expected: str) -> None:
    state = validate_state(snapshot(), "analysis process")
    if state["namespace"] != expected:
        raise NamespaceError(f"analysis process escaped network namespace: {label}")
    interfaces = external_interfaces(state)
    routes = external_routes(state)
    if interfaces or routes:
        raise NamespaceError(f"analysis process has external network access: {label}")
    forbidden = sorted(name for name in FORBIDDEN_NETWORK_VARIABLES if os.environ.get(name))
    go_environment = {
        name: os.environ.get(name)
        for name in ("GONOSUMDB", "GOPRIVATE", "GOPROXY", "GOSUMDB")
    }
    if forbidden:
        raise NamespaceError(f"analysis process inherited network bypass variables: {forbidden}")
    if (
        not (go_environment["GOPROXY"] or "").startswith("file://")
        or go_environment != {
            "GONOSUMDB": "*",
            "GOPRIVATE": "",
            "GOPROXY": go_environment["GOPROXY"],
            "GOSUMDB": "off",
        }
    ):
        raise NamespaceError(f"analysis process has unsafe Go network environment: {label}")
    event = {
        "external_interfaces": interfaces,
        "external_routes": routes,
        "forbidden_network_variables_present": forbidden,
        "go_environment": go_environment,
        "label": label,
        "namespace": state["namespace"],
        "pid_before_exec": os.getpid(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write(json.dumps(event, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())


def check_events(path: Path, evidence_path: Path, expected: str, labels: list[str]) -> None:
    try:
        events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    except (OSError, json.JSONDecodeError) as error:
        raise NamespaceError(f"cannot read analysis namespace events: {error}") from error
    if [item.get("label") for item in events] != labels:
        raise NamespaceError("analysis namespace event sequence changed")
    for event in events:
        if (
            event.get("namespace") != expected
            or event.get("external_interfaces") != []
            or event.get("external_routes") != []
            or event.get("forbidden_network_variables_present") != []
            or not (event.get("go_environment", {}).get("GOPROXY") or "").startswith("file://")
            or event.get("go_environment", {}).get("GOSUMDB") != "off"
            or event.get("go_environment", {}).get("GONOSUMDB") != "*"
            or event.get("go_environment", {}).get("GOPRIVATE") != ""
        ):
            raise NamespaceError(f"invalid analysis namespace event: {event.get('label')}")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    evidence["analysis_exec_events"] = events
    write_json(evidence_path, evidence)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture = subparsers.add_parser("capture")
    capture.add_argument("--output", type=Path, required=True)
    isolated = subparsers.add_parser("assert-isolated")
    isolated.add_argument("--outer", type=Path, required=True)
    isolated.add_argument("--evidence", type=Path, required=True)
    execute = subparsers.add_parser("exec")
    execute.add_argument("--expected", required=True)
    execute.add_argument("--events", type=Path, required=True)
    execute.add_argument("--label", required=True)
    execute.add_argument("argv", nargs=argparse.REMAINDER)
    check = subparsers.add_parser("check-events")
    check.add_argument("--expected", required=True)
    check.add_argument("--events", type=Path, required=True)
    check.add_argument("--evidence", type=Path, required=True)
    check.add_argument("--labels", required=True)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            write_json(args.output, snapshot())
        elif args.command == "assert-isolated":
            print(assert_isolated(args.outer, args.evidence))
        elif args.command == "exec":
            argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not argv:
                raise NamespaceError("network namespace exec has no command")
            append_exec_event(args.events, args.label, args.expected)
            os.execvp(argv[0], argv)
        else:
            check_events(
                args.events,
                args.evidence,
                args.expected,
                args.labels.split(","),
            )
    except (NamespaceError, OSError, ValueError) as error:
        print(f"network namespace: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
