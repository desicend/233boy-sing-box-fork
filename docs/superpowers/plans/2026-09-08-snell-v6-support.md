# Snell v6 Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade Snell inbound support to default to Snell v6 with deployment-level diversity and mode support while maintaining backward compatibility with Snell v5.

**Architecture:** Extend Snell configuration parsing and generation in `src/core.sh` and `core.sh` to distinguish between v6 and v5 schemas. For v6, write `version: 6` and `mode` (default `default`, options `unshaped` / `unsafe-raw`), strictly omitting `obfs_mode`, and enforcing PSK length 12-255 characters. For v5, maintain `version: 5` and `obfs_mode`, strictly omitting `mode`. Add the `sing-box mode` command, smart routing between `mode` and `obfs`, version migration in `snell-version`, and adaptive Surge/URI output.

**Tech Stack:** Bash, `jq`, `sing-box check` (offline fake test core), OpenSSL, shell integration tests.

**Spec:** `docs/superpowers/specs/2026-09-08-snell-v6-support-design.md`

## Global Constraints

- Require `sing-box >= 1.14.0`; reject older versions and unparseable formats.
- Snell default version is `6`; Snell v5 is supported as an explicit option.
- Valid Snell versions are strictly `5` and `6`; reject all other versions.
- Snell v6 inbounds must contain `version: 6` and `mode` (`default`, `unshaped`, `unsafe-raw`); strictly omit `obfs_mode`.
- Snell v5 inbounds must contain `version: 5` and `obfs_mode` (`none`, `http`); strictly omit `mode`.
- Snell v6 PSK must be between 12 and 255 characters; reject PSK shorter than 12 characters.
- Snell v5 PSK must be non-empty.
- Preserve dual-file core parity: all runtime behavioral changes must be applied identically to both `src/core.sh` and `core.sh`.
- Snell exports sing-box URI and Surge configuration formats only; QR code generation remains explicitly unsupported.
- Validate every config before saving via temporary file and `$is_core_bin check -c`.
- Offline test suite `tests-snell-support.sh` must pass 100% in WSL.

---

## File Structure

- Modify: `tests-snell-support.sh` — Offline test suite with fake sing-box core schema validator and end-to-end regression tests.
- Modify: `src/core.sh` — Core protocol routines, validation, JSON generation, CLI routing, and display logic.
- Modify: `core.sh` — Root core script kept in sync with `src/core.sh`.
- Modify: `src/help.sh` — Command help text documenting v6 defaults, `mode` command, and updated Snell parameters.
- Modify: `README.md` — User documentation for Snell v6 support.

---

## Task 1: Update Test Harness, Snell Validation, and Version-Adaptive JSON Generation

**Files:**
- Modify: `tests-snell-support.sh`
- Modify: `src/core.sh:267-326,837-850,1721-1727`
- Modify: `core.sh:267-326,837-850,1721-1727`

**Interfaces:**
- Produces: `snell_mode_valid()`, updated `snell_version_valid()`, updated `validate_snell()`, and version-adaptive `create server Snell`.
- Consumes: `get_snell_psk()`, `is_core_ver`, `is_conf_dir`, `is_core_bin`.

- [ ] **Step 1: Write the failing tests in `tests-snell-support.sh`**

Update `fake-sing-box` in `tests-snell-support.sh` to validate both v6 and v5 schemas, and add tests for default v6 creation and v6 constraints:

In `tests-snell-support.sh`:
```bash
# In fake_core check section:
jq -e '
    (.inbounds | length == 1)
    and (.inbounds[0].type == "snell")
    and (.inbounds[0].listen == "::")
    and (.inbounds[0].listen_port | type == "number")
    and ((.inbounds[0].psk | type) == "string")
    and ((.inbounds[0] | has("tls")) | not)
    and ((.inbounds[0] | has("reality")) | not)
    and ((.inbounds[0] | has("transport")) | not)
    and (
        (
            .inbounds[0].version == 6
            and (.inbounds[0].mode == "default" or .inbounds[0].mode == "unshaped" or .inbounds[0].mode == "unsafe-raw")
            and ((.inbounds[0].psk | length) >= 12)
            and ((.inbounds[0].psk | length) <= 255)
            and ((.inbounds[0] | has("obfs_mode")) | not)
        )
        or
        (
            .inbounds[0].version == 5
            and (.inbounds[0].obfs_mode == "none" or .inbounds[0].obfs_mode == "http")
            and ((.inbounds[0].psk | length) > 0)
            and ((.inbounds[0] | has("mode")) | not)
        )
    )
' "$config" >/dev/null || exit 1
```

