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
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf "%s\n" "$*" >>"$manage_log"; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf "%s\n" "$1"; }

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
) >"$case_dir/snell-version.out" 2>&1 && fail "unsupported Snell version should fail"
[[ ! -f $is_conf_dir/snell-41603.json ]] || fail "unsupported version should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 0 supplied-psk 5
) >"$case_dir/snell-port-zero.out" 2>&1 && fail "port 0 should fail"
[[ ! -f $is_conf_dir/snell-0.json ]] || fail "port 0 should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 65536 supplied-psk 5
) >"$case_dir/snell-port-high.out" 2>&1 && fail "port 65536 should fail"
[[ ! -f $is_conf_dir/snell-65536.json ]] || fail "port 65536 should not create target file"

jq -n '{inbounds:[{type:"vmess",listen_port:41604}]}' >"$is_conf_dir/existing.json"
(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41604 supplied-psk 5
) >"$case_dir/snell-conflict.out" 2>&1 && fail "saved config port conflict should fail"
[[ ! -f $is_conf_dir/snell-41604.json ]] || fail "port conflict should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  TEST_ACTIVE_PORT=41610
  add snell 41610 supplied-psk 5
) >"$case_dir/snell-active-port.out" 2>&1 && fail "active listener port conflict should fail"
[[ ! -f $is_conf_dir/snell-41610.json ]] || fail "active listener port conflict should not create target file"

invalid_obfs_output=$(
  snell_psk=supplied-psk
  snell_version=5
  snell_obfs_mode=quic
  port=41611
  is_core_ver=1.14.0
  validate_snell
) 2>&1
[[ $? != 0 ]] || fail "unsupported obfs mode should fail"

empty_psk_output=$(
  snell_psk=
  snell_version=5
  snell_obfs_mode=none
  port=41612
  is_core_ver=1.14.0
  validate_snell
) 2>&1
[[ $? != 0 ]] || fail "empty PSK should fail"

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
for malformed_case in "1.14garbage:41607" "1.14.0garbage:41608"; do
  malformed_version=${malformed_case%%:*}
  malformed_port=${malformed_case##*:}
  malformed_output=$( (
    unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
    is_core_ver=$malformed_version
    add snell "$malformed_port" supplied-psk 5
  ) 2>&1 )
  [[ $? != 0 ]] || fail "$malformed_version should fail Snell creation"
  [[ $malformed_output == *1.14.0* ]] || fail "$malformed_version failure should mention 1.14.0"
  [[ ! -f $is_conf_dir/snell-$malformed_port.json ]] || fail "$malformed_version should not create target file"
done

jq -n \
  '{inbounds:[{tag:"snell-41601.json",type:"snell",listen:"::",listen_port:41601,version:5,psk:"old-psk",obfs_mode:"http"}]}' \
  >"$is_conf_dir/snell-41601.json"
jq -n '{node_name:"snell-node",entry_addr:"edge.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41601.json.meta.json"

is_dont_show_info=1
info snell-41601.json
[[ $is_protocol == snell ]] || fail "info should identify Snell protocol"
[[ $port == 41601 ]] || fail "info should extract Snell port"
[[ $snell_version == 5 ]] || fail "info should extract Snell version"
[[ $snell_psk == old-psk ]] || fail "info should extract Snell PSK"
[[ $snell_obfs_mode == http ]] || fail "info should extract Snell obfs mode"
[[ -z ${is_url:-} ]] || fail "Snell info should not create a URL"
old_is_dont_auto_exit=$is_dont_auto_exit
is_dont_show_info=
is_dont_auto_exit=
info_output=$(info snell-41601.json)
for label in "协议 (protocol)" "版本 (version)" "PSK" "混淆模式 (obfs_mode)"; do
  [[ $info_output == *"$label"* ]] || fail "Snell info output should include $label"
done
is_dont_show_info=1
is_dont_auto_exit=$old_is_dont_auto_exit

change snell-41601.json psk new-psk || fail "Snell PSK change should succeed"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41601.json") == new-psk ]] || fail "Snell PSK change was not saved"

change snell-41601.json snell-version 5 || fail "Snell version change should succeed"
[[ $(jq -r '.inbounds[0].version' "$is_conf_dir/snell-41601.json") == 5 ]] || fail "Snell version change was not saved"

change snell-41601.json obfs none || fail "Snell obfs change should succeed"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == none ]] || fail "Snell obfs change was not saved"

