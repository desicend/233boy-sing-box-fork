#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

source "$repo_root/core.sh"

is_conf_dir="$workdir/conf"
is_config_json="$workdir/config.json"
is_dont_auto_exit=1
mkdir -p "$is_conf_dir/.quan-meta"

cat > "$is_conf_dir/demo.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "demo.json",
      "type": "shadowsocks",
      "listen": "0.0.0.0",
      "listen_port": 12345,
      "method": "aes-128-gcm",
      "password": "pass123"
    }
  ],
  "outbounds": [
    {"type": "direct"},
    {"tag": "direct"}
  ]
}
EOF

is_config_file=demo.json

old_label=$(node_name_for_link "$is_config_file")
[[ "$old_label" == "demo" ]] || {
  echo "FAIL: baseline node label should be demo"
  echo "old_label=${old_label:-<empty>}"
  exit 1
}

change demo.json name NewLabel

[[ -f "$is_conf_dir/demo.json" ]] || {
  echo "FAIL: original json file missing after rename"
  exit 1
}
[[ ! -f "$is_conf_dir/NewLabel.json" ]] || {
  echo "FAIL: json filename was renamed, but should not be"
  exit 1
}

meta_file="$is_conf_dir/.quan-meta/demo.json.meta.json"
[[ -f "$meta_file" ]] || {
  echo "FAIL: node label metadata file not created"
  exit 1
}

jq -e '.node_name == "NewLabel"' "$meta_file" >/dev/null || {
  echo "FAIL: node label metadata value is incorrect"
  cat "$meta_file"
  exit 1
}

new_label=$(node_name_for_link "$is_config_file")
[[ "$new_label" == "NewLabel" ]] || {
  echo "FAIL: node_name_for_link should return NewLabel"
  echo "new_label=${new_label:-<empty>}"
  exit 1
}

grep -q 'is_node_name=$(node_name_for_link "$is_config_file")' "$repo_root/core.sh" || {
  echo "FAIL: core.sh no longer wires URL node label to node_name_for_link"
  exit 1
}

echo "PASS: node rename updates link label source without renaming json file"
