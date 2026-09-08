# Sing-box: Snell v6 协议支持设计规范

**状态:** 待用户评审 (Pending User Review)
**创建日期:** 2026-09-08
**目标项目:** `one-singbox`
**依赖核心:** `sing-box >= 1.14.0`

---

## 1. 目标与定位

1. **升级 Snell 默认版本为 v6**：执行 `sing-box add snell` 时默认创建 Snell v6 节点，享受 PSK 派生的部署级流量多样性（Deployment-Level Diversity）以增强公网直连抗审查能力。
2. **完全向下兼容 Snell v5**：允许用户显式指定版本参数创建或切换为 Snell v5 节点。
3. **版本自适应配置生成**：
   - Snell v6：入站配置生成 `version: 6`，引入 `mode: "default"`（支持 `unshaped`、`unsafe-raw`），剔除 `obfs_mode`；
   - Snell v5：入站配置生成 `version: 5`，保留 `obfs_mode: "none"`（支持 `http`），剔除 `mode`。
4. **严格的参数校验**：
   - 对 v6 节点的 PSK 强制校验长度必须在 $12 \sim 255$ 字符之间；
   - 模式校验：v6 校验 `mode in (default, unshaped, unsafe-raw)`，v5 校验 `obfs_mode in (none, http)`。
5. **CLI 与交互自适应**：
   - 新增 `sing-box mode` 命令，且与 `obfs` 智能互通路由；
   - 修改节点时，根据节点版本自适应展示「更改运行模式」或「更改混淆模式」；
   - 支持通过 `snell-version` 在 5 与 6 之间平滑互转并自动迁移清洗特有字段。
6. **导出格式自适应**：
   - Surge 单行配置根据版本自适应输出（v6 携带 `version=6` 及非 default 时的 `mode=...`；v5 携带 `version=5` 与 `obfs=...`）；
   - sing-box URI 自适应输出；
   - **二维码策略**：默认不提供二维码，仅输出 URL 链接与 Surge 配置。

---

## 2. 详细设计与规范

### 2.1 数据模型与 JSON 结构

#### Snell v6 Inbound (默认)
```json
{
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-<port>.json",
      "listen": "::",
      "listen_port": 6160,
      "version": 6,
      "psk": "<psk>",
      "mode": "default"
    }
  ]
}
```

#### Snell v5 Inbound (兼容)
```json
{
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-<port>.json",
      "listen": "::",
      "listen_port": 6160,
      "version": 5,
      "psk": "<psk>",
      "obfs_mode": "none"
    }
  ]
}
```

#### 关键约束
* 严禁将 `obfs_mode` 写入 v6 配置；
* 严禁将 `mode` 写入 v5 配置；
* 生成配置文件后，依然先写入临时文件 `$is_conf_dir/.snell-XXXXXX.json` 并调用 `$is_core_bin check -c` 严格校验，通过后方可持久化。

---

### 2.2 参数校验与默认值 (`validate_snell`)

1. **核心版本依赖**：
   - 依赖 `sing-box >= 1.14.0`（v5 与 v6 均在该版本正式引入）。
2. **版本合法性**：
   - `snell_version_valid` 放行版本：`[[ $1 == 5 || $1 == 6 ]]`；
   - 默认版本：`[[ ! $snell_version ]] && snell_version=6`。
3. **PSK 长度校验**：
   - 默认生成：`get_snell_psk` 继续使用 `openssl rand -base64 32` 生成 44 字符密钥；
   - 若 `snell_version == 6`：严格校验 `${#snell_psk} -ge 12 && ${#snell_psk} -le 255`，不足 12 位时报错阻断；
   - 若 `snell_version == 5`：校验 `[[ $snell_psk ]]` 非空。
4. **运行模式 / 混淆模式校验**：
   - 若 `snell_version == 6`：
     - 默认模式：`[[ ! $snell_mode ]] && snell_mode=default`；
     - 校验规则：`[[ $snell_mode =~ ^(default|unshaped|unsafe-raw)$ ]]`；
   - 若 `snell_version == 5`：
     - 默认混淆：`[[ ! $snell_obfs_mode ]] && snell_obfs_mode=none`；
     - 校验规则：`[[ $snell_obfs_mode =~ ^(none|http)$ ]]`。

---

### 2.3 命令行接口 (CLI) 与交互菜单

#### 1. 创建节点
* 语法：`sing-box add snell [port] [psk] [version]`
  * `port`：可选，缺省时随机分配可用端口；
  * `psk`：可选，缺省时自动调用 `get_snell_psk` 生成；
  * `version`：可选，**缺省时为 `6`**；支持显式传入 `5`。

#### 2. 参数修改命令
* `sing-box psk [name] [psk | auto]`：
  * 修改 PSK；若目标节点为 v6，执行 $\ge 12$ 字符校验；
* `sing-box snell-version [name] [6 | 5 | auto]`：
  * 更改版本，`auto` 设为 `6`；
* `sing-box mode [name] [default | unshaped | unsafe-raw | auto]`：
  * **[新增]** 修改 v6 节点运行模式，`auto` 设为 `default`；
* `sing-box obfs [name] [none | http | auto]`：
  * 修改 v5 节点混淆模式。

