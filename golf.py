#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sqlite3
import requests
import json
import os
import sys
from datetime import date, timedelta, datetime
import argparse

# ==================== 配置区 ====================
DB_PATH = "/home/ubuntu/xxh/hitdata/data/golf_stats.db"
WECOM_WEBHOOK = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=bc732891-62fa-49e8-a23c-86fe2958c381"

# 是否启用企业微信通知 (True=启用, False=禁用)
ENABLE_WECOM_NOTIFY = True

# ==================== 辅助函数 ====================

def send_wecom_markdown_v2(content: str):
    """
    发送企业微信 Markdown V2 消息
    """
    if not ENABLE_WECOM_NOTIFY:
        print("企业微信通知已禁用")
        return

    payload = {
        "msgtype": "markdown_v2",
        "markdown_v2": {
            "content": content
        }
    }

    try:
        response = requests.post(WECOM_WEBHOOK, json=payload, timeout=10)
        response.raise_for_status()  # 如果状态码不是 2xx，则抛出异常
        
        # 企业微信的API响应通常包含errcode字段
        response_json = response.json()
        if response_json.get("errcode") == 0:
            print("企业微信消息发送成功")
        else:
            print(f"企业微信消息发送失败, 响应: {response.text}")

    except requests.exceptions.RequestException as e:
        print(f"警告: 发送企业微信消息时发生网络错误: {e}")
    except json.JSONDecodeError:
        print(f"警告: 解析企业微信响应失败, 响应内容: {response.text}")


def get_db_connection():
    """检查数据库文件并返回连接对象"""
    if not os.path.exists(DB_PATH):
        print(f"错误: 数据库文件不存在: {DB_PATH}")
        send_wecom_markdown_v2("❌ **数据库错误**\n> 数据库文件不存在，请检查路径配置。")
        sys.exit(1)
    
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row # 让查询结果可以通过列名访问
        return conn
    except sqlite3.Error as e:
        print(f"错误: 无法连接到数据库: {e}")
        send_wecom_markdown_v2(f"❌ **数据库错误**\n> 无法连接到数据库: {e}")
        sys.exit(1)


def get_display_name(device_name, device_id):
    """获取设备显示名称，如果名称为空则使用部分ID"""
    if not device_name or device_name == "null":
        return f"{device_id[:8]}..."
    return device_name

# ==================== 报告生成函数 ====================

def generate_daily_report(report_date_str: str):
    """生成每日报告"""
    print("==========================================")
    print(f"生成每日高尔夫击球数统计报告")
    print(f"日期: {report_date_str}")
    print("==========================================")

    conn = get_db_connection()
    query = """
    SELECT 
        d.device_name,
        ds.device_id,
        ds.hit_count,
        ds.firmware_version,
        ds.created_at
    FROM daily_stats ds
    LEFT JOIN devices d ON ds.device_id = d.device_id
    WHERE ds.date = ?
    ORDER BY ds.hit_count DESC;
    """
    
    try:
        cursor = conn.cursor()
        results = cursor.execute(query, (report_date_str,)).fetchall()
    finally:
        conn.close()

    now_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    if not results:
        print("当日无击球数据")
        message = (
            f"## 📊 高尔夫击球数日报\n"
            f"**日期:** {report_date_str}\n"
            f"**状态:** 当日无设备活动记录\n\n"
            f"---\n"
            f"⏰ 报告时间: {now_time}"
        )
        send_wecom_markdown_v2(message)
        return

    total_devices = len(results)
    total_hits = sum(row['hit_count'] for row in results)
    top_device = results[0]

    # 构建报告内容
    report = [
        f"## 📊 高尔夫击球数日报",
        f"**日期:** `{report_date_str}`\n",
        f"### 📈 数据汇总",
        f"- **活跃设备数:** {total_devices} 台",
        f"- **总击球数:** {total_hits} 次",
        # f"- **平均击球数:** {avg_hits} 次/台", # <-- 此行已移除
        f"- **最活跃设备:** {get_display_name(top_device['device_name'], top_device['device_id'])} ({top_device['hit_count']}次)\n",
        f"### 🎯 设备详情 (Top {min(10, total_devices)})"
    ]

    # 构建设备详情表格
    table = [
        "| 排名 | 设备名称 | 击球数 | 固件版本 |",
        "|:----:|:--------|:------:|:----------|"
    ]
    for i, row in enumerate(results[:10]):
        rank = i + 1
        display_name = get_display_name(row['device_name'], row['device_id'])
        fw_version = row['firmware_version'] if row['firmware_version'] else "unknown"
        table.append(f"| {rank} | {display_name} | **{row['hit_count']}** | `{fw_version}` |")

    report.extend(table)
    if total_devices > 10:
        report.append(f"\n> ... 还有 {total_devices - 10} 台设备未显示")

    report.append(f"\n---\n⏰ 报告生成时间: {now_time}")
    
    final_report = "\n".join(report)
    print(final_report)
    send_wecom_markdown_v2(final_report)


