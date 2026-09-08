# Native Relay Management Design

**Status:** Approved design

**Source requirements:** `SNELL-SUPPORT-REQUIREMENTS.md`, section 4

**Target:** MVP management of fixed-target native `direct` relay in the
`233boy-sing-box-fork` script.

## Goal

Allow users to create, inspect, list, and delete fixed-target TCP/UDP relay
entries through the existing `sing-box` management command while preserving
the behavior and file format of existing protocol nodes and the legacy
`add direct` flow.

The relay is implemented by sing-box itself. The script will not install or
start Realm, socat, iptables redirect rules, or another forwarding daemon.

## Scope

The MVP includes:

- `relay add [local-port] [remote-address] [remote-port]`.
- `relay list` and `relay info [local-port]`.
- `relay delete [local-port]`.
- An interactive relay submenu when `relay` has no subcommand.
- One relay JSON file per local listening port.
- Native `direct` inbound configuration with `override_address` and
  `override_port`.
- Default dual-protocol behavior: TCP and UDP are both supported.
- Local port validation against active listeners and all saved node/relay
  configurations.
- Temporary-file validation and atomic installation for additions.
- Rollback-safe deletion when the complete runtime configuration fails
  validation.
- A clear warning that an unauthenticated public relay must be restricted by
  a firewall or network ACL.
- Offline tests against both `core.sh` and `src/core.sh`.

The MVP excludes relay authentication, source IP ACL configuration, rate
limiting, traffic statistics, health checks, failover, load balancing,
dynamic target updates, relay-specific share links, and `relay change`.

## Repository Boundaries

The installed script loads `src/core.sh`. The repository also keeps a root
`core.sh` used by the local test suite and release artifact. These files have
unrelated historical differences, so the implementation must apply the same
relay behavior to both files without replacing either file wholesale.

The existing `add direct` command is a legacy generic configuration path. It
will remain available and unchanged in user-facing behavior. New relay
commands use dedicated relay helpers and a relay filename prefix, which keeps
relay lifecycle operations separate from generic node operations.

The release workflow already packages `core.sh`, `sing-box.sh`, `src/`, and
the documentation. No workflow change is required unless verification shows
that a new file must be included in the release archive.

## Data Model

Each relay is stored at:

```text
$is_conf_dir/relay-<local-port>.json
```

The JSON shape is:

```json
{
  "inbounds": [
    {
      "tag": "relay-10000.json",
      "type": "direct",
      "listen": "::",
      "listen_port": 10000,
      "override_address": "203.0.113.10",
      "override_port": 20000
    }
  ]
}
```

The `network` field is intentionally omitted. Its absence preserves the
native direct inbound's TCP and UDP behavior. The info view renders this
effective value as `tcp,udp` rather than implying that the field is present
in JSON.

The remote address is stored as a string using `jq --arg`; the remote port is
stored as a JSON number using `jq --argjson`. The script requires a non-empty
remote address and does not perform custom DNS resolution or dynamic target
updates. A static hostname, if accepted by sing-box validation, is passed
unchanged.

Relay files have no `.quan-meta` record. They are operational forwarding
entries, not shareable protocol nodes, so no node name, URL, QR value, or
credential metadata is generated.

## Command Flow

### Dispatch

`main()` receives `relay` before the generic unknown-command path and calls a
relay dispatcher. The dispatcher handles `add`, `list`, `info`, and `delete`;
an omitted subcommand opens the relay submenu. Unknown subcommands fail with
the documented relay syntax.

The main interactive menu gains a `中转管理` item appended without
renumbering existing menu entries. The submenu contains add, list/info,
delete, and return actions.

### Add

`relay add` accepts the three positional values in the documented order. If a
value is omitted, the interactive path prompts for it. `auto` is accepted for
the local port and uses the existing random-port helper. The remote address
must be non-empty after trimming; both port values must be in `1-65535`.

Before any file is installed, the command checks:

1. The local port is not used by an active listener.
2. The local port is not present in any saved inbound under
   `$is_conf_dir/*.json`, including existing relay files and protocol nodes.
3. The remote port is valid.
4. The remote address is non-empty.

The command then generates a same-directory temporary JSON file, validates it
with the configured sing-box binary, and moves it to
`relay-<local-port>.json` only after validation succeeds. If a complete
`config.json` exists, the runtime configuration is checked with the conf
directory after installation. A failed complete check removes the new relay
and leaves the service untouched.

After successful installation and validation, the command restarts sing-box
through the existing `manage restart` helper and prints the relay parameters.
It also prints the public unauthenticated relay warning.

### List and Info

`relay list` enumerates only `relay-*.json` files. It prints one compact row
per relay containing the local port, remote address, and remote port, followed
by the effective network value. `relay info <local-port>` prints the full
fields:

```text
type = direct
listen = ::
listen_port = 10000
override_address = 203.0.113.10
override_port = 20000
network = tcp,udp
```

