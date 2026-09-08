# Native Relay Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to create, inspect, list, and delete fixed-target native `direct` TCP/UDP relay entries through `sing-box` management commands while preserving existing protocol nodes and legacy direct flow.

**Architecture:** Implement relay management using dedicated relay helpers and files prefixed with `relay-` (`relay-<local-port>.json`). Reuse and generalize the saved-port conflict scan across Snell and relay configurations. Apply identical relay behaviors to both runtime `src/core.sh` and root `core.sh` while preserving unrelated differences. Validate single files and complete runtime configurations before installation or deletion commit, with rollback on validation failures.

**Tech Stack:** Bash, `jq`, `sing-box check` (fragment `-c` and directory `-C`), shell integration tests.

**Spec:** `docs/superpowers/specs/2026-09-08-relay-design.md`

## Global Constraints

- Relay is implemented exclusively by native sing-box `direct` inbounds with `override_address` and `override_port`; no Realm, socat, iptables redirect, or other daemons.
- Dual-protocol default: omit the `network` field in JSON to preserve native sing-box direct TCP and UDP forwarding.
- Stored filename is strictly `$is_conf_dir/relay-<local-port>.json`.
- Remote address is stored as a string via `jq --arg`; remote port is stored as a JSON number via `jq --argjson`.
- Relay files have no `.quan-meta` metadata record and never emit or encode share URLs or QR codes.
- Local listening ports must be validated against active listeners (`is_test port_used`) and all saved inbounds (`config_port_used`).
- Validation is fail-closed: temporary file validation and complete runtime configuration validation (`sing-box check -c $is_config_json -C $is_conf_dir`) must pass before finalizing addition or deletion.
- Failed addition deletes the candidate relay file and does not restart sing-box; failed deletion restores the original relay file and does not restart sing-box.
- Every relay creation, listing, and inspection must display a security warning regarding unauthenticated public relay exposure and the requirement for a host firewall or network ACL.
- Existing legacy `add direct` command and generic `Direct-*.json` nodes must remain unchanged in behavior.
- `fix-all` must explicitly skip `relay-*.json` files.
- `sync_runtime_node_outbound_modes` continues scanning without modifying relay files.
- Apply relay behavior to both `core.sh` and `src/core.sh`; preserve existing unrelated differences between those files.
- Automated tests must be offline and deterministic; client forwarding remains manual acceptance.

---

## File Map

- Create: `tests-relay-support.sh` — offline integration test harness covering both `core.sh` and `src/core.sh` using a fake `sing-box` binary.
- Modify: `src/core.sh` — generalize `config_port_used`, implement relay add/list/info/delete helpers, wire relay dispatcher and submenu, skip relay in `fix-all`.
- Modify: `core.sh` — apply identical relay helpers, dispatcher, submenu, and `fix-all` guard while preserving root-only non-relay differences.
- Modify: `src/help.sh` — document `relay` subcommands, arguments, dual-protocol behavior, and security warning.
- Modify: `README.md` — document relay feature, commands, and security warning in the static help block.

---

## Interfaces Between Tasks

- `config_port_used <port> [current-config]`: checks if any saved inbound in `$is_conf_dir/*.json` uses `<port>` (except `[current-config]`). Returns 0 if used, 1 if available.
- `snell_config_port_used <port> [current-config]`: backwards-compatible wrapper calling `config_port_used`.
- `relay_warn_security`: emits the unauthenticated public relay security warning (firewall/network ACL).
- `relay_add [local-port] [remote-address] [remote-port]`: validates ports and target, validates fragment with `check -c`, verifies runtime config with `check -c -C`, installs `relay-<local-port>.json`, restarts sing-box, prints parameters and warning.
- `relay_info_show <local-port> <remote-address> <remote-port>`: formats standard relay info fields including `network = tcp,udp`.
- `relay_info [local-port]`: displays relay inbound parameters for `<local-port>` and security warning.
- `relay_list`: lists all `relay-*.json` entries with local port, remote target, `tcp,udp`, and security warning.
- `relay_delete <local-port>`: safely deletes `relay-<local-port>.json` with rollback to backup if complete config check fails.
- `relay_menu`: interactive submenu for relay management (add, list/info, delete, return).
- `relay_main`: command dispatcher for `sing-box relay [add|list|info|delete]`.

