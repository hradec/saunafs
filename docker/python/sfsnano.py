#!/usr/bin/env python3
"""Cluster-wide SaunaFS configuration collector.

This tool retrieves a configuration file from every SaunaFS node reported by
`saunafs-admin list-chunkservers` and `saunafs-admin list-metadataservers` and
constructs a merged view. Lines that differ between nodes are annotated with the
originating IP address to make cluster-wide edits easier.
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections import OrderedDict, defaultdict


def run_shell(command):
    """Run *command* using the shell and return stdout as a list of stripped lines."""
    try:
        output = subprocess.check_output(
            command, shell=True, stderr=subprocess.PIPE, universal_newlines=True
        )
    except subprocess.CalledProcessError as err:
        sys.stderr.write(
            "[sfsnano] Command failed (exit {}): {}\n{}".format(
                err.returncode, command, err.stderr
            )
        )
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]





def collect_ips(admin_host, admin_port):
    """Collect unique IP addresses for chunkservers and metadataservers."""
    # Discovery pipelines provided by the user; keep exactly as supplied.
    commands = [
        f"saunafs-admin list-chunkservers {admin_host} {admin_port} | grep Server | sed 's/Server //' | sed 's/:.*//'",
        f"saunafs-admin list-metadataservers {admin_host} {admin_port} | grep IP | sed 's/.*: //'",
    ]

    ips = []
    seen = set()

    for template in commands:
        # Use .format() so the command definition can adopt future placeholders.
        lines = run_shell(template.format(host=admin_host, port=admin_port))
        for line in lines:
            if line not in seen:
                seen.add(line)
                ips.append(line)

    return ips


def fetch_remote_file(ip, remote_path, ssh_user, ssh_timeout, extra_ssh_args):
    """Retrieve *remote_path* from *ip* via ssh and return the raw text."""
    target = ip if not ssh_user else "{}@{}".format(ssh_user, ip)

    ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
    if ssh_timeout:
        ssh_cmd.extend(["-o", "ConnectTimeout={}".format(ssh_timeout)])
    if extra_ssh_args:
        ssh_cmd.extend(extra_ssh_args)

    ssh_cmd.extend([target, "cat", remote_path])

    try:
        output = subprocess.check_output(ssh_cmd, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as err:
        raise RuntimeError(
            "ssh {} failed (exit {}): {}".format(
                target, err.returncode, err.stderr.decode(errors="ignore")
            )
        )

    return output.decode(errors="ignore")


_IP_PREFIX_RE = re.compile(r"^(?P<ip>(?:\d{1,3}\.){3}\d{1,3})\s+(?P<core>.+)$")
_EDITED_PREFIX_RE = re.compile(r"^\s*(?P<ip>(?:\d{1,3}\.){3}\d{1,3})\s*:\s*(?P<core>.*)$")


def _strip_prefix(line):
    """Return (ip, core) when the line already carries an IP prefix."""
    match = _IP_PREFIX_RE.match(line.strip())
    if match:
        return match.group("ip"), match.group("core")
    return None, line


def align_lines(per_host_lines):
    """Build the merged view from a mapping of host->list of lines."""
    if not per_host_lines:
        return []

    hosts = list(per_host_lines.keys())

    per_host_entries = {}
    global_order = []
    seen_keys = set()

    for host in hosts:
        lines = per_host_lines[host]
        entries = []
        assign_counts = defaultdict(int)  # Track repeated assignments per key
        filler_idx = 0  # Keep unique ordering hints for comments/blank lines

        for line in lines:
            prefix, core = _strip_prefix(line)
            stripped_core = core.strip()
            if stripped_core and not stripped_core.startswith("#") and "=" in core:
                key_base = core.split("=", 1)[0].strip()
                assign_counts[key_base] += 1
                key = f"A::{key_base}::{assign_counts[key_base]}"
                allow_prefix = True
            else:
                filler_idx += 1
                key = f"F::{filler_idx}::{host}"
                allow_prefix = False

            entry = {
                "key": key,
                "core": core,
                "allow_prefix": allow_prefix,
            }
            entries.append(entry)

        per_host_entries[host] = {entry["key"]: entry for entry in entries}

        for entry in entries:
            key = entry["key"]
            if key not in seen_keys:
                # Record first occurrence so we can replay keys in a deterministic order.
                global_order.append(key)
                seen_keys.add(key)

    merged = []

    for key in global_order:
        # Collect every host that actually emitted this key.
        available = []
        for host in hosts:
            entry = per_host_entries[host].get(key)
            if entry is None:
                continue
            available.append((host, entry))

        if not available:
            continue

        # Group by line content so shared values can be emitted once.
        core_groups = OrderedDict()
        for host, entry in available:
            core_groups.setdefault(entry["core"], []).append((host, entry))

        nonpref_lines = []
        unique_pref = []

        for core, items in core_groups.items():
            # Any group that contains a comment/blank (allow_prefix == False)
            # must be emitted exactly as-is to preserve formatting.
            if any(not item[1]["allow_prefix"] for item in items):
                nonpref_lines.append(core)
                continue

            if len(items) > 1:
                nonpref_lines.append(core)
            else:
                host = items[0][0]
                unique_pref.append((host, core))

        for line in nonpref_lines:
            # Skip extra blank lines once content has started to keep the tail tidy.
            # if not line.strip() and merged:
            #     continue
            merged.append(line)
        for host, core in unique_pref:
            merged.append(f"{host}:{core}")

    # Remove any trailing whitespace-only lines to avoid extra noise at EOF.
    while merged and (not merged[-1].strip() or merged[-1].strip()[0] == "#"):
        merged.pop()

    return merged


def _assignment_key(line):
    """Return assignment key (lhs) or None for non-assignment lines."""
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        return None
    return line.split("=", 1)[0].strip()


def build_host_configs(lines, hosts):
    """Generate per-host configuration content from edited merged lines."""
    host_lines = {ip: [] for ip in hosts}
    host_positions = {ip: {} for ip in hosts}
    host_occurrence = {ip: defaultdict(int) for ip in hosts}
    ignored_ips = set()

    def append_line(ip, text):
        key = _assignment_key(text)
        host_lines[ip].append(text)
        if key:
            host_occurrence[ip][key] += 1
            occ = host_occurrence[ip][key]
            host_positions[ip][(key, occ)] = len(host_lines[ip]) - 1
        return key

    for raw_line in lines:
        match = _EDITED_PREFIX_RE.match(raw_line)
        if match:
            ip = match.group("ip")
            core = match.group("core")
            if ip not in host_lines:
                ignored_ips.add(ip)
                continue
            key = _assignment_key(core)
            if key and host_occurrence[ip].get(key, 0) > 0:
                occ = host_occurrence[ip][key]
                idx = host_positions[ip].get((key, occ))
                if idx is not None:
                    host_lines[ip][idx] = core
                else:
                    append_line(ip, core)
            else:
                append_line(ip, core)
            continue

        for ip in hosts:
            append_line(ip, raw_line)

    return host_lines, ignored_ips


def write_remote_file(ip, remote_path, data, ssh_user, ssh_timeout, extra_ssh_args):
    """Upload *data* to *remote_path* on *ip* via ssh."""
    target = ip if not ssh_user else f"{ssh_user}@{ip}"

    ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
    if ssh_timeout:
        ssh_cmd.extend(["-o", f"ConnectTimeout={ssh_timeout}"])
    if extra_ssh_args:
        ssh_cmd.extend(extra_ssh_args)

    ssh_cmd.extend([target, f"cat > {shlex.quote(remote_path)}"])

    proc = subprocess.Popen(
        ssh_cmd,
        stdin=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    _, stderr_data = proc.communicate(data)
    if proc.returncode != 0:
        raise RuntimeError(
            "ssh {} failed (exit {}): {}".format(
                target, proc.returncode, stderr_data.strip()
            )
        )


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Cluster SaunaFS cfg aggregator")
    parser.add_argument(
        "filename",
        help="Configuration filename located under /etc/saunafs on each node",
    )
    parser.add_argument(
        "--admin-host",
        default="240.0.0.1",
        help="Controller IP passed to saunafs-admin (default: %(default)s)",
    )
    parser.add_argument(
        "--admin-port",
        type=int,
        default=9421,
        help="Controller port passed to saunafs-admin (default: %(default)s)",
    )
    parser.add_argument(
        "--output",
        "-o",
        help="Optional output file; defaults to stdout",
    )
    parser.add_argument(
        "--ssh-user",
        default='root',
        help="Username for ssh connections (default: root)",
    )
    parser.add_argument(
        "--ssh-timeout",
        type=int,
        default=10,
        help="Seconds to wait before aborting ssh connections (default: %(default)s)",
    )
    parser.add_argument(
        "--ssh-arg",
        action="append",
        dest="ssh_args",
        default=[],
        help="Additional -o style options forwarded to ssh (may be repeated)",
    )
    parser.add_argument(
        "-r",
        "--restart",
        nargs="+",
        help=(
            "Restart services after updating hosts. Options: 'uraft', 'chunk', 'master', "
            "'all', or 'custom <command ...>'. Multiple commands are run sequentially on "
            "each host; 'custom' executes the remaining arguments verbatim."
        ),
    )
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)

    ips = collect_ips(args.admin_host, args.admin_port)
    if not ips:
        sys.stderr.write("[sfsnano] No cluster IPs discovered.\n")
        return 1

    remote_path = os.path.normpath(os.path.join("/etc/saunafs", args.filename))

    retrieved = OrderedDict()
    errors = {}

    for ip in ips:
        try:
            raw = fetch_remote_file(
                ip,
                remote_path,
                args.ssh_user,
                args.ssh_timeout,
                args.ssh_args,
            )
        except RuntimeError as err:
            errors[ip] = str(err)
            continue

        lines = raw.splitlines()
        if raw.endswith("\n"):
            lines.append("")
        retrieved[ip] = lines

    if not retrieved:
        sys.stderr.write("[sfsnano] Failed to retrieve {} from every host.\n".format(remote_path))
        for ip, message in errors.items():
            sys.stderr.write("[sfsnano] {}: {}\n".format(ip, message))
        return 2

    # Reconcile per-host copies into a single, ordered view.
    merged_lines = align_lines(retrieved)

    output_data = "\n".join(merged_lines)
    if not output_data.endswith("\n"):
        output_data += "\n"

    created_temp = False
    if args.output:
        target_path = args.output
        with open(target_path, "w", encoding="utf-8") as handle:
            handle.write(output_data)
    else:
        tmp = tempfile.NamedTemporaryFile(
            mode="w", delete=False, encoding="utf-8", prefix="sfsnano-", suffix=".cfg"
        )
        tmp.write(output_data)
        tmp.flush()
        target_path = tmp.name
        tmp.close()
        created_temp = True

    try:
        subprocess.run(["nano", target_path], check=True)
    except FileNotFoundError:
        sys.stderr.write("[sfsnano] nano command not found.\n")
        return 3
    except subprocess.CalledProcessError as err:
        sys.stderr.write(
            "[sfsnano] nano exited with {} while editing {}.\n".format(
                err.returncode, target_path
            )
        )
        return err.returncode

    try:
        with open(target_path, "r", encoding="utf-8") as handle:
            edited_lines = handle.read().splitlines()
    except OSError as exc:
        sys.stderr.write(
            "[sfsnano] Failed to read edited data from {}: {}\n".format(
                target_path, exc
            )
        )
        return 6

    active_hosts = list(retrieved.keys())
    host_configs, ignored_ips = build_host_configs(edited_lines, active_hosts)

    if ignored_ips:
        sys.stderr.write(
            "[sfsnano] Ignored overrides for unknown hosts: {}\n".format(
                ", ".join(sorted(ignored_ips))
            )
        )

    push_errors = {}
    for ip in active_hosts:
        lines = host_configs[ip]
        content = "\n".join(lines)
        # open(f"/tmp/{os.path.basename(remote_path)}.{ip}", "w").write(content)
        if not content.endswith("\n"):
            content += "\n"
        try:
            print(f"[sfsnano] Pushing updated config to {ip}...")
            write_remote_file(
                ip,
                remote_path,
                content,
                args.ssh_user,
                args.ssh_timeout,
                args.ssh_args,
            )
        except RuntimeError as err:
            push_errors[ip] = str(err)
            continue

    if created_temp:
        try:
            os.unlink(target_path)
        except OSError:
            pass

    if push_errors:
        sys.stderr.write("[sfsnano] Failed to update remote files:\n")
        for ip, message in push_errors.items():
            sys.stderr.write("  {} -> {}\n".format(ip, message))
        return 7
    else:
        sys.stderr.write(
            "[sfsnano] Updated {} on {} host(s).\n".format(
                remote_path, len(active_hosts)
            )
        )

    restart_commands = []
    try:
        restart_commands = parse_restart_arguments(args.restart)
    except ValueError as exc:
        sys.stderr.write("[sfsnano] {}\n".format(exc))
        return 8

    restart_errors = {}
    for command in restart_commands:
        sys.stderr.write(f"[sfsnano] Running '{command}' on all hosts...\n")
        for ip in active_hosts:
            try:
                output = run_remote_command(
                    ip,
                    command,
                    args.ssh_user,
                    args.ssh_timeout,
                    args.ssh_args,
                )
                stdout = output.strip()
                if stdout:
                    sys.stderr.write(f"  {ip} -> {stdout}\n")
                else:
                    sys.stderr.write(f"  {ip} -> (no output)\n")
            except RuntimeError as err:
                restart_errors.setdefault(ip, []).append(str(err))

    if restart_errors:
        sys.stderr.write("[sfsnano] Restart commands reported errors:\n")
        for ip, messages in restart_errors.items():
            for message in messages:
                sys.stderr.write("  {} -> {}\n".format(ip, message))
        return 9

    if errors:
        sys.stderr.write("[sfsnano] Completed with partial errors:\n")
        for ip, message in errors.items():
            sys.stderr.write("  {} -> {}\n".format(ip, message.strip()))

    return 0


def run_remote_command(ip, command, ssh_user, ssh_timeout, extra_ssh_args):
    """Execute *command* on *ip* via ssh."""
    target = ip if not ssh_user else f"{ssh_user}@{ip}"

    ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
    if ssh_timeout:
        ssh_cmd.extend(["-o", f"ConnectTimeout={ssh_timeout}"])
    if extra_ssh_args:
        ssh_cmd.extend(extra_ssh_args)

    ssh_cmd.extend([target, command])

    result = subprocess.run(ssh_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            "ssh {} failed (exit {}): {}".format(
                target,
                result.returncode,
                (result.stderr or result.stdout).strip(),
            )
        )
    return result.stdout.strip()
def parse_restart_arguments(restart_args):
    if not restart_args:
        return []

    target = restart_args[0]
    if target == "all":
        return [
            "systemctl restart saunafs-uraft",
            "systemctl restart saunafs-chunkserver",
            "saunafs-uraft-helper reload-saunafs-ha-master",
        ]
    if target == "uraft":
        return ["systemctl restart saunafs-uraft"]
    if target == "chunk":
        return ["systemctl restart saunafs-chunkserver"]
    if target == "master":
        return ["saunafs-uraft-helper reload-saunafs-ha-master"]
    if target == "custom":
        if len(restart_args) == 1:
            raise ValueError("custom restart requires a command to execute")
        return [" ".join(restart_args[1:])]

    raise ValueError(
        "Unknown restart option '{}'. Choose from: uraft, chunk, master, all, custom".format(
            target
        )
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
