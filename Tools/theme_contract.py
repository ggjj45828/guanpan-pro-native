#!/usr/bin/env python3
"""主题语义色回归合同（静态检查）。

用法：python3 Tools/theme_contract.py
退出码 0 = 通过；1 = 有违约项，CI 会直接失败。

检查内容：
  1. ThemeSemantics.swift 的 hex 与 theme_contract.json 逐项一致；
  2. 两套主题的文字/卡片、强调底前景色 WCAG 对比度达到阈值；
  3. 全站 Swift 文件 LF、无行尾空格（防止 diff 误报整片尾随空格）；
  4. 受管表单文件禁止系统语义色与硬编码白/黑字；
  5. 全站禁止硬编码白/黑字做前景色（allowlist 需写明理由）；
  6. 禁止页面直接引用静态版式令牌 DS.* / AppLayout.*；
  7. 弹窗背板必须走 AppAppearance.resolved，且 sheet 内容挂 themedSheetBackground。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
CONTRACT = Path(__file__).resolve().parent / "theme_contract.json"

errors: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def hex_to_rgb(value: str) -> tuple[float, float, float]:
    v = value.lstrip("#")
    return tuple(int(v[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def luminance(value: str) -> float:
    def channel(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in hex_to_rgb(value))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def main() -> int:
    cfg = json.loads(CONTRACT.read_text(encoding="utf-8"))
    checks = cfg["checks"]

    # 1) 源码 hex 与契约一致
    semantics = (SOURCES / "ThemeSemantics.swift").read_text(encoding="utf-8")
    found: dict[str, str] = {}
    for m in re.finditer(
        r"(\w+):\s*Color\(hex:\s*0x([0-9A-Fa-f]{6})\)[^\n]*//\s*contract:\s*(\w+)\.(\w+)",
        semantics,
    ):
        found[f"{m.group(3)}.{m.group(4)}"] = "#" + m.group(2).upper()
    for theme, palette in cfg["palettes"].items():
        for token, want in palette.items():
            key = f"{theme}.{token}"
            got = found.get(key)
            if got is None:
                fail(f"契约 {key} 在 ThemeSemantics.swift 里找不到 contract 注释")
            elif got != want.upper():
                fail(f"契约 {key} 不一致：Swift={got} JSON={want}")
    notes.append(f"语义色 token 核对：{len(found)} 项")

    # 2) 对比度
    limits = cfg["contrast"]
    pairs = [
        ("body", "ink", "card"),
        ("secondary", "ink2", "card"),
        ("hint", "ink3", "card"),
        ("onAccent", "onAccent", "accent"),
        ("onPage", "ink", "pageTop"),
        ("body", "ink", "cardSoft"),
    ]
    for theme, palette in cfg["palettes"].items():
        for kind, fg, bg in pairs:
            ratio = contrast(palette[fg], palette[bg])
            floor = limits[kind]
            status = "OK" if ratio >= floor else "FAIL"
            notes.append(f"  {theme} {fg}/{bg}: {ratio:.2f}:1 (≥{floor}) {status}")
            if ratio < floor:
                fail(f"{theme} 的 {fg} 在 {bg} 上对比度 {ratio:.2f}:1 < {floor}:1")

    # 3) 换行 / 尾随空格
    swift_files = sorted(SOURCES.glob("*.swift"))
    for p in swift_files:
        raw = p.read_bytes()
        if b"\r\n" in raw:
            fail(f"{p.name}: 存在 CRLF，仓库统一使用 LF")
        for i, line in enumerate(raw.decode("utf-8").splitlines(), 1):
            if line.rstrip(" \t") != line:
                fail(f"{p.name}:{i}: 行尾空格")
                break

    # 4) 受管文件禁止写法
    managed = set(checks["managedFiles"])
    for p in swift_files:
        if p.name not in managed:
            continue
        text = "\n".join(l.split("//", 1)[0] for l in p.read_text(encoding="utf-8").splitlines())
        for token in checks["managedForbidden"]:
            if token in text:
                fail(f"[受管] {p.name} 仍使用系统默认样式：{token}")

    # 5) 全站硬编码白/黑前景色
    fg_re = re.compile(r"\.foregroundStyle\((?:Color\.)?(white|black)\)")
    for p in swift_files:
        text = p.read_text(encoding="utf-8")
        for i, line in enumerate(text.splitlines(), 1):
            for token in checks["globalForbiddenForeground"]:
                if token in line:
                    short = token.replace("foregroundStyle", "fg")
                    allowed = any(
                        a["file"] == p.name and a["token"] in line
                        for a in checks.get("globalAllowlist", [])
                    )
                    if not allowed:
                        fail(f"[全站] {p.name}:{i}: 硬编码前景色 {short} → {line.strip()[:90]}")
        _ = fg_re

    # 6) 静态版式令牌
    for p in swift_files:
        if p.name in checks["layoutTokenDefinitionFiles"]:
            continue
        text = p.read_text(encoding="utf-8")
        for token in checks["forbiddenLayoutTokens"]:
            for i, line in enumerate(text.splitlines(), 1):
                if token in line and "minimumTapHeight" not in line:
                    fail(f"[版式] {p.name}:{i}: 静态令牌 {token} → 改用 palette.xxx / ThemeLayout")

    # 7) 弹窗背板
    app_theme = (SOURCES / "AppTheme.swift").read_text(encoding="utf-8")
    body = app_theme.split("struct ThemedSheetBackground", 1)[-1].split("extension View", 1)[0]
    if checks["requireResolvedInSheetBackground"] and "AppAppearance.resolved(appearance)" not in body:
        fail("ThemedSheetBackground 未先 resolved(appearance)：.system + 浅色系统会深底黑字")
    if checks["requireSheetBackground"]:
        for p in swift_files:
            text = p.read_text(encoding="utf-8")
            sheets = text.count(".sheet(") + text.count(".fullScreenCover(")
            themed = text.count(".themedSheetBackground()")
            if sheets > themed and "contract-ignore: sheet-background" not in text:
                fail(f"[弹窗] {p.name}: {sheets} 个 sheet 只有 {themed} 处 themedSheetBackground")

    print("=== 主题语义色回归合同 v%s ===" % cfg["version"])
    for n in notes:
        print(n)
    if errors:
        print(f"\n违约 {len(errors)} 项：")
        for e in errors[:80]:
            print("  -", e)
        if len(errors) > 80:
            print(f"  ... 另有 {len(errors) - 80} 项")
        return 1
    print(f"\n通过：{len(swift_files)} 个 Swift 文件，0 项违约")
    return 0


if __name__ == "__main__":
    sys.exit(main())