And in `run_core_case`:
```bash
# Test default Snell creation creates version 6 with mode default
(
  unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
  add snell 41602
) || fail "add snell with default parameters should succeed"
jq -e '
    .inbounds[0].version == 6
    and .inbounds[0].mode == "default"
    and (.inbounds[0] | has("obfs_mode") | not)
    and (.inbounds[0].psk | length >= 12)
' "$is_conf_dir/snell-41602.json" >/dev/null || fail "default snell config should be v6 with mode default and no obfs_mode"

# Test v6 PSK < 12 characters is rejected
(
  unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
  add snell 41620 shortpsk 6
) >"$case_dir/snell-short-psk.out" 2>&1 && fail "v6 PSK < 12 chars should fail"
[[ ! -f $is_conf_dir/snell-41620.json ]] || fail "short PSK should not create config"

# Test unsupported versions (e.g., version 4 and version 7) are rejected
for bad_ver in 4 7; do
  (
    unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
    add snell 41621 "valid-long-psk-123" "$bad_ver"
  ) >"$case_dir/snell-bad-ver.out" 2>&1 && fail "version $bad_ver should fail"
  [[ ! -f $is_conf_dir/snell-41621.json ]] || fail "unsupported version should not create config"
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: FAIL because `add snell 41602` defaults to version 5, `fake_core` rejects v5 if mode is missing or v6 format mismatches, and `validate_snell` only accepts version 5.

- [ ] **Step 3: Implement minimal code in `src/core.sh` and `core.sh`**

In `src/core.sh` and `core.sh`:
1. Update `snell_version_valid` and add `snell_mode_valid`:
```bash
snell_version_valid() {
    [[ $1 == 5 || $1 == 6 ]]
}

