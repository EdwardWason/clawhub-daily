#!/usr/bin/env python3
"""
每日推荐生成脚本
- 4 维度轮换（D1 趋势 / D2 质量 / D3 新星 / D4 全景）
- 10 天去重（10 天全覆盖扫描周期）
- 痛点匹配加权
- 中文一句话解读（基于 capability_tags + 痛点场景拼装，0 token 消耗）
- 生成飞书云文档 blocks + 简报 Markdown
"""
import json
import argparse
import sys
import time
from pathlib import Path
from datetime import datetime, timedelta


# 7 大痛点库（与 pain-points.md 保持同步）
PAIN_POINTS_DB = {
    "🤖 自动化办公": {
        "keywords": [
            "gmail", "calendar", "slack", "trello", "notion", "sheets", "drive",
            "docs", "gog", "himalaya", "office", "workspace", "meeting", "mail"
        ],
        "weight": 1.5,
        "next_action_template": "试试用 {skill} 接管你的 {场景} 工作流",
    },
    "🛠️ 开发工具": {
        "keywords": [
            "github", "mcp", "browser", "code", "git", "test", "ci", "debug",
            "lint", "api", "rest", "graphql", "docker", "build", "deploy",
            "coding", "repo", "pull-request"
        ],
        "weight": 1.5,
        "next_action_template": "在 IDE 中安装 {skill} 并配置 MCP server",
    },
    "✍️ 内容创作": {
        "keywords": [
            "youtube", "humanizer", "video", "image", "pdf", "writing", "blog",
            "medium", "substack", "twitter", "social", "content", "creator",
            "editor", "transcript", "frame"
        ],
        "weight": 1.2,
        "next_action_template": "用 {skill} 改写你最近一篇内容",
    },
    "🕷️ 数据采集": {
        "keywords": [
            "search", "scraping", "apify", "firecrawl", "polymarket", "google",
            "bing", "duckduckgo", "brave", "tavily", "serp", "crawler", "scraper",
            "data", "extract", "monitor"
        ],
        "weight": 1.2,
        "next_action_template": "用 {skill} 监控你的数据源",
    },
    "🧠 AI 增强": {
        "keywords": [
            "self-improving", "proactive", "memory", "agent", "reasoning",
            "reflection", "learning", "autonomous", "schedule", "plan",
            "improve", "optimize", "hal", "wal"
        ],
        "weight": 1.3,
        "next_action_template": "把 {skill} 加入你的 Skill 库",
    },
    "🇨🇳 中文支持": {
        "keywords": [
            "chinese", "baidu", "wechat", "taobao", "bilibili", "qq", "weibo",
            "douyin", "jd", "tencent", "中文", "百度", "微信", "淘宝", "B站"
        ],
        "weight": 1.0,
        "next_action_template": "用 {skill} 处理你的中文内容",
    },
    "💰 金融分析": {
        "keywords": [
            "polymarket", "financial", "stock", "trading", "invest", "market",
            "price", "prediction", "alpha", "fund", "portfolio", "backtest",
            "earnings"
        ],
        "weight": 0.8,
        "next_action_template": "用 {skill} 跟踪市场动态",
    },
}

# 维度配置
DIMENSION_CONFIG = {
    "trending": {
        "name": "趋势",
        "module": "🔥 今日热装",
        "primary_field": "installs_current",
        "filter_fn": lambda s: s['installs_current'] >= 100,
        "sort_field": "installs_current",
        "sort_desc": True,
        "limit": 8,
    },
    "quality": {
        "name": "质量",
        "module": "⭐ 口碑精品",
        "primary_field": "star_rate",
        "filter_fn": lambda s: s['downloads'] >= 1000 and s['star_rate'] >= 0.5,
        "sort_field": "star_rate",
        "sort_desc": True,
        "limit": 8,
    },
    "newcomers": {
        "name": "新星",
        "module": "🚀 新星崛起",
        "primary_field": "age_days",
        "filter_fn": lambda s: s['age_days'] <= 60 and s['installs_current'] >= 10 and s['stars'] >= 3,
        "sort_field": "installs_current",
        "sort_desc": True,
        "limit": 8,
    },
    "panorama": {
        "name": "全景",
        "module": "🏆 分类王者",
        "primary_field": "comments",
        "filter_fn": lambda s: s['comments'] >= 50,
        "sort_field": "comments",
        "sort_desc": True,
        "limit": 8,
    },
}


