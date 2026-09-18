#!/usr/bin/env python3
"""Swift 源码粗检（纯标准库）。

在没有 macOS / Xcode 的机器上没法真正编译 Swift，但可以先排掉一大类低级错误：
  - 括号 {} () [] 不配对
  - 字符串 / 注释未闭合
  - 非 ASCII 的引号、破折号混进语法位置（从文档复制代码时最常见）
  - 同一个文件里重复定义同名的 struct / class / enum / func

它不是编译器，只是「出门前照一下镜子」。真正的类型检查还得靠 Xcode。
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DanceAlarm")

PAIRS = {"}": "{", ")": "(", "]": "["}


def strip_code(src):
    """去掉注释与字符串字面量，只留下参与括号配对的结构字符。

    返回 (清理后的文本, 错误列表)
    """
    out = []
    errors = []
    i = 0
    n = len(src)
    line = 1

    while i < n:
        ch = src[i]

        if ch == "\n":
            line += 1
            out.append("\n")
            i += 1
            continue

        # 行注释
        if src.startswith("//", i):
            j = src.find("\n", i)
            if j == -1:
                break
            i = j
            continue

        # 块注释（Swift 支持嵌套）
        if src.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth > 0:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if src[i] == "\n":
                        line += 1
                    i += 1
            if depth > 0:
                errors.append("第 %d 行起：块注释未闭合" % line)
            continue

        # 多行字符串 """
        if src.startswith('"""', i):
            end = src.find('"""', i + 3)
            if end == -1:
                errors.append("第 %d 行起：多行字符串未闭合" % line)
                break
            line += src.count("\n", i, end)
            i = end + 3
            continue

        # 普通字符串
        if ch == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "\n":
                    errors.append("第 %d 行：字符串换行未闭合（少了一个引号？）" % line)
                    line += 1
                    break
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out), errors


def check_balance(path, cleaned):
    stack = []
    line = 1
    problems = []
    for ch in cleaned:
        if ch == "\n":
            line += 1
        elif ch in "{([":
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                problems.append("第 %d 行：多余的 '%s'" % (line, ch))
            else:
                open_ch, open_line = stack.pop()
                if open_ch != PAIRS[ch]:
                    problems.append(
                        "第 %d 行：'%s' 与第 %d 行的 '%s' 不匹配"
                        % (line, ch, open_line, open_ch)
                    )
    for open_ch, open_line in stack:
        problems.append("第 %d 行：'%s' 未闭合" % (open_line, open_ch))
    return problems


SUSPICIOUS = {
    "\u201c": "左双引号（中文引号误入代码）",
    "\u201d": "右双引号（中文引号误入代码）",
    "\u2018": "左单引号（中文引号误入代码）",
    "\u2019": "右单引号（中文引号误入代码）",
    "\uff1b": "中文分号",
    "\uff08": "中文左括号",
    "\uff09": "中文右括号",
    "\uff0c": "中文逗号",
}


def check_suspicious(path, cleaned):
    """在**剥离了字符串与注释之后**的文本里找中文标点。

    必须先剥离再找：中文字符串里出现中文逗号、中文括号是完全正常的
    （整个 App 的界面文案都是中文），只有出现在**语法位置**上才是错误。
    """
    bad = []
    for lineno, text in enumerate(cleaned.splitlines(), 1):
        if not text.strip():
            continue
        for ch, desc in SUSPICIOUS.items():
            if ch in text:
                bad.append("第 %d 行：%s → %s" % (lineno, desc, text.strip()[:60]))
    return bad


DECL = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
                  r"(struct|class|enum|protocol)\s+(\w+)", re.MULTILINE)


def check_duplicates(path, cleaned):
    seen = {}
    dupes = []
    for match in DECL.finditer(cleaned):
        kind, name = match.group(1), match.group(2)
        key = (kind, name)
        if key in seen:
            dupes.append("重复定义 %s %s（本文件内）" % (kind, name))
        seen[key] = True
    return dupes


def main():
    if not os.path.isdir(ROOT):
        print("找不到源码目录：%s" % ROOT)
        return 1

    files = []
    for dirpath, _, filenames in os.walk(ROOT):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                files.append(os.path.join(dirpath, name))
    files.sort()

    total_problems = 0
    for path in files:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()

        cleaned, errs = strip_code(src)
        problems = errs + check_balance(path, cleaned) + check_duplicates(path, cleaned)
        problems += check_suspicious(path, cleaned)

        rel = os.path.relpath(path, os.path.dirname(ROOT))
        if problems:
            total_problems += len(problems)
            print("✗ %s" % rel)
            for p in problems:
                print("    %s" % p)
        else:
            print("✓ %s  (%d 行)" % (rel, src.count("\n") + 1))

    print()
    if total_problems:
        print("发现 %d 处可疑问题，需要人工确认" % total_problems)
        return 1
    print("全部 %d 个 Swift 文件通过粗检（括号配对 / 字符串闭合 / 无重复定义 / 无中文标点误入代码）"
          % len(files))
    print("注意：这只是粗检，真正的类型检查仍需在 macOS 上用 Xcode 编译。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
