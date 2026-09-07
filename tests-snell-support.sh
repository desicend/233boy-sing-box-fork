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
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c)
            config=$2
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    [[ -f $config ]] || exit 1
    jq -e '
        (.inbounds | length == 1)
        and (.inbounds[0].type == "snell")
        and (.inbounds[0].listen == "::")
        and (.inbounds[0].listen_port | type == "number")
        and (.inbounds[0].version == 5)
        and ((.inbounds[0].psk | type) == "string")
        and ((.inbounds[0].psk | length) > 0)
        and (.inbounds[0].obfs_mode == "none" or .inbounds[0].obfs_mode == "http")
        and ((.inbounds[0] | has("tls")) | not)
        and ((.inbounds[0] | has("reality")) | not)
        and ((.inbounds[0] | has("transport")) | not)
    ' "$config" >/dev/null || exit 1
    [[ $(jq -r '.inbounds[0].psk' "$config") != reject-me ]] || exit 1
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
ip=203.0.113.10
is_dont_show_info=1
is_dont_auto_exit=1
mkdir -p "$is_conf_dir/.quan-meta"
manage() { :; }
get_snell_psk() { printf '%s\n' generated-psk; }

[[ " ${protocol_list[*]} " == *' Snell '* ]] || fail "protocol_list should include Snell"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41601 supplied-psk 5
) || fail "add snell with explicit PSK should succeed"
config=$is_conf_dir/snell-41601.json
[[ -f $config ]] || fail "expected $config to be created"
jq -e '
    .inbounds[0].type == "snell"
    and .inbounds[0].tag == "snell-41601.json"
    and .inbounds[0].listen == "::"
    and .inbounds[0].listen_port == 41601
    and .inbounds[0].version == 5
    and .inbounds[0].psk == "supplied-psk"
    and .inbounds[0].obfs_mode == "none"
' "$config" >/dev/null || fail "explicit PSK Snell JSON has unexpected shape"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41602
) || fail "add snell with generated PSK should succeed"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41602.json") == generated-psk ]] || fail "omitted PSK should use get_snell_psk"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41603 supplied-psk 6
) >/tmp/snell-version.out 2>&1 && fail "unsupported Snell version should fail"
[[ ! -f $is_conf_dir/snell-41603.json ]] || fail "unsupported version should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 0 supplied-psk 5
) >/tmp/snell-port-zero.out 2>&1 && fail "port 0 should fail"
[[ ! -f $is_conf_dir/snell-0.json ]] || fail "port 0 should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 65536 supplied-psk 5
) >/tmp/snell-port-high.out 2>&1 && fail "port 65536 should fail"
[[ ! -f $is_conf_dir/snell-65536.json ]] || fail "port 65536 should not create target file"

jq -n '{inbounds:[{type:"vmess",listen_port:41604}]}' >"$is_conf_dir/existing.json"
(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41604 supplied-psk 5
) >/tmp/snell-conflict.out 2>&1 && fail "saved config port conflict should fail"
[[ ! -f $is_conf_dir/snell-41604.json ]] || fail "port conflict should not create target file"

version_output=$((
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  is_core_ver=1.13.9
  add snell 41605 supplied-psk 5
) 2>&1)
[[ $? != 0 ]] || fail "sing-box 1.13.9 should fail Snell creation"
[[ $version_output == *1.14.0* ]] || fail "1.13.9 failure should mention 1.14.0"
[[ ! -f $is_conf_dir/snell-41605.json ]] || fail "unsupported core version should not create target file"

unknown_output=$((
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  is_core_ver=unknown
  add snell 41606 supplied-psk 5
) 2>&1)
[[ $? != 0 ]] || fail "unknown sing-box version should fail Snell creation"
[[ $unknown_output == *1.14.0* ]] || fail "unknown version failure should mention 1.14.0"
[[ ! -f $is_conf_dir/snell-41606.json ]] || fail "unknown core version should not create target file"
CASE
}

run_core_case "$repo_root/core.sh" || exit 1
run_core_case "$repo_root/src/core.sh" || exit 1

echo "PASS: Snell offline generation and validation coverage"