---

### Task 1: Generalize Port Check & Implement Relay Add Generation and Validation

**Files:**
- Create: `tests-relay-support.sh`
- Modify: `src/core.sh` (refactor `snell_config_port_used` -> `config_port_used`, add `relay_warn_security`, `relay_add`, and initial `relay_main`)
- Modify: `core.sh` (mirror the identical changes in `core.sh`)

**Interfaces:**
- Produces: `config_port_used`, `snell_config_port_used`, `relay_warn_security`, `relay_add`, and `relay_main add` dispatcher.
- Generates: validated `$is_conf_dir/relay-<local-port>.json`.

- [ ] **Step 1: Write the failing offline relay test harness.**

Create `tests-relay-support.sh` with a fake sing-box core binary supporting `version`, `check -c <file>`, and `check -c <config.json> -C <confdir>`. The test harness runs test cases against both `core.sh` and `src/core.sh`:

```bash
#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

fake_core="$workdir/fake-sing-box"
cat >"$fake_core" <<'FAKE_CORE'
#!/usr/bin/env bash
case ${1:-} in
version)
    printf 'sing-box version %s\n' "${FAKE_CORE_VERSION:-1.14.0}"
    ;;
check)
    config=
    conf_dir=
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c)
            config=$2
            shift 2
            ;;
        -C)
            conf_dir=$2
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    if [[ $TEST_REJECT_COMPLETE == 1 && -n $conf_dir ]]; then
        exit 1
    fi
    if [[ -n $config ]]; then
        [[ -f $config ]] || exit 1
        if jq -e '.inbounds[0].type == "direct"' "$config" >/dev/null 2>&1; then
            jq -e '
                (.inbounds | length == 1)
                and (.inbounds[0].type == "direct")
                and (.inbounds[0].listen == "::")
                and (.inbounds[0].listen_port | type == "number")
                and (.inbounds[0].listen_port > 0)
                and (.inbounds[0].listen_port <= 65535)
                and ((.inbounds[0].override_address | type) == "string")
                and ((.inbounds[0].override_address | length) > 0)
                and (.inbounds[0].override_port | type == "number")
                and (.inbounds[0].override_port > 0)
                and (.inbounds[0].override_port <= 65535)
                and ((.inbounds[0] | has("network")) | not)
            ' "$config" >/dev/null || exit 1
            [[ $(jq -r '.inbounds[0].override_address' "$config") != reject-fragment ]] || exit 1
        fi
    fi
    if [[ -n $conf_dir ]]; then
        [[ -d $conf_dir ]] || exit 1
        shopt -s nullglob
        for f in "$conf_dir"/*.json; do
            jq -e . "$f" >/dev/null 2>&1 || exit 1
            if [[ $(jq -r '.inbounds[0].override_address // empty' "$f") == "reject-complete" ]]; then
                exit 1
            fi
        done
        shopt -u nullglob
    fi
    ;;
esac
FAKE_CORE
chmod +x "$fake_core"

fail() {
  echo "FAIL: $1"
  exit 1
}

run_core_case() {
  local core_file=$1
  CORE_FILE="$core_file" FAKE_CORE="$fake_core" bash <<'CASE'
set -o pipefail

fail() {
  echo "FAIL(${CORE_FILE}): $1"
  exit 1
}

case_dir=$(mktemp -d)
cleanup() {
  rm -rf "$case_dir"
}
trap cleanup EXIT

source "$CORE_FILE"

is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_dont_auto_exit=1
mkdir -p "$is_conf_dir"
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf "%s\n" "$*" >>"$manage_log"; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf "%s\n" "$1"; }

# 1. Successful relay add with explicit values
add_out=$( (main relay add 10000 203.0.113.10 20000) 2>&1 )
[[ $? == 0 ]] || fail "relay add 10000 should succeed: $add_out"
config="$is_conf_dir/relay-10000.json"
[[ -f $config ]] || fail "relay-10000.json should exist"
jq -e '
    .inbounds[0].tag == "relay-10000.json"
    and .inbounds[0].type == "direct"
    and .inbounds[0].listen == "::"
    and .inbounds[0].listen_port == 10000
    and .inbounds[0].override_address == "203.0.113.10"
    and .inbounds[0].override_port == 20000
    and ((.inbounds[0] | has("network")) | not)
' "$config" >/dev/null || fail "relay-10000.json shape mismatch"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10000.json.meta.json" ]] || fail "relay must not generate metadata"
[[ $add_out == *"防火墙"* || $add_out == *"ACL"* ]] || fail "relay add should emit security warning"
grep -q "restart" "$manage_log" || fail "manage restart should be called on successful add"

# 2. IPv6 remote address
(main relay add 10001 "2001:db8::1" 20001) >/dev/null 2>&1 || fail "relay add with IPv6 should succeed"
[[ $(jq -r '.inbounds[0].override_address' "$is_conf_dir/relay-10001.json") == "2001:db8::1" ]] || fail "IPv6 remote address mismatch"

# 3. Invalid ports & empty address
(main relay add 0 203.0.113.10 20000) >/dev/null 2>&1 && fail "local port 0 should fail"
(main relay add 65536 203.0.113.10 20000) >/dev/null 2>&1 && fail "local port 65536 should fail"
(main relay add 10002 203.0.113.10 0) >/dev/null 2>&1 && fail "remote port 0 should fail"
(main relay add 10002 203.0.113.10 65536) >/dev/null 2>&1 && fail "remote port 65536 should fail"
(main relay add 10002 "   " 20000) >/dev/null 2>&1 && fail "empty remote address should fail"

# 4. Port conflicts (active listener, protocol node, existing relay)
TEST_ACTIVE_PORT=10005
(main relay add 10005 203.0.113.10 20000) >/dev/null 2>&1 && fail "active port conflict should fail"
jq -n '{inbounds:[{type:"vless",listen_port:10006}]}' > "$is_conf_dir/vless-10006.json"
(main relay add 10006 203.0.113.10 20000) >/dev/null 2>&1 && fail "protocol node port conflict should fail"
(main relay add 10000 203.0.113.10 30000) >/dev/null 2>&1 && fail "duplicate relay port should fail"

# 5. Fragment check failure
(main relay add 10007 reject-fragment 20000) >/dev/null 2>&1 && fail "fragment validation rejection should fail"
[[ ! -f "$is_conf_dir/relay-10007.json" ]] || fail "failed candidate must not be installed"

# 6. Complete config check failure rollback
echo '{"inbounds":[]}' > "$is_config_json"
TEST_REJECT_COMPLETE=1
(main relay add 10008 203.0.113.10 20000) >/dev/null 2>&1 && fail "complete check rejection should fail"
[[ ! -f "$is_conf_dir/relay-10008.json" ]] || fail "complete check rollback should remove candidate"
unset TEST_REJECT_COMPLETE

# 7. Backward compatibility of config_port_used / snell_config_port_used
config_port_used 10000 || fail "config_port_used should detect relay port"
snell_config_port_used 10006 || fail "snell_config_port_used wrapper should detect vless port"
! config_port_used 59999 || fail "unused port should return 1"

CASE
}

run_core_case "$repo_root/core.sh"
run_core_case "$repo_root/src/core.sh"

echo "PASS: Task 1 relay add generation and validation coverage"
```