snell_mode_valid() {
    [[ $1 =~ ^(default|unshaped|unsafe-raw)$ ]]
}
```

2. Update `validate_snell`:
```bash
validate_snell() {
    local current_port
    require_snell_support
    [[ $(is_test port "$port") ]] || err "($port) 不是一个有效的端口. $is_err_tips"
    current_port=$(jq -r '.inbounds[0].listen_port // empty' "$is_conf_dir/${is_config_file:-missing}" 2>/dev/null)
    if [[ $port != "$current_port" ]] && [[ $(is_test port_used "$port") ]]; then
        err "无法使用 ($port) 端口. $is_err_tips"
    fi
    config_port_used "$port" "${is_config_file:-}" && err "无法使用 ($port) 端口. $is_err_tips"
    [[ $snell_psk ]] || err "Snell PSK 不能为空. $is_err_tips"
    snell_version_valid "$snell_version" || err "Snell 版本只支持 5 或 6. $is_err_tips"
    if [[ $snell_version == 6 ]]; then
        ((${#snell_psk} >= 12 && ${#snell_psk} <= 255)) || err "Snell v6 PSK 长度必须在 12 到 255 字符之间. $is_err_tips"
        snell_mode_valid "$snell_mode" || err "Snell 运行模式只支持 default, unshaped 或 unsafe-raw. $is_err_tips"
    else
        snell_obfs_mode_valid "$snell_obfs_mode" || err "Snell 混淆模式只支持 none 或 http. $is_err_tips"
    fi
}
```

3. Update `add()` for Snell defaults (lines 1721-1727):
```bash
    if [[ ${is_new_protocol,,} == snell ]]; then
        [[ ! $port ]] && get_port && port=$tmp_port
        [[ ! $snell_psk ]] && snell_psk=$(get_snell_psk)
        [[ ! $snell_version ]] && snell_version=6
        if [[ $snell_version == 6 ]]; then
            [[ ! $snell_mode ]] && snell_mode=default
            unset snell_obfs_mode
        else
            [[ ! $snell_obfs_mode ]] && snell_obfs_mode=none
            unset snell_mode
        fi
        validate_snell
    fi
```

4. Update `create server Snell` (lines 837-845):
```bash
        if [[ ${2,,} == snell ]]; then
            if [[ $snell_version == 6 ]]; then
                is_new_json=$(jq -n \
                    --arg tag "$is_config_name" \
                    --argjson port "$port" \
                    --arg psk "$snell_psk" \
                    --arg mode "$snell_mode" \
                    --argjson version 6 \
                    '{inbounds:[{tag:$tag,type:"snell",listen:"::",listen_port:$port,version:$version,psk:$psk,mode:$mode}]}')
            else
                is_new_json=$(jq -n \
                    --arg tag "$is_config_name" \
                    --argjson port "$port" \
                    --arg psk "$snell_psk" \
                    --arg obfs_mode "$snell_obfs_mode" \
                    --argjson version 5 \
                    '{inbounds:[{tag:$tag,type:"snell",listen:"::",listen_port:$port,version:$version,psk:$psk,obfs_mode:$obfs_mode}]}')
            fi
            is_snell_tmp_file=$(mktemp "$is_conf_dir/.snell-XXXXXX.json") || err "无法创建 Snell 临时配置文件."
            printf '%s\n' "$is_new_json" >"$is_snell_tmp_file"
            if ! "$is_core_bin" check -c "$is_snell_tmp_file" &>/dev/null; then
                rm -f "$is_snell_tmp_file"
                err "Snell 配置校验失败."
            fi
        fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: PASS for Step 1 test assertions.

- [ ] **Step 5: Commit**

```bash
git add tests-snell-support.sh src/core.sh core.sh
git commit -m "feat(snell): support snell v6 inbound schema, validation, and defaults"
```

---

## Task 2: State Loading, Info Display, and Adaptive Surge/URI Export

**Files:**
- Modify: `src/core.sh:128-154,1826-1828,1945-1950,2187-2199`
- Modify: `core.sh:128-154,1826-1828,1945-1950,2187-2199`
- Modify: `tests-snell-support.sh`

**Interfaces:**
- Produces: `snell_mode` state extraction in `get info`, `info_list` item 25 (`"运行模式 (mode)"`), version-aware `info()` display, and URL/Surge generation.
- Consumes: `is_config_file`, `snell_version`, `snell_psk`, `snell_mode`, `snell_obfs_mode`, `is_addr`, `port`, `is_node_name`.

- [ ] **Step 1: Write the failing tests in `tests-snell-support.sh`**

Add tests to `tests-snell-support.sh` for Snell v6 info display, Surge output, and sing-box URI output (both default and non-default modes):

```bash
# Test v6 default mode info and export formats
jq -n \
  '{inbounds:[{tag:"snell-41622.json",type:"snell",listen:"::",listen_port:41622,version:6,psk:"test-psk-12345678",mode:"default"}]}' \
  >"$is_conf_dir/snell-41622.json"
jq -n '{node_name:"snell-v6-node",entry_addr:"v6.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41622.json.meta.json"

is_dont_show_info=1
info snell-41622.json
[[ $is_protocol == snell ]] || fail "info should identify Snell protocol"
[[ $port == 41622 ]] || fail "info should extract Snell port"
[[ $snell_version == 6 ]] || fail "info should extract Snell v6 version"
[[ $snell_mode == default ]] || fail "info should extract Snell mode default"
[[ $snell_psk == "test-psk-12345678" ]] || fail "info should extract Snell PSK"
[[ $is_url == "snell://test-psk-12345678@v6.example.com:41622?version=6#snell-v6-node" ]] || fail "Snell v6 default URI mismatch: $is_url"
[[ $is_surge_str == "snell-v6-node = snell, v6.example.com, 41622, psk=test-psk-12345678, version=6" ]] || fail "Snell v6 default Surge mismatch: $is_surge_str"

# Test v6 unshaped mode exports &mode=unshaped
jq -n \
  '{inbounds:[{tag:"snell-41623.json",type:"snell",listen:"::",listen_port:41623,version:6,psk:"test-psk-12345678",mode:"unshaped"}]}' \
  >"$is_conf_dir/snell-41623.json"
jq -n '{node_name:"snell-v6-unshaped",entry_addr:"v6.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41623.json.meta.json"

is_dont_show_info=1
info snell-41623.json
[[ $snell_mode == unshaped ]] || fail "info should extract unshaped mode"
[[ $is_url == "snell://test-psk-12345678@v6.example.com:41623?version=6&mode=unshaped#snell-v6-unshaped" ]] || fail "v6 unshaped URI mismatch: $is_url"
[[ $is_surge_str == "snell-v6-unshaped = snell, v6.example.com, 41623, psk=test-psk-12345678, version=6, mode=unshaped" ]] || fail "v6 unshaped Surge mismatch: $is_surge_str"

# Test v6 terminal info output contains 运行模式 (mode)
old_is_dont_auto_exit=$is_dont_auto_exit
is_dont_show_info=
is_dont_auto_exit=
v6_info_output=$(info snell-41622.json)
for label in "协议 (protocol)" "版本 (version)" "PSK" "运行模式 (mode)"; do
  [[ $v6_info_output == *"$label"* ]] || fail "Snell v6 info output should include $label"
done
[[ $v6_info_output != *"混淆模式 (obfs_mode)"* ]] || fail "Snell v6 info should not display obfs_mode"
is_dont_show_info=1
is_dont_auto_exit=$old_is_dont_auto_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: FAIL because `info` does not yet extract `.inbounds[0].mode` or format v6 Surge/URI lines.

- [ ] **Step 3: Implement minimal code in `src/core.sh` and `core.sh`**

1. In `info_list` (lines 128-154), append:
```bash
    "运行模式 (mode)"
```
(This has index 25).

2. In `get info` (lines 1826-1828):
```bash
is_json_data=$(jq -r '(.inbounds[0]|.type,.listen_port,.listen,(.users[0]|.uuid,.password,.username),.method,.password,.override_port,.override_address,(.transport|.type,.path,.headers.host),(.tls|.server_name,.reality.private_key)),(.outbounds[1].tag,.inbounds[0].version,.inbounds[0].psk,.inbounds[0].obfs_mode,.inbounds[0].mode)' <<<$is_json_str)
[[ $? != 0 ]] && err "无法读取此文件: $is_config_file"
is_up_var_set=(null is_protocol port is_listen_addr uuid password username ss_method ss_password door_port door_addr net_type path host is_servername is_private_key is_public_key snell_version snell_psk snell_obfs_mode snell_mode)
```

3. In `get protocol` (lines 1945-1950):
```bash
        snell*)
            net=snell
            is_protocol=snell
            [[ $snell_version ]] || snell_version=6
            if [[ $snell_version == 6 ]]; then
                [[ $snell_mode ]] || snell_mode=default
                unset snell_obfs_mode
            else
                [[ $snell_obfs_mode ]] || snell_obfs_mode=none
                unset snell_mode
            fi
            ;;
```

4. In `info()` (lines 2187-2199):
```bash
    snell)
        if [[ $snell_version == 6 ]]; then
            is_can_change=(0 1 13 14 15 17 18 20)
            is_info_show=(0 1 2 22 23 25)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$snell_version" "$snell_psk" "$snell_mode")
            local mode_param=
            local surge_mode=
            if [[ $snell_mode && $snell_mode != "default" ]]; then
                mode_param="&mode=$snell_mode"
                surge_mode=", mode=$snell_mode"
            fi
            is_url="snell://$snell_psk@$is_addr:$port?version=$snell_version${mode_param}#$is_node_name"
            is_surge_str="$is_node_name = snell, $is_addr, $port, psk=$snell_psk, version=$snell_version${surge_mode}"
        else
            is_can_change=(0 1 13 14 15 17 18 19)
            is_info_show=(0 1 2 22 23 24)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$snell_version" "$snell_psk" "$snell_obfs_mode")
            local obfs_param=
            local surge_obfs=
            if [[ $snell_obfs_mode && $snell_obfs_mode != "none" ]]; then
                obfs_param="&obfs=$snell_obfs_mode"
                surge_obfs=", obfs=$snell_obfs_mode"
            fi
            is_url="snell://$snell_psk@$is_addr:$port?version=$snell_version${obfs_param}#$is_node_name"
            is_surge_str="$is_node_name = snell, $is_addr, $port, psk=$snell_psk, version=$snell_version${surge_obfs}"
        fi
        ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests-snell-support.sh src/core.sh core.sh
git commit -m "feat(snell): adapt info display and URI/Surge exports for snell v6"
```

---

## Task 3: CLI Commands (`mode`, `obfs`, `psk`, `snell-version`), Smart Routing, and Version Migration

**Files:**
- Modify: `src/core.sh:155-176,995-1015,1267-1295`
- Modify: `core.sh:155-176,995-1015,1267-1295`
- Modify: `tests-snell-support.sh`

**Interfaces:**
- Produces: CLI commands `mode`, `obfs`, `psk`, `snell-version`, bidirectional 5 <-> 6 migration, and menu adaptation.
- Consumes: `change()`, `is_can_change`, `change_list`, `add snell`.

- [ ] **Step 1: Write failing tests in `tests-snell-support.sh`**

Add tests in `tests-snell-support.sh` for:
1. `sing-box mode <v6-node> unshaped` updates mode to `unshaped`.
2. `sing-box mode <v5-node> http` routes to obfs and updates v5 `obfs_mode` to `http`.
3. `sing-box obfs <v6-node> unshaped` updates v6 `mode` to `unshaped`.
4. `sing-box obfs <v6-node> http` routes to v6 default mode.
5. `sing-box psk <v6-node> short` (< 12 chars) is rejected.
6. `sing-box snell-version <v5-node> 6` migrates to v6: cleans `obfs_mode`, adds `mode: "default"`, verifies PSK length.
7. `sing-box snell-version <v6-node> 5` migrates to v5: cleans `mode`, adds `obfs_mode: "none"`, preserves PSK.

```bash
# Test change mode on v6 node
change snell-41622.json mode unshaped || fail "change mode unshaped on v6 node should succeed"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == unshaped ]] || fail "v6 mode was not saved"

