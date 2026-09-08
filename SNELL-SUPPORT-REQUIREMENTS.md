# Snell 协议与原生中转支持需求

- 项目：`one-singbox`
- 需求状态：Draft
- 目标版本：MVP
- 关联核心：`sing-box >= 1.14.0`
- 推荐首版：Snell v5 + sing-box 原生 `direct` 中转

## 1. 背景

当前脚本基于 sing-box 管理节点，已经支持 TUIC、Trojan、Hysteria2、Shadowsocks、VLESS、VMess、AnyTLS 等协议，但尚未支持 Snell，也没有统一的 sing-box 原生固定目标中转管理能力。

sing-box 从 1.14.0 开始提供 Snell 原生入站能力，因此本需求的目标是给管理脚本增加 Snell 配置的创建、查看、修改和校验能力，不引入官方 `snell-server` 二进制，也不引入 glibc 兼容层。

中转功能使用 sing-box 原生 `direct` 入站，通过 `override_address` 和 `override_port` 将入口端口转发到固定远端地址和端口，不引入 Realm 或其他独立中转程序。

官方参考：

- [sing-box Snell 入站配置](https://sing-box.sagernet.org/configuration/inbound/snell/)
- [sing-box Snell 出站配置](https://sing-box.sagernet.org/configuration/outbound/snell/)
- [sing-box Direct 入站配置](https://sing-box.sagernet.org/configuration/inbound/direct/)

## 2. 目标

用户可以通过现有脚本命令完成：

1. 添加一个 Snell v5 入站节点；
2. 自动生成或手动设置端口、PSK；
3. 查看 Snell 节点配置；
4. 修改端口、PSK、协议版本或混淆参数；
5. 删除、重启和校验 Snell 节点；
6. 添加一个固定目标的 TCP/UDP 中转入口；
7. 查看和删除中转配置；
8. 让生成的 Snell 和中转配置能够被 sing-box 原生校验并启动。

## 3. Snell MVP 范围

### 3.1 协议入口

在协议菜单中增加：

```text
Snell
```

命令行支持：

```bash
sing-box add snell
```

建议支持的参数形式：

```bash
sing-box add snell [port] [psk] [version]
```

其中：

- `port`：监听端口；未提供时沿用现有随机端口逻辑；
- `psk`：预共享密钥；未提供时安全随机生成；
- `version`：首版默认 `5`，允许显式指定 `5`。

### 3.2 配置生成

生成的节点配置应使用 sing-box 原生 Snell 入站格式：

```json
{
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-<port>",
      "listen": "::",
      "listen_port": 6160,
      "version": 5,
      "psk": "<generated-psk>",
      "obfs_mode": "none"
    }
  ]
}
```

要求：

- 遵循现有 `/etc/sing-box/conf/` 单节点 JSON 文件结构；
- 遵循现有主配置加载和节点路由机制；
- 默认监听地址保持现有双栈行为；
- Snell 不走 Caddy 自动 TLS；
- 不生成 `tls`、`reality`、`transport` 等不属于 Snell 的字段；
- PSK 不得复用 UUID 生成逻辑作为默认实现；
- tag 必须唯一，不得因重复添加节点产生冲突。

### 3.3 参数校验

- 检测 sing-box 版本，低于 `1.14.0` 时阻止创建并提示升级；
- 端口必须为 `1-65535`，且不能与现有节点或中转入口冲突；
- PSK 不得为空；
- `version` 首版只接受 `5`；
- `obfs_mode` 只允许 `none` 或 `http`；
- 生成后必须执行 `sing-box check`；
- 校验失败时不得覆盖原有有效配置。

### 3.4 查看与修改

`info` 应展示：

```text
协议 (protocol) = snell
地址 (address)
端口 (port)
版本 (version)
PSK
混淆模式 (obfs_mode)
```

`change` 至少支持：

- 修改端口；
- 修改 PSK；
- 修改 Snell 版本字段；
- 修改 `obfs_mode`。

修改流程必须先生成临时配置并通过 `sing-box check`，校验成功后再替换原配置。

### 3.5 URL 与二维码

Snell 没有本项目可以安全假设的统一通用分享链接格式。

MVP 要求：

- `info` 显示完整 Snell 参数；
- `url` / `qr` 不得生成伪造的 `snell://` 链接；
- 暂不支持通用 URL 和二维码时，明确提示“Snell 暂不支持通用分享链接，请使用配置参数导入”；
- 后续如支持 Surge 配置或特定客户端格式，应单独定义格式适配，不与通用 URL 混用。

## 4. sing-box 原生中转 MVP 范围

### 4.1 实现方式

中转必须使用 sing-box 原生 `direct` 入站，不引入 Realm、iptables REDIRECT、socat 或其他独立中转程序。

逻辑链路：

```text
客户端 → 本机监听地址:本地端口
       → sing-box direct inbound
       → 远端地址:远端端口
```

生成的单个中转配置示例：

```json
{
  "type": "direct",
  "tag": "direct-<local-port>",
  "listen": "::",
  "listen_port": 10000,
  "override_address": "203.0.113.10",
  "override_port": 20000
}
```

要求：

- 使用 `type: "direct"`；
- 使用 `override_address` 指定远端地址；
- 使用 `override_port` 指定远端端口；
- 默认支持 TCP 和 UDP，除非现有配置明确限制网络类型；
- 默认监听地址保持现有双栈行为；
- 中转不解析、不终止 Snell、VLESS、Shadowsocks 等上层协议；
- 后端节点的协议认证仍由后端服务完成；
- 中转 tag 必须唯一；
- 本地监听端口不得与任何节点或其他中转冲突。

### 4.2 命令接口

建议增加：

```bash
sing-box relay add [local-port] [remote-address] [remote-port]
sing-box relay list
sing-box relay info [local-port]
sing-box relay delete [local-port]
```

交互式菜单至少提供：

1. 添加中转；
2. 查看中转；
3. 删除中转；
4. 返回。

MVP 不要求中转支持逐字段修改；修改可以通过删除后重新添加完成。后续可增加 `relay change`。

### 4.3 中转参数校验

- 本地端口必须为 `1-65535`；
- 远端端口必须为 `1-65535`；
- 本地端口不能与已有入站或其他中转重复；
- 远端地址不能为空；
- IPv4、IPv6 地址必须能被正确写入 JSON；
- 生成后必须执行 `sing-box check`；
- 校验失败时不得覆盖原有有效配置；
- 添加、删除中转后仅在配置校验通过时重启服务；
- 监听公网地址且无认证时，命令输出必须明确提示需要通过防火墙或网络 ACL 限制来源。

### 4.4 中转查看与连接信息

`relay info` / `relay list` 至少展示：

```text
类型 (type) = direct
本地监听地址 (listen)
本地端口 (listen_port)
远端地址 (override_address)
远端端口 (override_port)
网络类型 (network)
```

中转不得生成伪造的 Snell、VLESS 或其他协议分享链接。客户端应使用中转入口地址和端口，并继续使用后端节点的协议认证参数。

## 5. 暂不纳入 MVP

以下内容放到后续版本：

1. Snell v6；
2. v4/v5/v6 多版本共存；
3. 多用户 `users` / `userkey` 管理；
4. Snell 出站管理；
5. 官方 `snell-server` 安装；
6. Docker 管理；
7. Surge、Loon、Egern 等客户端的专用分享链接；
8. QUIC Proxy Mode；
9. ShadowTLS 与 Snell 的组合管理；
10. Realm 集成；
11. 中转鉴权、来源 IP ACL、限速和流量统计；
12. 中转健康检查、故障转移、负载均衡；
13. 中转目标域名解析和动态目标；
14. 中转配置的原地修改命令。

## 6. 可能涉及的代码区域

实现前需要确认两份核心脚本的职责和同步方式：

- `core.sh`
- `src/core.sh`

重点修改区域：

1. `protocol_list`：增加 Snell 菜单项；
2. `add()`：增加 `snell` 别名和参数解析；
3. `get protocol`：增加 Snell JSON 生成分支；
4. `info()`：增加 Snell 字段读取和展示；
5. `change()`：增加 Snell 可修改字段；
6. `url_qr()`：增加明确的不支持提示，禁止生成错误链接；
7. 中转命令分发：增加 `relay add/list/info/delete`；
8. 中转配置生成：增加 `direct` 入站和 `override_address/override_port`；
9. 端口冲突检查：统一检查节点与中转的监听端口；
10. 配置写入：统一采用临时文件校验成功后的原子替换；
11. `help` / `README.md`：增加命令、版本要求和中转安全提示；
12. 测试脚本：增加 Snell 配置生成、中转配置生成、校验和版本门禁测试。

注意：当前仓库中的 `core.sh` 和 `src/core.sh` 不是完全相同文件，实施前必须明确哪个是源文件，并确保发布包中的另一份同步更新。

## 7. 验收标准

### 7.1 Snell 功能验收

- [ ] 菜单中可以选择 Snell；
- [ ] `sing-box add snell` 可以创建 Snell v5 配置；
- [ ] 未提供 PSK 时可以生成随机 PSK；
- [ ] 生成配置包含正确的 `type`、`listen_port`、`version`、`psk`；
- [ ] `sing-box info` 可以展示 Snell 关键参数；
- [ ] 可以修改 PSK 和端口；
- [ ] 可以删除 Snell 节点；
- [ ] 不会生成伪造的通用分享链接。

### 7.2 中转功能验收

- [ ] `sing-box relay add` 可以生成 `direct` 入站；
- [ ] 生成配置包含正确的 `listen_port`、`override_address`、`override_port`；
- [ ] `sing-box relay list/info` 可以展示中转参数；
- [ ] 可以删除指定中转；
- [ ] 中转不会生成 Realm 配置或启动 Realm 进程；
- [ ] TCP 中转实测可达后端目标；
- [ ] UDP 中转实测可达后端目标；
- [ ] 中转入口端口与已有节点冲突时会拒绝创建；
- [ ] 公网监听且无鉴权时会显示安全警告。

### 7.3 兼容性验收

- [ ] sing-box `1.14.0+` 配置通过 `sing-box check`；
- [ ] sing-box 服务可以正常启动；
- [ ] Snell 监听端口在 TCP 层面符合配置预期；
- [ ] 中转监听端口在 TCP、UDP 层面符合配置预期；
- [ ] 使用至少一个实际 Snell 客户端完成 TCP 连接测试；
- [ ] 通过 Snell 中转入口完成一次实际客户端连接测试；
- [ ] 原有 VLESS、VMess、Shadowsocks、Trojan 等节点不受影响；
- [ ] sing-box 低于 `1.14.0` 时能够阻止创建 Snell 并给出清晰提示。

## 8. 风险与处理

| 风险 | 影响 | 处理方式 |
|---|---|---|
| sing-box 版本过低 | Snell 配置无法识别 | 创建前增加版本门禁 |
| Snell 客户端版本差异 | 节点无法互通 | MVP 固定 v5，并做实际客户端测试 |
| PSK 处理不当 | 节点泄露或无法连接 | 使用安全随机生成，修改前先校验 |
| 没有统一分享链接 | 用户无法扫码导入 | MVP 输出参数，不伪造 URL |
| 两份 `core.sh` 不一致 | 发布后功能缺失 | 明确源文件并增加同步检查 |
| 现有节点被误覆盖 | 已有业务中断 | 临时文件校验成功后原子替换 |
| `direct` 中转暴露公网 | 形成开放转发器 | 显示警告，并建议防火墙或 ACL 限制来源 |
| IPv4/IPv6 监听不一致 | 客户端无法连接 | 提供明确监听地址，优先验证双栈行为 |
| 中转本地端口重复 | 服务启动失败 | 创建前统一检查全部监听端口 |
| 中转 UDP 行为与预期不符 | UDP 应用不可用 | 使用真实 UDP 目标做端到端测试 |
| 中转配置语义不兼容 | sing-box 无法启动 | 写入前运行 `sing-box check`，失败不覆盖旧配置 |

## 9. 回滚方案

本需求只新增 Snell 分支、中转分支和相关文档，不改变已有协议的配置格式。

若上线后出现问题：

1. 停止使用 Snell 和中转创建入口；
2. 删除 Snell 和中转分支、菜单项及命令分发；
3. 删除已经创建且确认有问题的 Snell 或 `direct` 入站配置；
4. 保留已有节点 JSON；
5. 恢复变更前的脚本文件；
6. 运行现有协议的配置校验和启动测试。

已有 VLESS、VMess、Shadowsocks、Trojan 等节点不应因为 Snell 或中转功能回滚而被删除或重建。

## 10. 推荐实现顺序

1. 先明确 `core.sh` 与 `src/core.sh` 的源文件和发布同步关系；
2. 实现 Snell v5 配置生成；
3. 加入 sing-box 版本门禁；
4. 加入 Snell `info`、修改和配置校验；
5. 实现 `direct` 中转的 add/list/info/delete；
6. 加入统一端口冲突检查和临时文件原子替换；
7. 完成 TCP、UDP 和实际 Snell 客户端互通测试；
8. 验证原有协议无回归；
9. 再评估 Snell v6、多用户和中转 ACL 等后续能力。