- [ ] **Step 2: Run test to verify it fails.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
```
Expected: FAIL because `main relay` is unrecognized and relay functions do not exist yet.

- [ ] **Step 3: Implement shared port check and relay add in `src/core.sh` and `core.sh`.**

In both `src/core.sh` and `core.sh`:
1. Generalize `snell_config_port_used` to `config_port_used`, and provide `snell_config_port_used` as a compatibility wrapper:
```bash
config_port_used() {
    local wanted=$1 current=${2:-} file nullglob_was_set
    if shopt -q nullglob; then
        nullglob_was_set=1
    else
        nullglob_was_set=0
    fi
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ ${file##*/} == "$current" ]] && continue
        if jq -e --argjson port "$wanted" 'any(.inbounds[]?.listen_port?; . == $port)' "$file" >/dev/null 2>&1; then
            if ((nullglob_was_set)); then
                shopt -s nullglob
            else
                shopt -u nullglob
            fi
            return 0
        fi
    done
    if ((nullglob_was_set)); then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
    return 1
}

snell_config_port_used() {
    config_port_used "$@"
}
```
Update `validate_snell` to use `config_port_used "$port" "${is_config_file:-}"`.

2. Add relay security warning and relay add functions:
```bash
relay_warn_security() {
    warn "当前中转未设置身份验证，请务必使用系统防火墙 (如 ufw / iptables) 或云服务商安全组 / 网络 ACL 限制访问来源，以防止端口被未授权滥用."
}

relay_info_show() {
    local l_port=$1 r_addr=$2 r_port=$3
    msg "type = direct"
    msg "listen = ::"
    msg "listen_port = $l_port"
    msg "override_address = $r_addr"
    msg "override_port = $r_port"
    msg "network = tcp,udp"
}

relay_add() {
    local local_port=$1 remote_addr=$2 remote_port=$3
    if [[ ! $local_port ]]; then
        ask string local_port "请输入本地监听端口 (输入 auto 自动生成):"
    fi
    if [[ $local_port == auto ]]; then
        while :; do
            get_port
            local_port=$tmp_port
            config_port_used "$local_port" || break
        done
    fi
    local_port=$(echo "$local_port" | tr -d ' ')
    [[ $(is_test port "$local_port") ]] || err "($local_port) 不是一个有效的端口."
    [[ $(is_test port_used "$local_port") ]] && err "本地端口 ($local_port) 已被占用."
    config_port_used "$local_port" && err "本地端口 ($local_port) 已被现有配置占用."

    if [[ ! $remote_addr ]]; then
        ask string remote_addr "请输入目标地址 (IPv4/IPv6/域名):"
    fi
    remote_addr=$(echo "$remote_addr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n $remote_addr ]] || err "目标地址不能为空."

    if [[ ! $remote_port ]]; then
        ask string remote_port "请输入目标端口:"
    fi
    remote_port=$(echo "$remote_port" | tr -d ' ')
    [[ $(is_test port "$remote_port") ]] || err "($remote_port) 不是一个有效的目标端口."

    local relay_file="$is_conf_dir/relay-${local_port}.json"
    local tmp_file
    tmp_file=$(mktemp "$is_conf_dir/.relay-XXXXXX.json") || err "无法创建中转临时配置文件."

    jq -n \
        --arg tag "relay-${local_port}.json" \
        --arg addr "$remote_addr" \
        --argjson local_port "$local_port" \
        --argjson remote_port "$remote_port" \
        '{inbounds:[{tag:$tag,type:"direct",listen:"::",listen_port:$local_port,override_address:$addr,override_port:$remote_port}]}' > "$tmp_file" || {
        rm -f "$tmp_file"
        err "生成中转配置 JSON 失败."
    }

    if ! "$is_core_bin" check -c "$tmp_file" &>/dev/null; then
        rm -f "$tmp_file"
        err "中转配置校验失败."
    fi

    if ! mv -f "$tmp_file" "$relay_file"; then
        rm -f "$tmp_file"
        err "保存中转配置文件失败."
    fi

    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            rm -f "$relay_file"
            err "完整运行时配置校验失败，已取消安装该中转配置."
        fi
    fi

    manage restart &
    msg "\n$(_green '中转配置添加成功!')"
    msg "------------------------------------------------"
    relay_info_show "$local_port" "$remote_addr" "$remote_port"
    msg "------------------------------------------------"
    relay_warn_security
}

relay_main() {
    case ${1:-} in
    add)
        relay_add "${@:2}"
        ;;
    *)
        err "无法识别中转命令 (${1:-}), 正确用法: $is_core relay [add|list|info|delete]"
        ;;
    esac
}
```

3. In `main()`, add `relay)` case before `*)`:
```bash
    relay)
        relay_main "${@:2}"
        ;;
