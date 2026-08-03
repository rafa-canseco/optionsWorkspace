#!/usr/bin/env python3
"""Classify credential-like assignments without ever echoing their values."""

from __future__ import annotations

import argparse
import math
import re
import sys
from collections import Counter
from dataclasses import dataclass


MIN_LITERAL_LENGTH = 24

CREDENTIAL_ASSIGNMENT = re.compile(
    r"""
    (?<![A-Za-z0-9_])
    (?P<quote>["']?)
    (?P<key>
        (?:[A-Za-z0-9]+_)*
        (?:PRIVATE_KEY|SECRET_KEY|API_KEY|MNEMONIC|SEED_PHRASE)
    )
    (?P=quote)
    \s*[:=]\s*
    """,
    re.IGNORECASE | re.VERBOSE,
)

PREFIXED_HEX_LITERAL = re.compile(r"0x[0-9a-fA-F]{24,}")
BARE_HEX_LITERAL = re.compile(r"[0-9a-fA-F]{32,}")
LITERAL_TOKEN = re.compile(r"[A-Za-z0-9_./+=-]{16,}")
REFERENCE_EXPRESSION = re.compile(
    r"""
    (?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[A-Za-z_$][A-Za-z0-9_$]*)
    (?:
        (?:\.|\?\.)[A-Za-z_$][A-Za-z0-9_$]*
        |\[[^\]\r\n]+\]
    )*
    """,
    re.VERBOSE,
)
IDENTIFIER = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")

# Prefixes are intentionally specific to credential formats that are not ordinary
# identifiers. Matching is done before the generic identifier exemption.
PROVIDER_PREFIXES = (
    "AKIA",
    "ASIA",
    "AIza",
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "github_pat_",
    "npm_",
    "pypi-",
    "sk-",
    "sk_live_",
    "sk_test_",
    "rk_live_",
    "sq0atp-",
    "sq0csp-",
    "xoxb-",
    "xoxp-",
    "xoxa-",
    "xoxr-",
    "xoxs-",
    "ya29.",
)


@dataclass(frozen=True)
class Finding:
    line_number: int
    category: str


def _quoted_values_and_unquoted_text(text: str) -> tuple[list[str], str]:
    quoted_values: list[str] = []
    unquoted = list(text)
    position = 0
    while position < len(text):
        if text[position] not in {'"', "'", "`"}:
            position += 1
            continue

        quote = text[position]
        quote_start = position
        position += 1
        escaped = False
        value: list[str] = []
        while position < len(text):
            character = text[position]
            if escaped:
                value.append(character)
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quoted_values.append("".join(value))
                position += 1
                break
            else:
                value.append(character)
            position += 1

        for redacted_position in range(quote_start, position):
            unquoted[redacted_position] = " "

    return quoted_values, "".join(unquoted)


def _has_provider_prefix(value: str) -> bool:
    return len(value) >= 16 and value.startswith(PROVIDER_PREFIXES)


def _entropy(value: str) -> float:
    counts = Counter(value)
    length = len(value)
    return -sum(
        (count / length) * math.log2(count / length) for count in counts.values()
    )


def _is_high_entropy_literal(value: str) -> bool:
    if len(value) < MIN_LITERAL_LENGTH:
        return False
    if not re.fullmatch(r"[A-Za-z0-9_./+=-]+", value):
        return False

    character_classes = sum(
        bool(pattern.search(value))
        for pattern in (
            re.compile(r"[a-z]"),
            re.compile(r"[A-Z]"),
            re.compile(r"[0-9]"),
            re.compile(r"[_./+=-]"),
        )
    )
    return character_classes >= 3 and _entropy(value) >= 3.5


def _is_quoted_hex_literal(value: str) -> bool:
    return bool(
        PREFIXED_HEX_LITERAL.fullmatch(value) or BARE_HEX_LITERAL.fullmatch(value)
    )


def _is_unambiguous_unquoted_hex_literal(value: str) -> bool:
    if PREFIXED_HEX_LITERAL.fullmatch(value):
        return True
    return bool(BARE_HEX_LITERAL.fullmatch(value) and not IDENTIFIER.fullmatch(value))