# Test smart routing: change mode on v5 node routes to obfs
change snell-41601.json mode http || fail "change mode on v5 node should route to obfs"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == http ]] || fail "v5 obfs was not updated via mode"

# Test smart routing: change obfs with mode value on v6 node updates mode
change snell-41622.json obfs unsafe-raw || fail "change obfs with unsafe-raw on v6 node should update mode"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == unsafe-raw ]] || fail "v6 mode was not updated via obfs"

# Test smart routing: change obfs with none/http on v6 node adapts to default mode
change snell-41622.json obfs http || fail "change obfs with http on v6 node should adapt"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == default ]] || fail "v6 mode was not adapted to default"

# Test v6 PSK change rejects < 12 characters
(change snell-41622.json psk tooshort) >"$case_dir/v6-short-psk.out" 2>&1 && fail "v6 PSK change < 12 chars should fail"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41622.json") == "test-psk-12345678" ]] || fail "failed PSK change altered PSK"

# Test migration v5 -> v6
jq -n \
  '{inbounds:[{tag:"snell-41624.json",type:"snell",listen:"::",listen_port:41624,version:5,psk:"long-enough-psk-1234",obfs_mode:"http"}]}' \
  >"$is_conf_dir/snell-41624.json"
change snell-41624.json snell-version 6 || fail "migration v5 to v6 should succeed"
jq -e '
    .inbounds[0].version == 6
    and .inbounds[0].mode == "default"
    and (.inbounds[0] | has("obfs_mode") | not)
    and .inbounds[0].psk == "long-enough-psk-1234"