```

- [ ] **Step 4: Run tests and verify they pass.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
wsl -u root bash tests-snell-support.sh
```
Expected:
Both test scripts exit 0.

- [ ] **Step 5: Run syntax checks and commit.**

Run:
```bash
bash -n core.sh
bash -n src/core.sh
bash -n tests-relay-support.sh
git add tests-relay-support.sh core.sh src/core.sh
git commit -m "feat: implement relay add generation and validation"
```

---

### Task 2: Implement Relay List, Info, Delete with Rollback Safety & Fix-All Protection

**Files:**
- Modify: `tests-relay-support.sh` (add test cases for list, info, delete rollback, delete success, fix-all isolation)
- Modify: `src/core.sh` (implement `relay_list`, `relay_info`, `relay_delete`, and guard `fix-all`)
- Modify: `core.sh` (mirror identical implementations and `fix-all` guard)

**Interfaces:**
- Consumes: `relay_warn_security`, `relay_info_show`, `relay_add`, `relay_file` convention from Task 1.
- Produces: `relay_list`, `relay_info`, `relay_delete`, and wires them into `relay_main`.
- Protects: `relay-*.json` files from `fix-all`.

- [ ] **Step 1: Write failing tests for relay list, info, delete, and fix-all.**

In `tests-relay-support.sh`, append assertions to `run_core_case`:
```bash
# 8. relay info output format
info_out=$(main relay info 10000)
[[ $info_out == *"type = direct"* ]] || fail "relay info should contain type = direct"
[[ $info_out == *"listen = ::"* ]] || fail "relay info should contain listen = ::"
[[ $info_out == *"listen_port = 10000"* ]] || fail "relay info should contain listen_port = 10000"
[[ $info_out == *"override_address = 203.0.113.10"* ]] || fail "relay info should contain override_address"
[[ $info_out == *"override_port = 20000"* ]] || fail "relay info should contain override_port"
[[ $info_out == *"network = tcp,udp"* ]] || fail "relay info should report network = tcp,udp"
[[ $info_out == *"防火墙"* || $info_out == *"ACL"* ]] || fail "relay info should include security warning"
[[ $info_out != *"http"* && $info_out != *"vmess"* ]] || fail "relay info should not include share links"

# 9. relay list output
list_out=$(main relay list)
[[ $list_out == *"10000"* && $list_out == *"203.0.113.10"* && $list_out == *"20000"* ]] || fail "relay list should show relay 10000"
[[ $list_out == *"10001"* && $list_out == *"2001:db8::1"* ]] || fail "relay list should show relay 10001"
[[ $list_out == *"tcp,udp"* ]] || fail "relay list should report tcp,udp"
[[ $list_out == *"防火墙"* || $list_out == *"ACL"* ]] || fail "relay list should include security warning"

# 10. fix-all skips relay files
# create a normal direct node that would be touched by fix-all
cat > "$is_conf_dir/Direct-22222.json" <<'EOF'
{"inbounds":[{"tag":"Direct-22222.json","type":"direct","listen":"::","listen_port":22222}]}
EOF
content_before=$(cat "$is_conf_dir/relay-10000.json")
main fix-all >/dev/null 2>&1
content_after=$(cat "$is_conf_dir/relay-10000.json")
[[ "$content_before" == "$content_after" ]] || fail "fix-all must not alter relay-*.json"

# 11. relay delete rollback on complete config failure
TEST_REJECT_COMPLETE=1
(main relay delete 10000) >/dev/null 2>&1 && fail "relay delete should fail when complete config check fails"
[[ -f "$is_conf_dir/relay-10000.json" ]] || fail "relay file should be restored after delete check failure"
unset TEST_REJECT_COMPLETE

# 12. relay delete success
restart_count_before=$(grep -c "restart" "$manage_log" || true)
(main relay delete 10000) >/dev/null 2>&1 || fail "relay delete 10000 should succeed"
[[ ! -f "$is_conf_dir/relay-10000.json" ]] || fail "relay-10000.json should be deleted"
restart_count_after=$(grep -c "restart" "$manage_log" || true)
(( restart_count_after > restart_count_before )) || fail "manage restart should be called on delete"
[[ -f "$is_conf_dir/relay-10001.json" ]] || fail "other relay files should not be deleted"
```