def match_pain_points(skill):
    """返回该 Skill 命中的痛点场景"""
    text_parts = [
        skill.get('display_name', ''),
        skill.get('summary', ''),
        ' '.join(skill.get('capability_tags', []))
    ]
    text = ' '.join(text_parts).lower()

    matched = []
    for scene, config in PAIN_POINTS_DB.items():
        for kw in config['keywords']:
            if kw.lower() in text:
                matched.append(scene)
                break
    return matched


def pain_point_score(skill):
    """根据痛点命中计算加权分"""
    matched = match_pain_points(skill)
    score = 0
    for scene in matched:
        score += PAIN_POINTS_DB[scene]['weight']
    return score, matched


def get_dimension_by_date(date_str):
    """根据日期自动决定维度（4 天一个周期）"""
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    epoch_day = (dt - datetime(2026, 1, 1)).days
    dims = ["trending", "quality", "newcomers", "panorama"]
    return dims[epoch_day % 4]


def load_recent_recommended(data_dir, lookback_days=10):
    """加载过去 N 天已推荐的 Skill URL 集合"""
    recommended_urls = set()
    today = datetime.now().date()

    for i in range(1, lookback_days + 1):
        day = today - timedelta(days=i)
        path = Path(data_dir) / "recommended" / f"{day.isoformat()}.json"
        if path.exists():
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                for rec in data.get('recommendations', []):
                    recommended_urls.add(rec.get('url'))
            except Exception as e:
                print(f"  [Warn] 读取 {path} 失败: {e}")
    return recommended_urls


def recommend_skills(skills, dimension, lookback_urls, target_count=10):
    """根据维度筛选 + 去重 + 痛点加权"""
    config = DIMENSION_CONFIG[dimension]
    filter_fn = config['filter_fn']
    sort_field = config['sort_field']

    # 1. 过滤
    candidates = [s for s in skills if filter_fn(s) and not s['is_suspicious']]

    # 2. 排序
    candidates.sort(key=lambda x: x[sort_field], reverse=config['sort_desc'])

    # 3. 痛点加权 + 去重
    recommended = []
    seen_urls = set()
    for skill in candidates:
        if skill['url'] in lookback_urls:
            continue
        if skill['url'] in seen_urls:
            continue
        if len(recommended) >= target_count:
            break

        pp_score, matched = pain_point_score(skill)
        skill_copy = dict(skill)
        skill_copy['pain_points_matched'] = matched
        skill_copy['pain_point_score'] = pp_score
        skill_copy['module'] = config['module']
        skill_copy['recommend_reason'] = generate_recommend_reason(skill_copy, dimension, matched)
        skill_copy['next_action'] = generate_next_action(skill_copy, matched)
        skill_copy['chinese_one_liner'] = generate_chinese_one_liner(skill_copy, matched)
        recommended.append(skill_copy)
        seen_urls.add(skill['url'])

    return recommended


def generate_recommend_reason(skill, dimension, matched):
    """生成中文推荐理由"""
    if dimension == "trending":
        return f"今日活跃安装 {skill['installs_current']} 次，累计 {skill['installs_all_time']} 次"
    elif dimension == "quality":
        return f"口碑率 {skill['star_rate']}%，高于平均（0.81%）"
    elif dimension == "newcomers":
        return f"仅 {skill['age_days']} 天，已 {skill['installs_current']} 活跃安装"
    elif dimension == "panorama":
        return f"社区热议 {skill['comments']} 条"
    return ""


def generate_next_action(skill, matched):
    """生成下一步行动建议"""
    if matched:
        scene = matched[0]
        template = PAIN_POINTS_DB[scene]['next_action_template']
        # 去掉 emoji，取场景中文名（如 "🤖 自动化办公" → "自动化办公"）
        scene_name = scene.split(' ', 1)[-1] if ' ' in scene else scene
        return (template
                .replace("{skill}", skill['display_name'])
                .replace("{场景}", scene_name))
    return f"访问 {skill['url']} 了解详情"