if ! (TEST_ACTIVE_PORT=41601 change snell-41601.json port 41601 >/dev/null 2>&1); then
  fail "same-port Snell change should ignore the current active listener"
fi
[[ -f $is_conf_dir/snell-41601.json ]] || fail "same-port Snell change should keep the existing filename"

change snell-41601.json port 41606 || fail "Snell port change should succeed"
[[ ! -f $is_conf_dir/snell-41601.json ]] || fail "old Snell port file should be removed after replacement"
[[ -f $is_conf_dir/snell-41606.json ]] || fail "new Snell port file should exist after replacement"
jq -e '.node_name == "snell-node" and .entry_addr == "edge.example.com" and .outbound_mode == "V4优先"' \
  "$is_conf_dir/.quan-meta/snell-41606.json.meta.json" >/dev/null || fail "Snell metadata should move with port change"

wait
manage_before=$(wc -l <"$manage_log")
failure_output=$( (change snell-41606.json psk reject-me) 2>&1 )
[[ $? != 0 ]] || fail "rejected Snell replacement should fail"
wait
manage_after=$(wc -l <"$manage_log")
[[ $manage_after == $manage_before ]] || fail "rejected replacement should not restart the service"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41606.json") == new-psk ]] || fail "rejected replacement should preserve old JSON"
[[ -f $is_conf_dir/.quan-meta/snell-41606.json.meta.json ]] || fail "rejected replacement should preserve metadata"
if compgen -G "$is_conf_dir/.snell-*" >/dev/null; then
  fail "rejected replacement should remove temporary files"
fi

url_output=$( (url_qr url snell-41606.json) 2>&1 )
url_status=$?
[[ $url_status != 0 ]] || fail "Snell URL command unexpectedly succeeded"
[[ $url_output == *'Snell 暂不支持通用分享链接，请使用配置参数导入'* ]] || fail "Snell URL command should show parameter-import guidance"

qr_output=$( (url_qr qr snell-41606.json) 2>&1 )
qr_status=$?
[[ $qr_status != 0 ]] || fail "Snell QR command unexpectedly succeeded"
[[ $qr_output == *'Snell 暂不支持通用分享链接，请使用配置参数导入'* ]] || fail "Snell QR command should show parameter-import guidance"
[[ $url_output != *'snell://'* ]] || fail "Snell URL output must not contain a snell:// URL"
[[ $qr_output != *'snell://'* ]] || fail "Snell QR output must not contain a snell:// URL"

del snell-41606.json
[[ ! -e "$is_conf_dir/snell-41606.json" ]] || fail "Snell delete should remove the node JSON"
CASE
}

run_core_case "$repo_root/core.sh" || exit 1
run_core_case "$repo_root/src/core.sh" || exit 1

grep -q 'Snell' "$repo_root/src/help.sh" || fail "src/help.sh should document Snell"
grep -q 'add snell \[port\] \[psk\] \[version\]' "$repo_root/src/help.sh" || fail "src/help.sh should document Snell add syntax"
grep -q '1.14.0' "$repo_root/src/help.sh" || fail "src/help.sh should document the Snell version floor"
grep -q 'Snell' "$repo_root/README.md" || fail "README.md should document Snell"
grep -q 'add snell \[port\] \[psk\] \[version\]' "$repo_root/README.md" || fail "README.md should document Snell add syntax"
grep -q '1.14.0' "$repo_root/README.md" || fail "README.md should document the Snell version floor"

echo "PASS: Snell offline generation and validation coverage"