- [ ] **Step 2: Run test to verify it fails.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
```
Expected: FAIL because `info`, `list`, and `delete` are not yet handled by `relay_main`, and `fix-all` touches relay files.

- [ ] **Step 3: Implement `relay_list`, `relay_info`, `relay_delete`, and update `fix-all`.**

In both `src/core.sh` and `core.sh`:
1. Implement `relay_info`:
```bash
relay_info() {
    local local_port=$1
    if [[ ! $local_port ]]; then
        relay_list
        ask string local_port "请输入要查看的中转本地端口:"
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    local relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || err "未找到中转配置 (relay-${local_port}.json)."
    local r_addr r_port
    r_addr=$(jq -r '.inbounds[0].override_address // empty' "$relay_file")
    r_port=$(jq -r '.inbounds[0].override_port // empty' "$relay_file")
    msg "\n------------- 中转配置信息 -------------"
    relay_info_show "$local_port" "$r_addr" "$r_port"
    msg "----------------------------------------"
    relay_warn_security
}
```

2. Implement `relay_list`:
```bash
relay_list() {
    local files count=0 file l_port r_addr r_port
    shopt -s nullglob
    files=("$is_conf_dir"/relay-*.json)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        msg "\n当前未配置任何中转.\n"
        return
    fi
    msg "\n------------- 中转列表 -------------"
    for file in "${files[@]}"; do
        l_port=$(jq -r '.inbounds[0].listen_port // empty' "$file")
        r_addr=$(jq -r '.inbounds[0].override_address // empty' "$file")
        r_port=$(jq -r '.inbounds[0].override_port // empty' "$file")
        msg "本地端口: $l_port -> 目标: $r_addr:$r_port (network: tcp,udp)"
        ((count++))
    done
    msg "------------------------------------"
    msg "共 $count 个中转"
    relay_warn_security
}
```

3. Implement `relay_delete`:
```bash
relay_delete() {
    local local_port=$1 relay_file backup_file
    if [[ ! $local_port ]]; then
        relay_list
        ask string local_port "请输入要删除的中转本地端口:"
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || err "未找到中转配置 (relay-${local_port}.json)."
    backup_file="$is_conf_dir/.relay-${local_port}.json.bak"
    mv -f "$relay_file" "$backup_file" || err "备份中转配置失败，未执行删除."
    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            mv -f "$backup_file" "$relay_file"
            err "删除中转后完整运行时配置校验失败，已恢复中转配置."
        fi
    fi
    rm -f "$backup_file"
    [[ -f $is_config_json ]] && sync_runtime_node_outbound_modes
    manage restart &
    _green "\n已删除中转配置: relay-${local_port}.json\n"
}
```

4. Update `relay_main` dispatcher:
```bash
relay_main() {
    case ${1:-} in
    add)
        relay_add "${@:2}"
        ;;
    list)
        relay_list
        ;;
    info)
        relay_info "${@:2}"
        ;;
    del | delete | rm)
        relay_delete "${@:2}"
        ;;
    "")
        relay_menu
        ;;
    *)
        err "无法识别中转命令 ($1), 正确用法: $is_core relay [add|list|info|delete]"
        ;;
    esac
}
```

5. In `fix-all` branch of both `core.sh` and `src/core.sh`, add skip guard for relay files:
```bash
            for is_json_file in "$is_conf_dir"/*.json; do
                v=${is_json_file##*/}
                [[ $v =~ dynamic-port-.*-link ]] && continue
                [[ $v == relay-*.json ]] && continue
                msg "fix: $v"
                change "$v" full
            done