def generate_chinese_one_liner(skill, matched):
    """基于 capability_tags + 痛点场景自动拼装中文一句话
    0 token 消耗，不调大模型
    """
    tags = skill.get('capability_tags', []) or []
    # 兜底：没有 tags 就用 display_name 拆词
    if not tags and skill.get('summary'):
        # 从 summary 简单抽取前 4 个英文单词作"功能"提示
        words = [w for w in skill['summary'].replace(',', ' ').split() if len(w) > 3][:4]
        tags = words or ['工具']

    top_tags = tags[:3]

    if matched:
        scene = matched[0]
        # 去掉 emoji，取场景中文
        scene_name = scene.split(' ', 1)[-1] if ' ' in scene else scene
        return f"面向「{scene_name}」场景，整合 {('、'.join(top_tags))} 等能力"
    return f"集成 {('、'.join(top_tags))} 等能力，可作为通用工具使用"


def generate_markdown(date_str, dimension, recommended, total_scanned, deduplicated):
    """生成简报 Markdown"""
    config = DIMENSION_CONFIG[dimension]
    dim_name = config['name']

    md = f"""# 🦞 ClawHub 每日洞察 | {date_str}（{dim_name}维度）

> 📊 数据日期：{date_str} | 🎯 推荐维度：{dim_name} | 📦 扫描数量：{total_scanned} | 🆕 新增推荐：{len(recommended)} | 🚫 已去重：{deduplicated}

## 🎯 TL;DR

今天推荐 **{len(recommended)}** 个 Skill"""

    if recommended:
        pain_scenes = set()
        for r in recommended:
            pain_scenes.update(r.get('pain_points_matched', []))
        if pain_scenes:
            md += f"，其中 **{len(pain_scenes)}** 个场景匹配你的关注：{', '.join(sorted(pain_scenes))}"

    md += "\n\n---\n\n"

    # 主要推荐模块
    md += f"## {config['module']}\n\n"
    for i, r in enumerate(recommended, 1):
        md += f"### {i}. {r['display_name']}\n\n"
        md += f"- **作者**: {r['author_display']} (`{r['author_handle']}`)\n"
        md += f"- **链接**: {r['url']}\n"
        md += f"- **数据**: ⭐ {r['stars']} | 📥 {r['downloads']} | "
        md += f"📊 活跃 {r['installs_current']} | 💬 {r['comments']}\n"
        md += f"- **指标**: 口碑率 {r['star_rate']}% | 活跃度 {r['activity_rate']}%\n"
        # 中文一句话解读（默认显示）
        if r.get('chinese_one_liner'):
            md += f"- **能力解读**: {r['chinese_one_liner']}\n"
        if r.get('pain_points_matched'):
            md += f"- **匹配场景**: {', '.join(r['pain_points_matched'])}\n"
        md += f"- **推荐理由**: {r['recommend_reason']}\n"
        md += f"- **下一步**: {r['next_action']}\n"
        # 英文原文摘要作为参考（折叠显示）
        if r.get('summary'):
            summary = r['summary'][:200] + ('...' if len(r['summary']) > 200 else '')
            md += f"- <details><summary>📄 原文摘要（English）</summary>{summary}</details>\n"
        md += "\n"

    # 痛点分组
    md += "\n## 🎯 痛点匹配（按场景分组）\n\n"
    by_scene = {}
    for r in recommended:
        for scene in r.get('pain_points_matched', []):
            by_scene.setdefault(scene, []).append(r)

    if by_scene:
        for scene in sorted(by_scene.keys(), key=lambda s: PAIN_POINTS_DB[s]['weight'], reverse=True):
            md += f"### {scene}\n"
            for r in by_scene[scene][:3]:
                md += f"- **{r['display_name']}** - {r.get('chinese_one_liner', r.get('summary', '')[:80])}\n"
            md += "\n"
    else:
        md += "今日推荐未命中预设痛点场景。\n\n"

    # 数据说明
    md += """---

## 📌 数据说明

- **数据源**: ClawHub Convex API
- **扫描数量**: {total} 个 Skill
- **时间窗口**: 10 天去重（10 天全覆盖扫描周期）
- **筛选规则**:
  - 趋势维度: installsCurrent > 100
  - 质量维度: downloads > 1000 且 star_rate > 0.5%
  - 新星维度: age_days <= 60 且 installsCurrent > 10 且 stars > 3
  - 全景维度: comments > 50

## 🦞 反馈

觉得推荐不准？编辑 `references/pain-points.md` 调整你的痛点优先级。
""".format(total=total_scanned)

    return md