Both commands use the same parser and warning helper. They never call the
generic URL or QR path and never expose a pseudo share link.

### Delete

`relay delete <local-port>` resolves only the corresponding relay filename;
it must not delete a protocol node that happens to use the same number in a
different filename. The command moves the relay file to a same-directory
temporary backup, checks the complete runtime configuration when
`config.json` exists, and permanently removes the backup only after the check
passes. If validation fails, the backup is moved back to its original path
and the service is not restarted.

On successful deletion, the existing runtime outbound synchronization is run
as needed and sing-box is restarted through `manage restart`.

## Shared Helpers and Compatibility

The existing saved-port scan is generalized to a neutral helper such as
`config_port_used <port> [current-config]`. The current
`snell_config_port_used` interface remains as a compatibility wrapper so the
already implemented Snell tests and behavior continue to work. Both Snell
and relay validation use the shared scan, which makes their local ports
mutually exclusive.

The active listener check remains the existing `is_port_used` mechanism. Relay
validation does not use the TLS-specific port exceptions in the generic node
path.

`sync_runtime_node_outbound_modes` may continue scanning all JSON files,
because relay files have no outbound metadata and are ignored. `fix-all` must
explicitly skip `relay-*.json`; otherwise the generic Direct change flow could
rename or rewrite a relay file. Generic protocol nodes, including existing
`Direct-*.json` files, retain their current behavior.

## Validation and Error Handling

Validation is fail-closed:

- Invalid local or remote ports fail before temporary file creation.
- Empty remote addresses fail before temporary file creation.
- Active or saved local-port conflicts fail without modifying any file.
- JSON values are passed through jq data arguments, not shell-generated JSON
  fragments.
- Any fragment or complete-config check failure removes only the new
  temporary/candidate file and does not restart the service.
- Deletion check failures restore the original relay file before returning an
  error.
- Temporary files are removed on success, failure, and test-mode exits.
- Errors identify the affected local port and explain the required correction.

The security warning is emitted because a direct relay has no built-in
authentication in this MVP. It recommends restricting the listening address
with a host firewall or network ACL and does not claim that the relay is
safe for unrestricted public exposure.

## Testing Strategy

Create `tests-relay-support.sh` as an offline integration-style test. It will
source each of `core.sh` and `src/core.sh` in an isolated child shell, set
temporary config paths, override `manage`, and use a deterministic fake
sing-box binary.

The fake binary must support:

- `version`, for stable test setup.
- `check -c <file>`, validating a direct relay fragment.
- Complete-config checking with the configured conf directory, including a
  switch that rejects a candidate to exercise rollback.

The test matrix covers:

- `relay add` with explicit values and correct JSON types/fields.
- IPv6 remote addresses and JSON-safe special characters.
- Omitted local port through deterministic `get_port` behavior.
- Invalid local/remote ports and empty remote address.
- Conflict with active listeners, saved protocol nodes, and another relay.
- Fragment-check failure with no installed file or restart.
- Complete-config failure with candidate removal and no restart.
- `relay list` and `relay info` output, including `network=tcp,udp`.
- Security warning content mentioning firewall or ACL restriction.
- Delete success, delete validation failure, restoration, and restart count.
- `fix-all` skipping relay files.
- Both core script copies preserving their unrelated differences.

Existing `tests-snell-support.sh` and `tests-node-name-label.sh` remain part of
the final verification set. Real TCP/UDP forwarding and client
interoperability remain environment-dependent manual acceptance tests and
must be reported separately from offline test results.

## Documentation

Update `src/help.sh` and the static help block in `README.md` with:

- The four relay commands and their argument order.
- The interactive relay management entry.
- The fact that the relay is native sing-box `direct` and supports TCP/UDP.
- The lack of relay authentication in the MVP.
- The requirement to restrict public relay access using a firewall or
  network ACL.
- The fact that relay entries do not produce protocol URLs or QR codes.

Do not change the existing Snell requirements or unrelated protocol help.

## Acceptance Criteria

- `sing-box relay add 10000 203.0.113.10 20000` creates the expected
  `relay-10000.json` with a native `direct` inbound.
- The generated file passes sing-box validation before installation.
- TCP and UDP are both represented by the omitted `network` field and are
  reported as `tcp,udp` by info/list output.
- `relay list` and `relay info 10000` display all required relay fields.
- `relay delete 10000` removes only the relay file and restarts only after
  successful complete-config validation.
- Local relay ports conflict with existing protocol and relay ports.
- Validation failures preserve previous files and do not restart sing-box.
- Public unauthenticated relay creation displays the firewall/ACL warning.
- No Realm process, Realm config, pseudo share URL, or QR payload is created.
- Existing protocol tests pass, and relay behavior is equivalent in
  `core.sh` and `src/core.sh`.
- Manual TCP/UDP forwarding checks are recorded separately when a suitable
  sing-box host is available.