```

- [ ] **Step 4: Run tests and verify they pass.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
```
Expected: All assertions in Steps 1-12 pass for both `core.sh` and `src/core.sh`.

- [ ] **Step 5: Run syntax checks and commit.**

Run:
```bash
bash -n core.sh
bash -n src/core.sh
bash -n tests-relay-support.sh
git add tests-relay-support.sh core.sh src/core.sh
git commit -m "feat: add relay list, info, delete with rollback and fix-all guard"
```

---

### Task 3: Interactive Menu Integration, Dispatcher & Documentation

**Files:**
- Modify: `tests-relay-support.sh` (add interactive submenu, dispatch, and documentation assertions)
- Modify: `src/core.sh` (add `relay_menu`, append `中转管理` to `mainmenu` and `is_main_menu`)
- Modify: `core.sh` (mirror identical `relay_menu` and menu integration)
- Modify: `src/help.sh` (document relay commands and security notice)
- Modify: `README.md` (document relay feature and command reference)

**Interfaces:**
- Consumes: `relay_main`, `relay_add`, `relay_list`, `relay_info`, `relay_delete`.
- Produces: `relay_menu`, `mainmenu` item 11, updated help output and README.

- [ ] **Step 1: Write failing assertions for menu and documentation.**

In `tests-relay-support.sh`:
```bash
# 13. main menu and empty relay subcommand dispatch
[[ "${mainmenu[10]}" == "中转管理" ]] || fail "mainmenu item 11 must be 中转管理"
(main relay unknown) >/dev/null 2>&1 && fail "unknown relay subcommand should fail"

# 14. documentation checks
grep -q 'relay add \[local-port\] \[remote-addr\] \[remote-port\]' src/help.sh || fail "help.sh missing relay add"
grep -q 'relay list' src/help.sh || fail "help.sh missing relay list"
grep -q 'relay info \[local-port\]' src/help.sh || fail "help.sh missing relay info"
grep -q 'relay delete \[local-port\]' src/help.sh || fail "help.sh missing relay delete"
grep -q '防火墙' src/help.sh || fail "help.sh missing firewall warning"
grep -q 'ACL' src/help.sh || fail "help.sh missing ACL warning"

grep -q 'relay add \[local-port\] \[remote-addr\] \[remote-port\]' README.md || fail "README missing relay add"
grep -q 'relay list' README.md || fail "README missing relay list"
grep -q 'relay info \[local-port\]' README.md || fail "README missing relay info"
grep -q 'relay delete \[local-port\]' README.md || fail "README missing relay delete"
grep -q '防火墙' README.md || fail "README missing firewall warning"
grep -q 'ACL' README.md || fail "README missing ACL warning"
grep -q '中转管理' README.md || fail "README missing interactive relay entry"
```