def generate_feishu_blocks(date_str, dimension, recommended, total_scanned, deduplicated):
    """生成飞书云文档 blocks（用于 create document）"""
    config = DIMENSION_CONFIG[dimension]
    dim_name = config['name']
    blocks = []

    # 标题
    blocks.append({"block_type": 3, "heading1": {
        "elements": [{"text_run": {"content": f"🦞 ClawHub 每日洞察 | {date_str}（{dim_name}维度）"}}],
        "style": {}
    }})
    # 元信息
    blocks.append({"block_type": 2, "text": {
        "elements": [{"text_run": {"content": f"数据日期：{date_str} | 推荐维度：{dim_name} | 扫描：{total_scanned} | 新增：{len(recommended)} | 去重：{deduplicated}"}}],
        "style": {}
    }})
    # TL;DR
    blocks.append({"block_type": 3, "heading1": {
        "elements": [{"text_run": {"content": "🎯 TL;DR"}}], "style": {}
    }})
    pain_scenes = set()
    for r in recommended:
        pain_scenes.update(r.get('pain_points_matched', []))
    tldr = f"今天推荐 {len(recommended)} 个 Skill"
    if pain_scenes:
        tldr += f"，匹配场景：{', '.join(sorted(pain_scenes))}"
    blocks.append({"block_type": 2, "text": {
        "elements": [{"text_run": {"content": tldr}}], "style": {}
    }})
    # 分隔线
    blocks.append({"block_type": 22, "divider": {}})

    # 主要模块
    blocks.append({"block_type": 3, "heading1": {
        "elements": [{"text_run": {"content": config['module']}}], "style": {}
    }})
    for i, r in enumerate(recommended, 1):
        blocks.append({"block_type": 4, "heading2": {
            "elements": [{"text_run": {"content": f"{i}. {r['display_name']}"}}],
            "style": {}
        }})
        for line in [
            f"作者: {r['author_display']} (`{r['author_handle']}`)",
            f"链接: {r['url']}",
            f"数据: ⭐ {r['stars']} | 📥 {r['downloads']} | 📊 活跃 {r['installs_current']} | 💬 {r['comments']}",
            f"指标: 口碑率 {r['star_rate']}% | 活跃度 {r['activity_rate']}%",
        ]:
            blocks.append({"block_type": 2, "text": {
                "elements": [{"text_run": {"content": line}}], "style": {}
            }})
        # 中文一句话解读（默认显示）
        if r.get('chinese_one_liner'):
            blocks.append({"block_type": 2, "text": {
                "elements": [{"text_run": {"content": f"能力解读: {r['chinese_one_liner']}"}}], "style": {}
            }})
        if r.get('pain_points_matched'):
            blocks.append({"block_type": 2, "text": {
                "elements": [{"text_run": {"content": f"匹配场景: {', '.join(r['pain_points_matched'])}"}}],
                "style": {}
            }})
        blocks.append({"block_type": 2, "text": {
            "elements": [{"text_run": {"content": f"推荐理由: {r['recommend_reason']}"}}],
            "style": {}
        }})
        blocks.append({"block_type": 2, "text": {
            "elements": [{"text_run": {"content": f"下一步: {r['next_action']}"}}],
            "style": {}
        }})
        # 英文原文摘要作为参考
        if r.get('summary'):
            summary = r['summary'][:200] + ('...' if len(r['summary']) > 200 else '')
            blocks.append({"block_type": 2, "text": {
                "elements": [{"text_run": {"content": f"📄 原文摘要（English）: {summary}"}}], "style": {}
            }})

    # 痛点分组
    blocks.append({"block_type": 22, "divider": {}})
    blocks.append({"block_type": 3, "heading1": {
        "elements": [{"text_run": {"content": "🎯 痛点匹配（按场景分组）"}}], "style": {}
    }})
    by_scene = {}
    for r in recommended:
        for scene in r.get('pain_points_matched', []):
            by_scene.setdefault(scene, []).append(r)
    for scene in sorted(by_scene.keys(), key=lambda s: PAIN_POINTS_DB[s]['weight'], reverse=True):
        blocks.append({"block_type": 4, "heading2": {
            "elements": [{"text_run": {"content": scene}}], "style": {}
        }})
        for r in by_scene[scene][:3]:
            desc = r.get('chinese_one_liner') or (r.get('summary', '')[:80] + '...')
            blocks.append({"block_type": 2, "text": {
                "elements": [{"text_run": {"content": f"• {r['display_name']} - {desc}"}}],
                "style": {}
            }})

    # 页脚
    blocks.append({"block_type": 22, "divider": {}})
    blocks.append({"block_type": 3, "heading1": {
        "elements": [{"text_run": {"content": "📌 数据说明"}}], "style": {}
    }})
    for line in [
        f"• 数据源: ClawHub Convex API",
        f"• 扫描数量: {total_scanned} 个 Skill",
        f"• 时间窗口: 10 天去重（10 天全覆盖扫描周期）",
        f"• 数据日期: {date_str}",
    ]:
        blocks.append({"block_type": 2, "text": {
            "elements": [{"text_run": {"content": line}}], "style": {}
        }})

    return blocks


