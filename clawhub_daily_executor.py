#!/usr/bin/env python3
"""
ClawHub Daily 定时任务执行器
SOLO Schedule 调用的主脚本
流程：抓取 → 计算指标 → 生成推荐 → 推送飞书

脚本指向 clawhub-daily/scripts/ 下的发布版脚本（无硬编码凭证）
"""
import sys
import subprocess
import argparse
from pathlib import Path
from datetime import datetime


PROJECT_DIR = Path(__file__).resolve().parent
SKILL_DIR = PROJECT_DIR / "clawhub-daily"
SCRIPTS = SKILL_DIR / "scripts"
DATA_DIR = PROJECT_DIR / "data"


def run(cmd, label):
    """执行命令"""
    print(f"\n{'='*60}")
    print(f"[Step] {label}")
    print(f"[Cmd]  {' '.join(cmd)}")
    print('='*60)
    result = subprocess.run(cmd, capture_output=False)
    if result.returncode != 0:
        print(f"[FAIL] {label} 失败 (exit={result.returncode})")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="ClawHub Daily 主执行器")
    parser.add_argument("--date", default=None, help="数据日期（默认今天）")
    parser.add_argument("--num", type=int, default=500, help="抓取数量")
    parser.add_argument("--skip-push", action="store_true", help="跳过飞书推送")
    args = parser.parse_args()

    date = args.date or datetime.now().strftime("%Y-%m-%d")
    print(f"🦞 ClawHub Daily | {date}")

    # Verify scripts directory exists
    if not SCRIPTS.exists():
        print(f"[ERROR] Scripts directory not found: {SCRIPTS}")
        print(f"  Expected clawhub-daily/scripts/ under {PROJECT_DIR}")
        return 1

    # Step 1: 抓取
    if not run([
        sys.executable, str(SCRIPTS / "fetch_clawhub.py"),
        "--num", str(args.num),
        "--date", date,
        "--output", str(DATA_DIR / "snapshots")
    ], "抓取 ClawHub 数据"):
        return 1

    # Step 2: 指标计算
    snapshot_path = DATA_DIR / "snapshots" / f"{date}.json"
    if not run([
        sys.executable, str(SCRIPTS / "compute_metrics.py"),
        "--input", str(snapshot_path)
    ], "计算指标"):
        return 1

    # Step 3: 生成推荐
    if not run([
        sys.executable, str(SCRIPTS / "daily_recommend.py"),
        "--date", date,
        "--data-dir", str(DATA_DIR)
    ], "生成推荐"):
        return 1

    # === 推送阶段（三处存放，各自独立 try/except 失败隔离，参考 web-to-fim 架构）===
    if not args.skip_push:
        rec_path = DATA_DIR / "recommended" / f"{date}.json"
        # Prefer config.local.json (local credentials, not published) over config.json (template)
        config_path = SKILL_DIR / "references" / "config.local.json"
        if not config_path.exists():
            config_path = SKILL_DIR / "references" / "config.json"

        push_results = {"feishu": None, "ima": None, "obsidian": None}

        # Step 4: 推送飞书云文档
        try:
            push_results["feishu"] = run([
                sys.executable, str(SCRIPTS / "push_to_feishu.py"),
                "--recommendation", str(rec_path),
                "--config", str(config_path)
            ], "推送飞书")
            if not push_results["feishu"]:
                print("[Warn] 飞书推送失败，继续尝试其他渠道")
        except Exception as e:
            print(f"[Warn] 飞书推送异常: {e}")

        # Step 5: 推送 IMA FIM 知识库
        try:
            push_results["ima"] = run([
                sys.executable, str(SCRIPTS / "push_to_ima.py"),
                "--recommendation", str(rec_path),
                "--config", str(config_path),
                "--mode", "official"
            ], "推送 IMA FIM 知识库")
            if not push_results["ima"]:
                print("[Warn] IMA 推送失败，继续尝试其他渠道")
        except Exception as e:
            print(f"[Warn] IMA 推送异常: {e}")

        # Step 6: 推送 Obsidian 本地 vault
        try:
            push_results["obsidian"] = run([
                sys.executable, str(SCRIPTS / "push_to_obsidian.py"),
                "--recommendation", str(rec_path)
            ], "推送 Obsidian 本地 vault")
            if not push_results["obsidian"]:
                print("[Warn] Obsidian 推送失败，继续尝试其他渠道")
        except Exception as e:
            print(f"[Warn] Obsidian 推送异常: {e}")

        # 推送汇总
        print(f"\n{'='*60}")
        print(f"[推送汇总] 飞书={'✓' if push_results['feishu'] else '✗'} | IMA={'✓' if push_results['ima'] else '✗'} | Obsidian={'✓' if push_results['obsidian'] else '✗'}")
        print('='*60)

    print(f"\n✅ ClawHub Daily | {date} | 全部完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