- [ ] **Step 2: Run test to verify it fails.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
```
Expected: FAIL due to missing menu item and missing documentation lines.

- [ ] **Step 3: Implement submenu and menu integration in `src/core.sh` and `core.sh`.**

1. Append `"中转管理"` to `mainmenu` array without renumbering items 0-9 (it becomes item 10, index 10, option 11 in 1-based display):
```bash
mainmenu=(
    "添加配置"
    "更改配置"
    "查看配置"
    "删除配置"
    "运行管理"
    "更新"
    "卸载"
    "帮助"
    "其他"
    "关于"
    "中转管理"
)
```

2. Implement `relay_menu()` in both `src/core.sh` and `core.sh`:
```bash
relay_menu() {
    is_tmp_list=("添加中转" "中转列表/信息" "删除中转" "返回主菜单")
    ask list is_relay_action null "\n请选择中转管理操作:\n"
    case $REPLY in
    1)
        relay_add
        ;;
    2)
        relay_list
        ask string local_port "请输入要查看的中转本地端口 (留空跳过):"
        [[ $local_port ]] && relay_info "$local_port"
        ;;
    3)
        relay_delete
        ;;
    4)
        is_main_menu
        ;;
    esac
}
```

3. In `is_main_menu()`, add case `11)`:
```bash
    10)
        load help.sh
        about
        ;;
    11)
        relay_menu
        ;;
