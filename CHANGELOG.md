# Changelog

All notable changes to **clawhub-daily** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-07-11

### Changed (变更)
- **抓取范围扩大 200→500**：ClawHub 平台已有 67.9K Skills，200 个仅占 0.3%，扩大到 500 翻倍候选池
- **推荐模式从 4 维度扩展到 6 维度**：新增 actively_maintained 和 verified 两个维度
- **维度配额调整**：trending×3 + quality×1 + newcomers×1 + panorama×2 + actively_maintained×1 + verified×0/1 = 每日 8 个
- **actively_maintained 阈值放宽**：主阈值从 30 天→90 天，新增 fallback 180 天+版本≥2
- **verified 标记为 optional**：候选为 0 时自动跳过，不占配额
- **数据说明文案更新**：Markdown 和飞书 blocks 都反映 6 维度新配置
- **SOLO Schedule 提示词更新**：8 个推荐、6 维度、新阈值、痛点去重、changelog 展示

### Added (新增)
- **适配 ClawHub API 数据结构变更**：`stats.installs`（非 `installsCurrent`）、`categories`（非 `capabilityTags`）、`badges.verified`、`latestVersion.changelog` 等嵌套字段
- **降级策略（fallback_fn）**：每个维度配置降级过滤函数，候选不足时自动放宽阈值
- **optional 维度机制**：候选为 0 的维度自动跳过，不占配额
- **痛点匹配去重展示**：同一 Skill 只在第一个命中场景展示（按权重排序）
- **changelog 展示**：有最近变更摘要的 Skill 在详情中展示"最近变更"字段
- **compute_metrics.py 新增 10+ 字段**：version_count、days_since_update、is_actively_maintained、update_frequency、changelog_summary、supported_os、setup_requirements、is_verified、license
- **safe_get() 函数**：安全获取嵌套字段，适配新旧 API 结构

### Fixed (修复)
- **维度遍历遗漏**：generate_markdown() 和 generate_feishu_blocks() 中硬编码的维度列表未包含 actively_maintained 和 verified，导致推荐生成了但不展示（Critical bug）
- **push_to_feishu.py 同类 bug**：飞书卡片 highlights 遍历也遗漏新维度
- **changelog 换行符破坏格式**：API 返回的 changelog 含 \n，嵌入 Markdown 前替换为空格
- **actively_maintained 推荐理由过时**：从"30天内更新"改为"近期更新（N天前）"

## [1.0.4] - 2026-06-05

### Changed (变更)
- **推荐模式从 4 天轮换改为每日全维度**：每天遍历全部 4 个维度，用户每天都能看到所有维度推荐
- 维度配额调整：trending×2 + quality×1 + newcomers×1 + panorama×2 = 每日 6 个
- 去重窗口从 10 天缩短到 7 天（7×6=42 个去重池）
- 飞书卡片消息扩展到 Top 5 简介 + 底部云文档直达链接
- 飞书卡片按维度分组展示，含维度概况统计

### Fixed (修复)
- 云文档/Markdown 中 Skill 链接改为可点击格式（`[text](url)` 和 `text_element_style.link`）
- 飞书云文档 blocks 中 Skill 标题添加超链接，可直接点击跳转

## [1.0.3] - 2026-06-05

### Fixed (修复)
- D4 全景维度 min_comments 从 50 降为 1，避免候选池过小
- deduplicated 字段语义修正：现在正确统计因去重被跳过的候选数
- 痛点关键词匹配改用词边界正则，避免子串误匹配（如 "ci" 匹配到金融 Skill）

## [1.0.0] - 2026-06-03

### Added (新增)

- 🎯 **首次安装模式选择**（`references/setup-wizard.md`）
  - 模式 A：常规对话模式（手动触发）
  - 模式 B：Cron 定时任务模式（自动推送）
- ⏰ **Cron 提示词模板**（`references/prompt-templates.md`）
  - Trae SOLO / qclaw / WorkBuddy / OpenClaw / Hermes / crontab / Windows Task Scheduler 全平台覆盖
  - 5 个开箱即用模板 + 痛点列表定制指南
- 🌍 **7 大痛点库**：🤖 自动化办公 / 🛠️ 开发工具 / ✍️ 内容创作 / 🕷️ 数据采集 / 🧠 AI 增强 / 🇨🇳 中文支持 / 💰 金融分析
- 📊 **4 维度轮换**：trending / quality / newcomers / panorama（按 `日期 % 4` 自动选）
- 🆔 **本地 JSON 去重**：10 天滚动窗口，0 数据库依赖
- 📥 **200 Skill 大池子抓取**：Convex API，0 token 消耗
- 📝 **简报中文化**：`chinese_one_liner` 自动拼装 + 英文 `<details>` 折叠
- 📤 **多通道推送**：
  - 飞书云文档 + 卡片消息（200-400 字摘要 + Top 3 详细解读）
  - IMA 知识库推送（`scripts/push_to_ima.py`，CLI 优先 + HTTP API 备选）
  - 本地 Markdown 简报（默认开启）
- 🔌 **`.claude-plugin/plugin.json`**：ClawHub 发布支持（**MIT-0 许可证**）
- 📜 **MIT-0 License**（`LICENSE`）— ClawHub 强制要求
- 📚 **`docs/CONTRIBUTING.md`** + **`docs/PUBLISHING_GUIDE.md`**：发布/贡献完整指南
- 🔐 **凭证管理**：`references/config.json` 模板（用户自填，不入库，支持飞书 + IMA 双渠道）

### Security (安全)

- 🔒 **移除硬编码凭证**：所有 `app_id` / `app_secret` / `user_open_id` 改为用户配置
- 🔒 **`.gitignore`**：忽略 `references/config.json`、`data/snapshots/*.json` 等运行时数据

### Documentation (文档)

- 📚 完整的 `README.md`（中英双语）
- 📚 `references/api-contract.md`（Convex API 契约）
- 📚 `references/source-data-schema.md`（数据字段说明）
- 📚 `references/pain-points.md`（痛点库维护指南）
- 📚 `references/briefing-template.md`（简报模板）

## [Unreleased]

### Planned

- 飞书 WebSocket 长连接（替代轮询）
- 多语言支持（英文 / 日文简报）
- 智能体推荐理由（基于 Skill 描述自动生成更精准的中文解读）
- Telegram / Slack / 企微 推送支持
- Skill 评分系统（基于用户安装/卸载行为）

---

## 版本号规则

- **MAJOR**：不兼容的 API 变更
- **MINOR**：向下兼容的新功能
- **PATCH**：向下兼容的 bug 修复

## 链接

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
