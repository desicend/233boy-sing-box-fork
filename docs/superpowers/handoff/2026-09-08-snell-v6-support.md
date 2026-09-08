# Handoff: Sing-box Snell v6 支持需求

本交接文档用于在当前会话中断后，供下一个智能体快速无缝接手后续工作。

## 1. 目标与背景

- **功能需求**：为 `one-singbox` 引入 Snell v6 协议支持，默认创建 v6 节点，完全向下兼容 v5。包含 v6 模式（`default`/`unshaped`/`unsafe-raw`）、PSK 长度（12~255 字符）严格校验、CLI `mode` 命令与智能路由、版本平滑迁移、Surge/sing-box URI 自适应导出及帮助文档更新。
- **设计规范**：[docs/superpowers/specs/2026-09-08-snell-v6-support-design.md](file:///d:/233boy-sing-box-fork/one-singbox/docs/superpowers/specs/2026-09-08-snell-v6-support-design.md)
- **实施计划**：[docs/superpowers/plans/2026-09-08-snell-v6-support.md](file:///d:/233boy-sing-box-fork/one-singbox/docs/superpowers/plans/2026-09-08-snell-v6-support.md)
- **SDD 执行记录 (Ledger)**：[d:/233boy-sing-box-fork/one-singbox/.superpowers/sdd/2026-09-08-snell-v6-support/progress.md](file:///d:/233boy-sing-box-fork/one-singbox/.superpowers/sdd/2026-09-08-snell-v6-support/progress.md)

---

## 2. 当前进度与交付物状态

所有计划内的任务已 100% 实施并通过任务级独立 Review（Spec Compliance ✅, Code Quality Approved）：

1. **Task 1** (`85e65c1`): Snell v6 入站校验与配置生成。实现 `snell_version_valid`（支持 5/6）、`snell_mode_valid`、`validate_snell`（v6 强制 PSK 12~255 位与 mode 校验）、`create server Snell`（v6 生成纯净 mode，v5 生成纯净 obfs_mode）。
2. **Task 2** (`bcb6c7c`): 状态读取与导出格式。`get info` 提取 `snell_mode`，`info()` 适配终端展示，Surge 与 sing-box URI 自适应导出（default 模式省略 mode 参数，非 default 模式携带 `mode=`，维持不支持二维码）。
3. **Task 3** (`9f58968`): CLI 交互与版本迁移。新增 `mode` 命令分支，`mode` 与 `obfs` 智能互通路由，`snell-version` 5 与 6 双向平滑迁移（自动清理互斥字段，v5 升 v6 时短 PSK 自动刷新为合规密钥）。
4. **Task 4** (`5465bad`): 帮助与文档。更新 `src/help.sh` 与 `README.md`，增加 `tests-snell-support.sh` 文档断言。
5. **文档归档** (`5a3db21`): 提交实施计划 `docs/superpowers/plans/2026-09-08-snell-v6-support.md`。

**当前分支与工作区状态**：
- 工作区当前处于分支 `main`，`git status` 完全干净。
- 测试套件验证通过：
  ```bash
  wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-snell-support.sh"  # PASS
  wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-relay-support.sh"  # PASS
  wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && ./tests-node-name-label.sh" # PASS
  wsl -u root bash -c "cd /mnt/d/233boy-sing-box-fork/one-singbox && bash -n src/core.sh && bash -n core.sh && bash -n src/help.sh" # PASS
  ```

---

## 3. 中断与交接点检查项 (Handoff Checkpoint)

- **停止原因**：用户因关机下线调用 `/handoff`。
- **Code Reviewer 状态**：已终止（Kill）正在执行中的全分支审查子代理（Conversation ID: `d3493fea-7c18-46ad-841e-c802f579ec76`）。
- **审查包就绪**：预生成的全量 diff 审查包位于：
  `d:/233boy-sing-box-fork/one-singbox/.superpowers/sdd/2026-09-08-snell-v6-support/final-review-package.txt`
  （覆盖范围：`082c3f9..5465bad`）。

---

## 4. 下一个会话的执行指引 (Next Steps)

下一个智能体启动后，无需重复执行编码或任务级单元测试，直接执行以下收尾流程：

1. **重新发起全分支代码审查 (Final Whole-Branch Review)**：
   - 审查范围：`082c3f9..5465bad`（或读取已有文件 `.superpowers/sdd/2026-09-08-snell-v6-support/final-review-package.txt`）。
   - 审查要求：检查 plan 对齐情况、代码质量、架构规范、测试完整性以及 `src/core.sh` 与 `core.sh` 的双文件对称性。
2. **处理审查反馈**：
   - 若审查通过（Approved）：将 Review Clean 记录追加至 ledger。
   - 若有必须修复的缺陷（Critical/Important）：单次派发 subagent 集中修复并重新复核。
3. **完成开发收尾**：
   - 删除临时目录 `.superpowers/sdd/2026-09-08-snell-v6-support/`。
   - 运行交付技能完成后续集成与发布操作。

---

## 5. 建议技能 (Suggested Skills)

下一个智能体接手时，建议按顺序调用以下技能：

1. `subagent-driven-development`：指导完成全分支审查与 SDD 生命周期收尾。
2. `requesting-code-review`：获取并使用全分支审查的标准提示模板（`code-reviewer.md`）。
3. `finishing-a-development-branch`：审查完成后引导用户进行分支归档、推送或合并。
