# Snell v5 Support Design

**Status:** Approved design

**Source requirements:** `SNELL-SUPPORT-REQUIREMENTS.md`

**Target:** MVP support for native Snell v5 inbound configuration in the
`233boy-sing-box-fork` management script.

## Goal

Allow the existing script to add, inspect, modify, validate, restart, and
delete Snell v5 inbound nodes while preserving the current per-node JSON
layout and behavior of all existing protocols.

The implementation targets `sing-box >= 1.14.0`. It does not install or
manage `snell-server`, add a compatibility layer, or implement Snell
outbound configuration.

## Scope

The MVP includes:

- `Snell` in the interactive protocol list.
- `add snell [port] [psk] [version]` with version 5 as the default.
- Secure random PSK generation when the PSK is omitted.
- Default `obfs_mode` of `none`, with `none` and `http` accepted for changes.
- Port validation and conflict detection against active listeners and saved
  node JSON files.
- Native Snell inbound JSON generation.
- `info` output for protocol, address, port, version, PSK, and obfuscation.
- Changes to port, PSK, version, and obfuscation mode.
- Atomic temporary-file validation before a Snell configuration is replaced.
- Deletion and normal service restart behavior through existing helpers.
- Explicit unsupported messages for Snell `url` and `qr` commands.

The MVP excludes Snell v6, multi-user management, Snell outbound nodes,
official server installation, Docker, client-specific share formats, QUIC
Proxy Mode, and ShadowTLS composition.

## Repository Boundaries

The runtime installation loads `src/core.sh`, while the release archive also
contains the root `core.sh` and the local test suite sources the root copy.
The two core files contain unrelated historical differences, so the
implementation will not replace one file with the other wholesale.

`src/core.sh` is the runtime implementation baseline. The same Snell-specific
behavior will be applied to the root `core.sh` while preserving its existing
non-Snell differences. Tests will execute the same cases against both files.
This makes synchronization an explicit behavioral contract without causing an
unrelated full-file merge.

## Data Model

Snell state is represented by dedicated shell variables:

- `snell_version`
- `snell_psk`
- `snell_obfs_mode`

The implementation must not use a generated UUID as the default PSK or expose
Snell credentials through the existing UUID/password aliases.

The generated per-node file follows the existing configuration directory
layout. Its inbound contains only the fields required by this MVP:

```json
{
  "inbounds": [
    {
      "tag": "snell-<port>.json",
      "type": "snell",
      "listen": "::",
      "listen_port": 6160,
      "version": 5,
      "psk": "<psk>",
      "obfs_mode": "none"
    }
  ]
}
```

No `tls`, `reality`, or `transport` field is emitted for Snell. Existing
metadata such as custom node name, entry address, and outbound mode remains
managed by the current metadata helpers.

## Command Flow

### Add

`add()` maps the case-insensitive `snell` alias to the `Snell` protocol and
parses positional arguments as port, PSK, and version. If no port is present,
the existing random-port helper supplies one. If no PSK is present, a
dedicated generator creates a cryptographically random value using the
existing OpenSSL dependency. Version defaults to 5. The default obfuscation
mode is `none` and is not added as a positional argument to `add`.

The Snell branch performs the version gate and all parameter validation before
calling the shared server creation flow.

### Read and Info

`get info` appends Snell-specific JSON fields to the existing extraction
payload so indexes for existing protocols remain unchanged. `get protocol snell`
loads `net=snell`, `is_protocol=snell`, and Snell defaults. `info()` renders
the six required fields and deliberately leaves the share URL unset.

### Change

The change menu receives dedicated entries for PSK, Snell version, and Snell
obfuscation. Their command aliases are:

- `psk` or `snell-psk`
- `snell-version` or `version`
- `obfs`, `obfs-mode`, or `obfs_mode`

The existing port change path is reused for Snell. Each Snell change updates
only its dedicated state, then invokes the Snell add/generation path so the
same validation and replacement rules apply.

### Delete and Restart

Once `get info` recognizes a Snell JSON file, existing `del`, `restart`, and
main configuration synchronization behavior applies without a protocol-
specific deletion path.

## Validation

Validation is fail-closed and occurs in this order:

1. Parse `is_core_ver` and require version `1.14.0` or newer. Empty,
   `unknown`, and unparseable versions are rejected.
2. Require a numeric port in the inclusive range `1-65535`.
3. Reject a port used by an active listener or by any saved node JSON, except
   for the current file during a port change.
4. Require a non-empty PSK.
5. Require Snell version `5`.
6. Require `obfs_mode` to be `none` or `http`.
7. Build the temporary JSON and run `sing-box check -c <temporary-file>`.

For generated test output, the existing `gen` mode still avoids saving files,
but the Snell JSON must pass the same core validation path. The validation
command is injectable in tests through a temporary fake `sing-box` binary;
production uses the configured `is_core_bin`.

## Atomic Replacement

Snell creation and modification use a temporary file in the same configuration
directory as the destination. The sequence is:

1. Build JSON with `jq` using `--arg`/`--argjson`, so PSK and other values are
   encoded as data rather than interpolated JSON syntax.
2. Write the JSON to the temporary file.
3. Run `sing-box check` against only the temporary file.
4. On failure, remove the temporary file and return an error. The old JSON,
   metadata, and running service remain unchanged.
5. On success, move the temporary file into the destination with `mv`.
6. If the port changed, remove the old JSON only after the new destination is
   installed. Move the existing metadata record to the new filename.
7. Synchronize runtime outbound rules and restart the service through the
   existing helpers.

For a same-port update, `mv` replaces the old path atomically after validation.
No Caddy configuration is created or changed for Snell.

## URL and QR Behavior

Snell does not participate in the existing generic URL construction cases.
`url_qr()` checks for the Snell protocol before its generic no-URL error and
returns the exact user-facing guidance:

```text
Snell 暂不支持通用分享链接，请使用配置参数导入
```

The same guidance is used for both `url` and `qr`, and no `snell://` value is
passed to a QR encoder or external QR page.

## Help and Documentation

`src/help.sh` and the root `README.md` will mention:

- Snell as a supported protocol.
- `add snell [port] [psk] [version]`.
- The `sing-box >= 1.14.0` requirement.
- Snell's parameter-based import limitation for URL and QR commands.

The requirements document remains the source of product scope; the design
document records the implementation decisions that resolve its open file and
testing questions.

## Automated Tests

`tests-snell-support.sh` runs each scenario in an isolated child shell for
both `core.sh` and `src/core.sh`. The test harness creates a temporary
configuration directory, sets a deterministic fake address, overrides service
management with a no-op, and provides a fake `sing-box` supporting `version`
and `check`.

The fake core validates the JSON shape and can deliberately reject a PSK to
exercise the failure path. Tests cover:

- Protocol listing and `snell` alias resolution.
- Explicit port, PSK, and version creation.
- Default version and deterministic replacement for generated PSK.
- Version gate for `1.13.x`, unknown, and accepted `1.14.0` values.
