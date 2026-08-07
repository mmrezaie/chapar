from __future__ import annotations

import ast
import io
import json
import re
import tokenize
from collections.abc import Iterator
from pathlib import PurePosixPath
from typing import assert_never

from .model import (
    AUDIT_PATH,
    MARKDOWN_SUFFIXES,
    POLICY_PATHS,
    POLICY_TOKENS,
    SHELL_FENCES,
    SHELL_SUFFIXES,
    AuditInputError,
    Candidate,
)
from .shell import direct_install_segment, shell_candidates

type JsonValue = str | float | bool | None | list[JsonValue] | dict[str, JsonValue]


def markdown_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    fence_marker: str | None = None
    fence_length = 0
    shell_fence = False
    fence_line = 0
    fence_content: list[str] = []
    shell_blocks: list[tuple[int, str]] = []
    prose: list[tuple[int, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        opening = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", line)
        if fence_marker is None and opening is not None:
            marker, info = opening.groups()
            if marker[0] == "`" and "`" in info:
                prose.append((line_number, line))
                continue
            language = info.strip().split(maxsplit=1)[0].lower() if info.strip() else ""
            fence_marker = marker[0]
            fence_length = len(marker)
            shell_fence = language in SHELL_FENCES
            fence_line = line_number
            fence_content = []
            continue
        if fence_marker is not None:
            closing = re.fullmatch(rf" {{0,3}}{re.escape(fence_marker)}{{{fence_length},}}[ \t]*", line)
            if closing is not None:
                if shell_fence:
                    shell_blocks.append((fence_line, "\n".join(fence_content)))
                fence_marker = None
                fence_content = []
                continue
            fence_content.append(line)
            continue
        prose.append((line_number, line))
    if fence_marker is not None and shell_fence:
        shell_blocks.append((fence_line, "\n".join(fence_content)))
    for opening_line, content in shell_blocks:
        for candidate in shell_candidates(path, content):
            yield Candidate(path=path, line=opening_line + candidate.line, tokens=candidate.tokens)
    block: list[tuple[int, str]] = []
    for line_number, line in prose + [(0, "")]:
        starts_item = re.match(r"\s*(?:[-*+] |\d+\. )", line) is not None
        if block and (not line.strip() or starts_item):
            normalized = " ".join(part.strip() for _, part in block)
            for sentence in re.split(r"(?<=[.!?])\s+", normalized):
                policy_words = sentence.lower()
                policy_language = any(token in policy_words for token in POLICY_TOKENS)
                if path not in POLICY_PATHS and not policy_language and not block[0][1].lstrip().startswith(("-", "*", "+")):
                    continue
                commands = tuple(
                    filter(None, (direct_install_segment(inline) for inline in re.findall(r"`([^`]+)`", sentence)))
                )
                negative = len(commands) == 1 and policy_language
                for tokens in commands:
                    yield Candidate(path=path, line=block[0][0], tokens=tokens, negative_policy=negative)
            block = []
        if line.strip():
            block.append((line_number, line))


def json_strings(value: JsonValue) -> Iterator[str]:
    match value:
        case str() as text:
            yield text
        case list() as items:
            for item in items:
                yield from json_strings(item)
        case dict() as entries:
            for item in entries.values():
                yield from json_strings(item)
        case int() | float() | bool() | None:
            return
        case unreachable:
            assert_never(unreachable)


def json_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    try:
        document: JsonValue = json.loads(text)
    except json.JSONDecodeError as error:
        raise AuditInputError(f"malformed JSON: {error.msg} at line {error.lineno}") from error
    for value in json_strings(document):
        tokens = direct_install_segment(value)
        if tokens is not None:
            line = text.count("\n", 0, text.find(value)) + 1
            yield Candidate(path=path, line=line, tokens=tokens)


def fixture_nodes(tree: ast.Module) -> frozenset[int]:
    for statement in tree.body:
        match statement:  # noqa: MATCH_OK - AST visitors intentionally select relevant node shapes.
            case ast.AnnAssign(
                target=ast.Name(id="SELF_TEST_FIXTURES"), annotation=annotation, value=ast.Dict(values=values)
            ) if ast.unparse(annotation) == "dict[str, str]":
                if all(isinstance(value, ast.Constant) and isinstance(value.value, str) for value in values):
                    return frozenset(id(value) for value in values)
            case _:
                continue
    return frozenset()


def static_string(node: ast.expr) -> str | None:
    match node:  # noqa: MATCH_OK - dynamic string expressions are intentionally rejected.
        case ast.Constant(value=str() as value):
            return value
        case ast.BinOp(left=left, op=ast.Add(), right=right):
            left_value = static_string(left)
            right_value = static_string(right)
            if left_value is not None and right_value is not None:
                return left_value + right_value
            return None
        case _:
            return None


def python_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    try:
        tree = ast.parse(text)
    except SyntaxError as error:
        raise AuditInputError(f"malformed Python at line {error.lineno}: {error.msg}") from error
    fixtures = fixture_nodes(tree) if path == AUDIT_PATH else frozenset()
    child_nodes = {
        id(child) for node in ast.walk(tree) if isinstance(node, ast.BinOp) for child in (node.left, node.right)
    }
    for node in ast.walk(tree):
        if not isinstance(node, ast.expr) or id(node) in child_nodes:
            continue
        value = static_string(node)
        if value is None:
            continue
        tokens = direct_install_segment(value)
        if tokens is not None:
            yield Candidate(path=path, line=node.lineno, tokens=tokens, fixture_value=id(node) in fixtures)
    try:
        comments = tokenize.generate_tokens(io.StringIO(text).readline)
        for token in comments:
            if token.type != tokenize.COMMENT:
                continue
            tokens = direct_install_segment(token.string.removeprefix("#"))
            if tokens is not None:
                yield Candidate(path=path, line=token.start[0], tokens=tokens)
    except (IndentationError, tokenize.TokenError) as error:
        raise AuditInputError(f"malformed Python token stream: {error}") from error


def candidates_for(path: PurePosixPath, text: str) -> tuple[Candidate, ...]:
    if path.name == "Makefile" or path.suffix in SHELL_SUFFIXES:
        return tuple(shell_candidates(path, text))
    if path.suffix in MARKDOWN_SUFFIXES:
        return tuple(markdown_candidates(path, text))
    if path.suffix == ".json":
        return tuple(json_candidates(path, text))
    if path.suffix == ".py":
        return tuple(python_candidates(path, text))
    return ()