' "$is_conf_dir/snell-41624.json" >/dev/null || fail "v5 -> v6 migration output invalid"

# Test migration v6 -> v5
change snell-41624.json snell-version 5 || fail "migration v6 to v5 should succeed"
jq -e '
    .inbounds[0].version == 5
    and .inbounds[0].obfs_mode == "none"
    and (.inbounds[0] | has("mode") | not)
    and .inbounds[0].psk == "long-enough-psk-1234"
' "$is_conf_dir/snell-41624.json" >/dev/null || fail "v6 -> v5 migration output invalid"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: FAIL because `mode` command and migration logic are not implemented.

- [ ] **Step 3: Implement minimal code in `src/core.sh` and `core.sh`**

1. In `change_list` (lines 155-176), append:
```bash
    "更改 Snell 运行模式"
```
(Index 20).

2. In `change()` argument parsing (lines 995-1015):
```bash
        outbound | outbound-mode)
            is_change_id=14
            ;;
        entry | entry-addr | entry_addr | addr)
            is_change_id=15
            ;;
        link | url)
            is_change_id=16
            ;;
        psk | snell-psk)
            is_change_id=17
            ;;
        snell-version | version)
            is_change_id=18
            ;;
        obfs | obfs-mode | obfs_mode)
            is_change_id=19
            ;;
        mode | snell-mode)
            is_change_id=20
            ;;
```