#### 3. CLI 智能路由与兼容
* 当针对 **v6 节点** 执行 `sing-box obfs`：
  * 若参数为 `default | unshaped | unsafe-raw`，直接作为 `mode` 处理；
  * 若参数为 `none | http`，友好提示当前为 v6 节点，并自动适配为 `default` 或引导使用 `mode`；
* 当针对 **v5 节点** 执行 `sing-box mode`：
  * 自动路由到 v5 的 `obfs` 修改逻辑。

#### 4. 交互式修改菜单自适应
在节点管理修改菜单中，动态判断目标节点版本：
* **v6 节点**：显示「`更改 Snell 运行模式`」，子菜单提供：
  1. `default`（推荐，流量整形混淆）
  2. `unshaped`（仅加密，无混淆，吞吐量提升约 10%）
  3. `unsafe-raw`（明文转发，仅用于内网安全隧道）
* **v5 节点**：显示「`更改 Snell 混淆模式`」，子菜单提供：
  1. `none`
  2. `http`

#### 5. 版本互转迁移机制 (v5 $\longleftrightarrow$ v6)
执行版本切换时：
* **v5 $\to$ v6**：
  * 自动剔除配置中的 `obfs_mode`；
  * 自动填充 `mode: "default"`；
  * 检测 PSK 长度：若 $< 12$ 字符，提示不符合 v6 规范并自动调用 `get_snell_psk` 替换或要求重新输入。
* **v6 $\to$ v5**：
  * 自动剔除配置中的 `mode`；
  * 自动填充 `obfs_mode: "none"`；
  * 保留原 PSK。

---

### 2.4 节点详情与导出格式

#### 1. 终端详情展示 (`get info` / 查看节点)
* **v6 节点**：
  * 协议：`Snell`
  * 地址：`$is_addr`
  * 端口：`$port`
  * 版本：`6`
  * 密钥 (PSK)：`$snell_psk`
  * 运行模式：`$snell_mode`（`default` / `unshaped` / `unsafe-raw`）
* **v5 节点**：
  * 协议：`Snell`
  * 地址：`$is_addr`
  * 端口：`$port`
  * 版本：`5`
  * 密钥 (PSK)：`$snell_psk`
  * 混淆模式：`$snell_obfs_mode`（`none` / `http`）

#### 2. Surge 格式导出
* **v6 节点**：
  * `mode == default` 时：
    `[node_name] = snell, [addr], [port], psk=[psk], version=6`
  * `mode != default` 时：
    `[node_name] = snell, [addr], [port], psk=[psk], version=6, mode=[mode]`
* **v5 节点**：
  * `[node_name] = snell, [addr], [port], psk=[psk], version=5[, obfs=http]`

#### 3. sing-box URI 导出
* **v6 节点**：
  * `mode == default` 时：
    `snell://[psk]@[addr]:[port]?version=6#[node_name]`
  * `mode != default` 时：
    `snell://[psk]@[addr]:[port]?version=6&mode=[mode]#[node_name]`
* **v5 节点**：
  * `snell://[psk]@[addr]:[port]?version=5[&obfs=http]#[node_name]`

#### 4. 二维码策略
* **默认不提供二维码**：无论是节点创建、查看详情还是导出分享，Snell 均不生成、不展示二维码，仅输出 URL 链接与 Surge 配置行；
* 若用户显式调用 `sing-box qr [name]`，输出明确提示：`Snell 默认不提供二维码，请使用 URL 链接或 Surge 配置`。

---

## 3. 受影响文件清单

1. `src/core.sh` 与 `core.sh`：
   - 修改 `snell_version_valid` 支持 5 和 6；
   - 升级 `validate_snell` 增加 v6 约束（PSK 长度 $\ge 12$、mode 校验）；
   - 更新 `create server` 生成 v6/v5 专属纯净 JSON；
   - 更新 `get info` 解析 `.inbounds[0].mode`；
   - 更新 `url_qr` / `info` 呈现自适应 Surge/URI 导出，保持默认不输出二维码；
   - 新增 `mode` 命令行分支与修改菜单自适应。
2. `src/help.sh`：
   - 补充 `mode` 命令帮助说明，更新 Snell 默认版本说明。
3. `tests-snell-support.sh`：
   - 更新测试用例：覆盖 v6 默认创建、v5 兼容创建、PSK 长度边界拦截、非法版本拦截、模式切换与跨版本平滑迁移。

---

## 4. 验证计划

1. **自动化测试套件 (`tests-snell-support.sh`)**：
   - 验证 `add snell [port]` 默认生成合规的 `version=6`、`mode="default"` 配置且通过 sing-box check；
   - 验证 `add snell [port] [psk] 5` 成功生成 `version=5`、`obfs_mode="none"` 配置；
   - 验证输入小于 12 位的 PSK 配合 v6 会被拒绝并拦截创建；
   - 验证输入版本 4 或 7 会被拦截；
   - 验证 `sing-box mode` 正确修改 v6 mode；
   - 验证 `snell-version` 顺利在 5 和 6 之间迁移且字段干净；
   - 验证输出格式符合 Surge 和 URI 规范，且不提供二维码；
   - 保证所有测试 100% 通过。
2. **语法检查**：
   - `bash -n src/core.sh`
   - `bash -n core.sh`