def main():
    parser = argparse.ArgumentParser(description="生成每日推荐")
    parser.add_argument("--date", required=True, help="快照日期 YYYY-MM-DD")
    parser.add_argument("--dimension", default=None, help="推荐维度（默认按日期自动）")
    parser.add_argument("--data-dir", default="data", help="数据根目录")
    parser.add_argument("--lookback-days", type=int, default=10, help="去重窗口（默认 10，配合 10 天全覆盖周期）")
    parser.add_argument("--target", type=int, default=10, help="推荐数量（默认 10）")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    metrics_path = data_dir / "snapshots" / f"{args.date}.metrics.json"
    if not metrics_path.exists():
        print(f"[Error] metrics 文件不存在: {metrics_path}")
        print(f"请先运行: python scripts/fetch_clawhub.py --date {args.date}")
        print(f"          python scripts/compute_metrics.py --input {metrics_path.parent / (args.date + '.json')}")
        return 1

    # 加载当日数据
    with open(metrics_path, "r", encoding="utf-8") as f:
        metrics = json.load(f)
    skills = metrics.get('skills', [])
    total_scanned = len(skills)
    print(f"[Recommend] 加载 {total_scanned} 个 Skill")

    # 决定维度
    dimension = args.dimension or get_dimension_by_date(args.date)
    print(f"[Recommend] 维度: {dimension}")

    # 加载历史去重
    lookback_urls = load_recent_recommended(data_dir, args.lookback_days)
    print(f"[Recommend] {args.lookback_days} 天内已推荐: {len(lookback_urls)} 个")

    # 生成推荐
    recommended = recommend_skills(skills, dimension, lookback_urls, args.target)
    deduplicated = total_scanned - len(recommended) - sum(1 for s in skills if not DIMENSION_CONFIG[dimension]['filter_fn'](s))
    print(f"[Recommend] 推荐 {len(recommended)} 个")

    # 生成 Markdown 简报
    md = generate_markdown(args.date, dimension, recommended, total_scanned, deduplicated)
    md_path = data_dir / "recommended" / f"{args.date}.md"
    md_path.parent.mkdir(parents=True, exist_ok=True)
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md)
    print(f"[Recommend] Markdown 已保存: {md_path}")

    # 生成飞书 blocks
    blocks = generate_feishu_blocks(args.date, dimension, recommended, total_scanned, deduplicated)
    print(f"[Recommend] 飞书 blocks: {len(blocks)} 个")

    # 保存推荐结果 JSON（包含 blocks 供 push_to_feishu 使用）
    output = {
        "date": args.date,
        "dimension": dimension,
        "total_scanned": total_scanned,
        "recommendations": recommended,
        "deduplicated": deduplicated,
        "markdown_path": str(md_path),
        "feishu_blocks": blocks,
        "feishu_blocks_count": len(blocks),
    }
    output_path = data_dir / "recommended" / f"{args.date}.json"
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"[Recommend] 推荐结果已保存: {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
