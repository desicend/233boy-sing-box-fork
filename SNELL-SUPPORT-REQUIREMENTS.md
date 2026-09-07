# Snell 协议支持需求（简版）

- 项目：`233boy-sing-box-fork`
- 需求状态：Draft
- 目标版本：MVP
- 关联核心：`sing-box >= 1.14.0`
- 推荐首版：Snell v5

## 1. 背景

当前脚本基于 sing-box 管理节点，已经支持 TUIC、Trojan、Hysteria2、Shadowsocks、VLESS、VMess、AnyTLS 等协议，但尚未支持 Snell。

sing-box 从 1.14.0 开始提供 Snell 原生入站能力，因此本需求的目标是给管理脚本增加 Snell 配置的创建、查看、修改和校验能力，不引入官方 `snell-server` 二进制，也不引入 glibc 兼容层。

官方参考：

- [sing-box Snell 入站配置](https://sing-box.sagernet.org/configuration/inbound/snell/)
- [sing-box Snell 出站配置](https://sing-box.sagernet.org/configuration/outbound/snell/)

## 2. 目标

用户可以通过现有脚本命令完成：

1. 添加一个 Snell v5 入站节点；
2. 自动生成或手动设置端口、PSK；
3. 查看 Snell 节点配置；
4. 修改端口、PSK、协议版本或混淆参数；
5. 删除、重启和校验 Snell 节点；
6. 让生成的配置能够被 sing-box 原生校验并启动。

## 3. MVP 范围

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
      "tag": "snell-<port>.json",
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
- PSK 不得复用 UUID 生成逻辑作为默认实现。

### 3.3 参数校验

- 检测 sing-box 版本，低于 `1.14.0` 时阻止创建并提示升级；
- 端口必须为 `1-65535`，且不能与现有节点冲突；
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

## 4. 暂不纳入 MVP

以下内容放到后续版本：

1. Snell v6；
2. v4/v5/v6 多版本共存；
3. 多用户 `users` / `userkey` 管理；
4. Snell 出站管理；
5. 官方 `snell-server` 安装；
6. Docker 管理；
7. Surge、Loon、Egern 等客户端的专用分享链接；
8. QUIC Proxy Mode；
9. ShadowTLS 与 Snell 的组合管理。

## 5. 可能涉及的代码区域

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
7. `help` / `README.md`：增加命令和版本要求；
8. 测试脚本：增加 Snell 配置生成、校验和版本门禁测试。

注意：当前仓库中的 `core.sh` 和 `src/core.sh` 不是完全相同文件，实施前必须明确哪个是源文件，并确保发布包中的另一份同步更新。

## 6. 验收标准

### 功能验收

- [ ] 菜单中可以选择 Snell；
- [ ] `sing-box add snell` 可以创建 Snell v5 配置；
- [ ] 未提供 PSK 时可以生成随机 PSK；
- [ ] 生成配置包含正确的 `type`、`listen_port`、`version`、`psk`；
- [ ] `sing-box info` 可以展示 Snell 关键参数；
- [ ] 可以修改 PSK 和端口；
- [ ] 可以删除 Snell 节点；
- [ ] 不会生成伪造的通用分享链接。

### 兼容性验收

- [ ] sing-box `1.14.0+` 配置通过 `sing-box check`；
- [ ] sing-box 服务可以正常启动；
- [ ] 监听端口在 TCP、UDP 层面符合配置预期；
- [ ] 使用至少一个实际 Snell 客户端完成 TCP 连接测试；
- [ ] 原有 VLESS、VMess、Shadowsocks、Trojan 等节点不受影响；
- [ ] sing-box 低于 `1.14.0` 时能够阻止创建并给出清晰提示。

## 7. 风险与处理

| 风险 | 影响 | 处理方式 |
|---|---|---|
| sing-box 版本过低 | 配置无法识别 | 创建前增加版本门禁 |
| Snell 客户端版本差异 | 节点无法互通 | MVP 固定 v5，并做实际客户端测试 |
| PSK 处理不当 | 节点泄露或无法连接 | 使用安全随机生成，修改前先校验 |
| 没有统一分享链接 | 用户无法扫码导入 | MVP 输出参数，不伪造 URL |
| 两份 `core.sh` 不一致 | 发布后功能缺失 | 明确源文件并增加同步检查 |
| 现有节点被误覆盖 | 已有业务中断 | 临时文件校验成功后原子替换 |

## 8. 回滚方案

本需求只新增 Snell 分支和相关文档，不改变已有协议的配置格式。

若上线后出现问题：

1. 停止使用 Snell 创建入口；
2. 删除 Snell 分支和菜单项；
3. 保留已有节点 JSON；
4. 恢复变更前的脚本文件；
5. 运行现有协议的配置校验和启动测试。

已有 VLESS、VMess、Shadowsocks、Trojan 等节点不应因为 Snell 功能回滚而被删除或重建。

## 9. 推荐实现顺序

1. 先实现 Snell v5 的配置生成；
2. 加入 sing-box 版本门禁；
3. 加入 `info` 和配置校验；
4. 加入端口、PSK 修改；
5. 完成真实客户端互通测试；
6. 再评估 v6、多用户和客户端专用链接。