3. In `change()` action dispatch (lines 1267-1295):
- For case 17 (`psk`):
```bash
    17)
        # psk
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell PSK."
        is_new_snell_psk=$3
        [[ $is_auto ]] && is_new_snell_psk=$(get_snell_psk)
        [[ ! $is_new_snell_psk ]] && ask string is_new_snell_psk "请输入新的 Snell PSK:"
        if [[ $snell_version == 6 ]]; then
            ((${#is_new_snell_psk} >= 12 && ${#is_new_snell_psk} <= 255)) || err "Snell v6 PSK 长度必须在 12 到 255 字符之间. $is_err_tips"
        fi
        snell_psk=$is_new_snell_psk
        add snell
        ;;
```

- For case 18 (`snell-version`):
```bash
    18)
        # snell-version
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell 版本."
        is_new_snell_version=$3
        [[ $is_auto ]] && is_new_snell_version=6
        [[ ! $is_new_snell_version ]] && {
            ask string is_new_snell_version "请输入新的 Snell 版本 [5/6]:"
        }
        snell_version_valid "$is_new_snell_version" || err "Snell 版本只支持 5 或 6. $is_err_tips"
        if [[ $is_new_snell_version == 6 && $snell_version != 6 ]]; then
            # migrating v5 -> v6
            unset snell_obfs_mode
            snell_mode=default
            if ((${#snell_psk} < 12)); then
                warn "原 PSK 长度不足 12 位，已自动生成符合 v6 规范的新 PSK."
                snell_psk=$(get_snell_psk)
            fi
        elif [[ $is_new_snell_version == 5 && $snell_version != 5 ]]; then
            # migrating v6 -> v5
            unset snell_mode
            snell_obfs_mode=none
        fi
        snell_version=$is_new_snell_version
        add snell
        ;;
```

- For case 19 (`obfs`):
```bash
    19)
        # obfs-mode
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell 混淆模式."
        if [[ $snell_version == 6 ]]; then
            # smart routing for v6 node
            if [[ $3 =~ ^(default|unshaped|unsafe-raw)$ ]]; then
                snell_mode=$3
                add snell
                return
            fi
            if [[ $3 == 'none' || $3 == 'http' ]]; then
                warn "当前为 Snell v6 节点，不支持混淆模式 (obfs_mode)，已自动转换为默认运行模式 (mode: default)."
                snell_mode=default
                add snell
                return
            fi
            # interactive prompt for mode
            is_tmp_list=(default unshaped unsafe-raw)
            ask list is_new_snell_mode "${is_tmp_list[*]}" "\n当前为 Snell v6 节点，请选择运行模式:\n"
            snell_mode=$is_new_snell_mode
            add snell
            return
        fi
        is_new_snell_obfs_mode=$3
        [[ $is_new_snell_obfs_mode == auto ]] && is_new_snell_obfs_mode=none
        [[ ! $is_new_snell_obfs_mode ]] && {
            is_tmp_list=(none http)
            ask list is_new_snell_obfs_mode
        }
        snell_obfs_mode=$is_new_snell_obfs_mode
        add snell
        ;;
```

