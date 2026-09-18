#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GitHub 连通性诊断工具
=====================

用途：国内网络下 GitHub 的 IP 会漂移，被封的往往是某一个具体 IP。
      本脚本扫描候选 IP 池，找出真正可用的 IP，并生成 hosts 补丁建议。

用法：
    python check_github.py

只依赖标准库，无需 pip install。
"""

import socket
import ssl
import sys
import concurrent.futures

# --- 候选 IP 池（GitHub 官方公布网段内的常用 IP）---------------------------
GITHUB_IPS = [
    "140.82.112.3", "140.82.112.4", "140.82.113.3", "140.82.113.4",
    "140.82.114.3", "140.82.114.4", "140.82.116.3", "140.82.116.4",
    "140.82.121.3", "140.82.121.4",
    "20.205.243.166", "20.27.177.113", "20.200.245.247", "4.237.22.38",
]
API_IPS = [
    "140.82.112.5", "140.82.112.6", "140.82.113.5", "140.82.113.6",
    "140.82.114.5", "140.82.114.6", "140.82.116.5", "140.82.121.6",
]
FASTLY_IPS = [
    "185.199.108.133", "185.199.109.133", "185.199.110.133", "185.199.111.133",
]

# --- 需要测试的域名 -> 候选 IP ---------------------------------------------
DOMAINS = {
    "github.com": GITHUB_IPS,
    "api.github.com": API_IPS,
    "codeload.github.com": API_IPS,
    "raw.githubusercontent.com": FASTLY_IPS,
    "objects.githubusercontent.com": FASTLY_IPS,
}

TIMEOUT = 4.0


def tcp_ok(ip, port=443, timeout=TIMEOUT):
    """TCP 层连通性测试。"""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def tls_ok(ip, host, port=443, timeout=TIMEOUT):
    """TLS 握手测试：确认 IP 上确实跑着该域名的证书。"""
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((ip, port), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host):
                return True
    except Exception:
        return False


def line(char="-", width=62):
    print(char * width)


def main():
    print()
    line("=")
    print("  GitHub 连通性诊断")
    line("=")
    print()

    # ---- 第一步：当前 DNS 解析是否可用 ----
    # 注意：这里必须用 TLS 握手判定而非 TCP 判定。
    # 原因：GFW 的典型行为是 TCP 三次握手照常成功，
    #       但在 TLS ClientHello 之后注入 RST —— 只测 TCP 会误判为"可用"。
    print("[1/3] 检查当前 DNS 解析结果（TLS 握手判定）")
    line()
    dns_broken = []
    for host in DOMAINS:
        try:
            resolved = socket.gethostbyname(host)
        except OSError as e:
            print("  %-34s 解析失败 (%s)" % (host, e))
            dns_broken.append(host)
            continue
        if tls_ok(resolved, host):
            mark = "可用"
        elif tcp_ok(resolved):
            mark = "TCP 通但 TLS 被重置"
        else:
            mark = "阻塞"
        print("  %-34s -> %-16s [%s]" % (host, resolved, mark))
        if mark != "可用":
            dns_broken.append(host)
    print()

    if not dns_broken:
        print("  ^ 所有域名均可用，无需修复。")
        print()
        return 0

    # ---- 第二步：扫描候选 IP ----
    print("[2/3] 扫描候选 IP 池（这一步约需 20 秒）")
    line()
    best = {}
    for host, pool in DOMAINS.items():
        if host not in dns_broken:
            continue
        found = None
        for ip in pool:
            if tcp_ok(ip) and tls_ok(ip, host):
                found = ip
                break
        best[host] = found
        if found:
            print("  %-34s -> 可用 IP: %s" % (host, found))
        else:
            print("  %-34s -> 未找到可用 IP（可能整体受限）" % host)
    print()

    # ---- 第三步：输出 hosts 补丁 ----
    usable = {h: ip for h, ip in best.items() if ip}
    print("[3/3] hosts 补丁建议")
    line()
    if not usable:
        print("  未找到任何可用 IP。请检查网络，或改用代理方式。")
        print()
        return 1

    print("  将以下内容加入 C:\\Windows\\System32\\drivers\\etc\\hosts")
    print("  （需管理员权限；或直接运行同目录的 fix_github_hosts.bat）")
    print()
    print("  # dancealarm-github-fix begin")
    for host, ip in usable.items():
        print("  %-17s %s" % (ip, host))
    print("  # dancealarm-github-fix end")
    print()
    print("  完成后执行：ipconfig /flushdns")
    print()
    line("=")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已取消。")
        sys.exit(130)