def _consume_balanced(expression: str, position: int) -> int | None:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[expression[position]]]
    position += 1
    quote: str | None = None
    escaped = False

    while position < len(expression):
        character = expression[position]
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
        elif character in {'"', "'", "`"}:
            quote = character
        elif character in pairs:
            stack.append(pairs[character])
        elif character == stack[-1]:
            stack.pop()
            if not stack:
                return position + 1
        position += 1
    return None


def _is_pure_reference_or_callable(expression: str) -> bool:
    expression = expression.strip().rstrip(",;").rstrip()
    if REFERENCE_EXPRESSION.fullmatch(expression):
        return True

    position = 0
    if expression.startswith("await "):
        position = len("await ")

    identifier = IDENTIFIER.match(expression, position)
    if identifier is None:
        return False
    position = identifier.end()
    saw_call = False

    while position < len(expression):
        while position < len(expression) and expression[position].isspace():
            position += 1
        if position == len(expression):
            break

        if expression.startswith("?.", position):
            position += 2
            member = IDENTIFIER.match(expression, position)
            if member is None:
                return False
            position = member.end()
        elif expression[position] == ".":
            position += 1
            member = IDENTIFIER.match(expression, position)
            if member is None:
                return False
            position = member.end()
        elif expression[position] in "([":
            opener = expression[position]
            next_position = _consume_balanced(expression, position)
            if next_position is None:
                return False
            saw_call = saw_call or opener == "("
            position = next_position
        else:
            return False

    return saw_call and position == len(expression)


def _rhs_end(line: str, start: int, upper_bound: int) -> int:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    quote: str | None = None
    escaped = False
    position = start

    while position < upper_bound:
        character = line[position]
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
        elif character in {'"', "'", "`"}:
            quote = character
        elif character in pairs:
            stack.append(pairs[character])
        elif stack and character == stack[-1]:
            stack.pop()
        elif not stack and character in ",;)]}":
            return position
        position += 1
    return upper_bound


def classify_rhs(rhs: str) -> str | None:
    """Return a redacted category, or None for a non-literal expression."""

    rhs = rhs.strip()
    exact_token = LITERAL_TOKEN.fullmatch(rhs.rstrip(",;").rstrip())
    if exact_token is not None:
        token = exact_token.group(0)
        if _has_provider_prefix(token):
            return "provider-prefixed-literal"
        if _is_unambiguous_unquoted_hex_literal(token):
            return "hexadecimal-literal"

    if _is_pure_reference_or_callable(rhs):
        return None

    quoted_values, unquoted_text = _quoted_values_and_unquoted_text(rhs)
    for quoted_value in quoted_values:
        if _has_provider_prefix(quoted_value):
            return "provider-prefixed-literal"
        if _is_quoted_hex_literal(quoted_value):
            return "hexadecimal-literal"
        if len(quoted_value) >= MIN_LITERAL_LENGTH:
            return "quoted-literal"

    for token_match in LITERAL_TOKEN.finditer(unquoted_text):
        token = token_match.group(0)
        if _has_provider_prefix(token):
            return "provider-prefixed-literal"
        if _is_unambiguous_unquoted_hex_literal(token):
            return "hexadecimal-literal"
        if not REFERENCE_EXPRESSION.fullmatch(token) and _is_high_entropy_literal(
            token
        ):
            return "high-entropy-literal"
    return None


def classify_text(text: str) -> list[Finding]:
    findings: list[Finding] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        assignments = list(CREDENTIAL_ASSIGNMENT.finditer(line))
        for assignment_index, assignment in enumerate(assignments):
            upper_bound = (
                assignments[assignment_index + 1].start()
                if assignment_index + 1 < len(assignments)
                else len(line)
            )
            rhs_end = _rhs_end(line, assignment.end(), upper_bound)
            category = classify_rhs(line[assignment.end() : rhs_end])
            if category is not None:
                findings.append(Finding(line_number=line_number, category=category))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect credential literals while redacting candidate values."
    )
    parser.add_argument("--quiet", action="store_true", help="Do not print findings")
    args = parser.parse_args()

    text = sys.stdin.buffer.read().decode("utf-8", errors="ignore")
    findings = classify_text(text)
    if not args.quiet:
        for finding in findings:
            print(
                f"sensitive-classifier: line={finding.line_number} "
                f"category={finding.category}",
                file=sys.stderr,
            )
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