- Add case 20 (`mode`):
```bash
    20)
        # mode
        if [[ $is_protocol != snell ]]; then
            # backward compatibility for non-snell outbound mode
            ask set_outbound_mode
            sync_runtime_dns_strategy "$is_outbound_mode"
            msg "\n已更新出站方式为: $(_green $is_outbound_mode)\n"
            return
        fi
        if [[ $snell_version == 5 ]]; then
            # smart routing for v5 node
            is_new_snell_obfs_mode=$3
            [[ $is_new_snell_obfs_mode == auto ]] && is_new_snell_obfs_mode=none
            if [[ ! $is_new_snell_obfs_mode || ! $is_new_snell_obfs_mode =~ ^(none|http)$ ]]; then
                is_tmp_list=(none http)
                ask list is_new_snell_obfs_mode "${is_tmp_list[*]}" "\n当前为 Snell v5 节点，请选择混淆模式:\n"
            fi
            snell_obfs_mode=$is_new_snell_obfs_mode
            add snell
            return
        fi
        is_new_snell_mode=$3
        [[ $is_new_snell_mode == auto ]] && is_new_snell_mode=default
        [[ ! $is_new_snell_mode ]] && {
            is_tmp_list=(default unshaped unsafe-raw)
            ask list is_new_snell_mode "${is_tmp_list[*]}" "\n请选择 Snell v6 运行模式:\n"
        }
        snell_mode_valid "$is_new_snell_mode" || err "Snell 运行模式只支持 default, unshaped 或 unsafe-raw. $is_err_tips"
        snell_mode=$is_new_snell_mode
        add snell
        ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests-snell-support.sh src/core.sh core.sh
git commit -m "feat(snell): add mode command, smart routing, and v5/v6 migration"
```

---

## Task 4: Help Text, Documentation, and Final Test Verification

**Files:**
- Modify: `src/help.sh`
- Modify: `README.md`
- Modify: `tests-snell-support.sh`

**Interfaces:**
- Produces: Updated help strings and README documentation matching test assertions.
- Consumes: Test suite verification.

- [ ] **Step 1: Write failing checks in `tests-snell-support.sh`**

In `tests-snell-support.sh`, verify help and README documentation:
```bash
grep -q 'mode \[name\]' "$repo_root/src/help.sh" || fail "src/help.sh should document mode command"
grep -q 'Snell v6' "$repo_root/README.md" || fail "README.md should document Snell v6"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"`
Expected: FAIL because `src/help.sh` and `README.md` do not yet mention `mode` or `Snell v6`.

- [ ] **Step 3: Update `src/help.sh` and `README.md`**

1. In `src/help.sh`:
- Update line 20:
```bash
   add snell [port] [psk] [version]                添加 Snell (默认 v6, 支持 v5, 需要 sing-box >= 1.14.0)
```
- In change section:
```bash
   psk [name] [psk | auto]                         更改 Snell PSK
   snell-version [name] [6 | 5 | auto]             更改 Snell 版本
   mode [name] [default | unshaped | unsafe-raw | auto] 更改 Snell 运行模式 (v6)
   obfs [name] [none | http | auto]                更改 Snell 混淆模式 (v5)
```

2. In `README.md`:
Update the Snell section to document Snell v6 default, the 12-255 char PSK requirement, modes (`default`, `unshaped`, `unsafe-raw`), and backward compatibility with v5.

- [ ] **Step 4: Run full test suite to verify**

Run:
```bash
wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"
wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-relay-support.sh"
wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && bash -n src/core.sh && bash -n core.sh && bash -n src/help.sh"
```
Expected: All tests PASS with exit code 0 and syntax check clean.

- [ ] **Step 5: Commit**

```bash
git add src/help.sh README.md tests-snell-support.sh
git commit -m "docs(snell): update help and documentation for snell v6 support"
```
