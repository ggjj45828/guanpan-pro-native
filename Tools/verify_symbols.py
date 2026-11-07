#!/usr/bin/env python3
"""静态调用符号核对（无 Swift 编译器时的第一道防线）。

只查一件事：`Type.member(...)` 里，如果 `Type` 是本工程自己定义的类型，
那 `member` 必须是这个类型声明过的静态成员 / enum case / 构造器。

2.26.0 首次 CI 就是栽在 `MarketSessionStatus.status(at:)`：
`status(at:custom:)` 其实在 `TradingSession` 上，本地括号平衡和主题合同都查不出来，
只能等 macOS runner 编译失败。这里把这类错误提前到本地。

局限：只做源码层名字核对，不做类型推导、不解析协议/继承来的成员、不查系统类型。
因此命中时只说明「需要人工再看一眼」，不替代 Apple 编译。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Sources"
FILES = sorted(ROOT.rglob("*.swift"))

# 由协议默认实现 / 系统扩展提供、但源码里找不到 static 声明的成员，在这里显式豁免。
ALLOW: set[tuple[str, str]] = {
    # 例：("SomeType", "someMember")
}

TYPE_DEF = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|final|open|nonisolated|@\w+)\s+)*"
    r"(enum|struct|class|extension|actor)\s+([A-Z]\w*)",
    re.M,
)
STATIC_MEMBER = re.compile(r"\b(?:static|class)\s+(?:func|var|let)\s+(\w+)")
INSTANCE_MEMBER = re.compile(r"^\s*(?:@\w+\s+)*(?:lazy\s+)?(?:func|var|let)\s+(\w+)", re.M)
CASE_LINE = re.compile(r"^\s*case\s+([^\n{]+)", re.M)
CALL = re.compile(r"\b([A-Z]\w*)\.(\w+)\s*\(")


def strip_noise(src: str) -> str:
    """剥掉注释和字符串字面量，保留换行以维持行号。"""
    out: list[str] = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        if src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                    continue
                if src.startswith("*/", i):
                    depth -= 1
                    i += 2
                    continue
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            continue
        if src[i] == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            out.append('""')
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def block_end(src: str, opening: int) -> int:
    """从 `{` 找到配对的 `}`。src 已剥掉注释与字符串，大括号只剩代码。"""
    depth = 0
    for i in range(opening, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return len(src)


def collect() -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    static: dict[str, set[str]] = {}
    instance: dict[str, set[str]] = {}
    for path in FILES:
        src = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        for match in TYPE_DEF.finditer(src):
            opening = src.find("{", match.end())
            if opening < 0:
                continue
            # 不能按「下一个类型定义」切块：类型里嵌套的 enum/struct 会提前截断范围，
            # 把外层后半个文件的 static 成员漏掉。按花括号配对拿完整类型体。
            block = src[opening:block_end(src, opening)]
            name = match.group(2)
            target = static.setdefault(name, set())
            inst = instance.setdefault(name, set())
            target.update(STATIC_MEMBER.findall(block))
            for raw in CASE_LINE.findall(block):
                for item in raw.split(","):
                    item = item.strip().split("(")[0].split("=")[0].strip()
                    if re.fullmatch(r"\w+", item or ""):
                        target.add(item)
            inst.update(INSTANCE_MEMBER.findall(block))
    return static, instance


def check_source(
    src: str,
    static: dict[str, set[str]],
    instance: dict[str, set[str]],
    label: str,
) -> tuple[list[str], int]:
    violations: list[str] = []
    checked = 0
    for match in CALL.finditer(src):
        type_name, member = match.group(1), match.group(2)
        if type_name not in static or member == "init":
            continue
        if (type_name, member) in ALLOW:
            continue
        checked += 1
        if member in static[type_name]:
            continue
        line = src.count("\n", 0, match.start()) + 1
        where = f"{label}:{line}"
        if member in instance[type_name]:
            violations.append(f"{where}: {type_name}.{member}(...) 是实例成员，不能按类型调用")
        else:
            violations.append(f"{where}: 本工程类型 {type_name} 没有静态成员 {member}(...)")
    return violations, checked


def main() -> int:
    static, instance = collect()
    violations: list[str] = []
    checked = 0
    for path in FILES:
        src = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        found, count = check_source(src, static, instance, str(path.relative_to(ROOT.parent)))
        violations.extend(found)
        checked += count

    # 自检：确认规则没有因为改写而悄悄失效。
    probe, _ = check_source(
        "let session = MarketSessionStatus.status(at: now)",
        static, instance, "<self-test>",
    )
    if not any("MarketSessionStatus" in item and "status" in item for item in probe):
        print("自检失败：已知的 MarketSessionStatus.status(...) 误用没有被拦住")
        return 1

    print("=== 静态调用符号核对 ===")
    print(f"{len(FILES)} 个 Swift 文件 / {len(static)} 个本工程类型 / {checked} 处静态调用")
    print("自检：已知误用可被拦截")
    if violations:
        print(f"发现 {len(violations)} 项：")
        for item in violations:
            print("  -", item)
        return 1
    print("通过：0 项违约（不替代 Apple 编译）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