```

- [ ] **Step 4: Update `src/help.sh` and `README.md`.**

In `src/help.sh`, add relay command section:
```text
            "中转:"
            "   relay add [local-port] [remote-addr] [remote-port]   添加中转 (sing-box 原生 direct, 支持 TCP/UDP)"
            "   relay list                                           中转列表"
            "   relay info [local-port]                              查看中转详情"
            "   relay delete [local-port]                            删除中转"
            "   中转管理亦可通过主菜单交互操作"
            "   中转无内置认证，请务必使用防火墙或网络 ACL 限制来源"
            "   中转不生成分享链接或二维码\n"
```

In `README.md`, add `- 一键添加端口中转 (原生 direct, 支持 TCP/UDP)` under `# 特点`, and add the relay section to the static command block.

- [ ] **Step 5: Run tests and verify they pass.**

Run:
```bash
wsl -u root bash tests-relay-support.sh
```
Expected: PASS: Task 1-3 coverage succeeds for both `core.sh` and `src/core.sh`.

- [ ] **Step 6: Run syntax checks and commit.**

Run:
```bash
bash -n core.sh
bash -n src/core.sh
bash -n src/help.sh
bash -n tests-relay-support.sh
git add tests-relay-support.sh core.sh src/core.sh src/help.sh README.md
git commit -m "feat: integrate relay menu and document relay commands"
```

---

### Task 4: Full Verification and Regression Audit

**Files:**
- Verify: `core.sh`, `src/core.sh`, `src/help.sh`, `README.md`, `tests-relay-support.sh`, `tests-snell-support.sh`, `tests-node-name-label.sh`.

- [ ] **Step 1: Run the full test suite.**

Run:
```bash
bash -n core.sh
bash -n src/core.sh
bash -n src/help.sh
bash -n tests-relay-support.sh
wsl -u root bash tests-relay-support.sh
wsl -u root bash tests-snell-support.sh
wsl -u root bash tests-node-name-label.sh
git diff --check
```
Expected: All syntax checks and tests pass with 0 exit code.

- [ ] **Step 2: Parity diff audit.**

Run:
```bash
git diff --no-index core.sh src/core.sh
```
Verify that all relay functions, dispatcher, menu integration, and `fix-all` guards are identical between `core.sh` and `src/core.sh`, and that only the pre-existing unrelated differences (e.g. process grep and url query params) differ.

- [ ] **Step 3: Document manual verification instructions.**

Document how to test live TCP/UDP forwarding on a real host running sing-box:
1. `sing-box relay add 10000 <target-ip> 80`
2. `curl -v http://127.0.0.1:10000` (verifies TCP forwarding)
3. `sing-box relay add 10053 8.8.8.8 53`
4. `dig @127.0.0.1 -p 10053 example.com` (verifies UDP forwarding)
5. `sing-box relay list`
6. `sing-box relay info 10000`
7. `sing-box relay delete 10000`