def generate_period_report(start_date_str: str, end_date_str: str, period_name: str, days: int):
    """
    生成周期性报告 (周报/月报)
    - period_name: "周" 或 "月"
    - days: 7 (周报) 或 30 (月报)
    """
    print("==========================================")
    print(f"生成高尔夫击球数{period_name}报")
    print(f"周期: {start_date_str} 至 {end_date_str}")
    print("==========================================")

    conn = get_db_connection()
    query = """
    SELECT 
        d.device_name,
        ds.device_id,
        SUM(ds.hit_count) as total_hits,
        COUNT(DISTINCT ds.date) as active_days,
        MAX(ds.hit_count) as max_daily_hits,
        ROUND(AVG(ds.hit_count), 0) as avg_daily_hits
    FROM daily_stats ds
    LEFT JOIN devices d ON ds.device_id = d.device_id
    WHERE ds.date BETWEEN ? AND ?
    GROUP BY ds.device_id
    ORDER BY total_hits DESC;
    """
    
    try:
        cursor = conn.cursor()
        results = cursor.execute(query, (start_date_str, end_date_str)).fetchall()
    finally:
        conn.close()

    now_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    if not results:
        print(f"本{period_name}无击球数据")
        message = (
            f"## 📊 高尔夫击球数{period_name}报\n"
            f"**周期:** `{start_date_str} ~ {end_date_str}`\n"
            f"**状态:** 本{period_name}无设备活动记录\n\n"
            f"---\n"
            f"⏰ 报告时间: {now_time}"
        )
        send_wecom_markdown_v2(message)
        return

    total_devices = len(results)
    total_hits = sum(row['total_hits'] for row in results)
    avg_daily_total = total_hits // days if days > 0 else 0

    report = [
        f"## 📊 高尔夫击球数{period_name}报",
        f"**周期:** `{start_date_str} ~ {end_date_str}` ({days}天)\n",
        f"### 📈 {period_name}度汇总",
        f"- **活跃设备数:** {total_devices} 台",
        f"- **{period_name}总击球数:** {total_hits} 次",
        f"- **日均总击球:** {avg_daily_total} 次\n",
        f"### 🏆 设备排行 (Top {min(10, total_devices)})"
    ]
    
    table = [
        f"| 排名 | 设备名称 | {period_name}总击球 | 活跃天数 | 日均击球 | 单日最高 |",
        "|:----:|:--------|:----------:|:----------:|:----------:|:----------:|"
    ]

    for i, row in enumerate(results[:10]):
        rank = i + 1
        display_name = get_display_name(row['device_name'], row['device_id'])
        avg_daily_device = int(row['avg_daily_hits'])
        table.append(f"| {rank} | {display_name} | **{row['total_hits']}** | {row['active_days']} | {avg_daily_device} | {row['max_daily_hits']} |")

    report.extend(table)
    if total_devices > 10:
        report.append(f"\n> ... 还有 {total_devices - 10} 台设备未显示")
        
    report.append(f"\n---\n⏰ 报告生成时间: {now_time}")

    final_report = "\n".join(report)
    print(final_report)
    send_wecom_markdown_v2(final_report)

# ==================== 主程序入口 ====================

def main():
    parser = argparse.ArgumentParser(
        description="生成高尔夫击球数据报告并发送到企业微信",
        formatter_class=argparse.RawTextHelpFormatter
    )
    
    # 使用子命令来区分不同的报告类型
    subparsers = parser.add_subparsers(dest='report_type', help='报告类型', required=True)

    # 默认/昨日报告
    subparsers.add_parser('yesterday', help='生成昨日报告 (默认)')

    # 今日报告
    subparsers.add_parser('today', help='生成今日报告')

    # 指定日期报告
    date_parser = subparsers.add_parser('date', help='生成指定日期报告')
    date_parser.add_argument('report_date', type=str, help='报告日期 (格式: YYYY-MM-DD)')

    # 周报
    weekly_parser = subparsers.add_parser('weekly', help='生成最近7天周报')
    weekly_parser.add_argument('end_date', type=str, nargs='?', default=None, help='周报的结束日期 (可选, 格式: YYYY-MM-DD)')

    # 月报
    monthly_parser = subparsers.add_parser('monthly', help='生成最近30天月报')
    monthly_parser.add_argument('end_date', type=str, nargs='?', default=None, help='月报的结束日期 (可选, 格式: YYYY-MM-DD)')

    # 如果没有提供参数，默认行为是'yesterday'
    if len(sys.argv) == 1:
        sys.argv.append('yesterday')
        
    args = parser.parse_args()

    report_type = args.report_type

    if report_type == 'today':
        report_date = date.today()
        generate_daily_report(report_date.strftime('%Y-%m-%d'))
    elif report_type == 'yesterday':
        report_date = date.today() - timedelta(days=1)
        generate_daily_report(report_date.strftime('%Y-%m-%d'))
    elif report_type == 'date':
        generate_daily_report(args.report_date)
    elif report_type == 'weekly':
        end_date = date.fromisoformat(args.end_date) if args.end_date else date.today() - timedelta(days=1)
        start_date = end_date - timedelta(days=6)
        generate_period_report(start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'), "周", 7)
    elif report_type == 'monthly':
        end_date = date.fromisoformat(args.end_date) if args.end_date else date.today() - timedelta(days=1)
        start_date = end_date - timedelta(days=29)
        generate_period_report(start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'), "月", 30)

    print("==========================================")
    print("报告生成完成")
    print("==========================================")


if __name__ == "__main__":
    main()