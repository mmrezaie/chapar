from __future__ import annotations

import re
import shlex
from collections.abc import Iterator
from pathlib import PurePosixPath

from .model import COMMAND_SEPARATORS, AuditInputError, Candidate


def lex_shell(source: str) -> tuple[str, ...]:
    source = source.replace("\\\r\n", "").replace("\\\n", "")
    lexer = shlex.shlex(source, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = "#"
    try:
        return tuple(lexer)
    except ValueError as error:
        raise AuditInputError(f"malformed shell syntax: {error}") from error


def legacy_backtick_payloads(source: str) -> tuple[str, ...]:
    payloads: list[str] = []
    payload: list[str] | None = None
    single_quoted = False
    double_quoted = False
    escaped = False
    for index, character in enumerate(source):
        marker_run = character == "`" and (
            (index > 0 and source[index - 1] == "`")
            or (index + 1 < len(source) and source[index + 1] == "`")
        )
        if escaped:
            if payload is not None:
                payload.append(character)
            escaped = False
            continue
        if character == "\\":
            if payload is not None:
                payload.append(character)
            escaped = True
            continue
        if payload is not None:
            if character == "`" and not marker_run:
                payloads.append("".join(payload))
                payload = None
            else:
                payload.append(character)
            continue
        if character == "'" and not double_quoted:
            single_quoted = not single_quoted
        elif character == '"' and not single_quoted:
            double_quoted = not double_quoted
        elif character == "#" and not single_quoted and not double_quoted and (
            index == 0 or source[index - 1] in " \t\r\n;&|()"
        ):
            break
        elif character == "`" and not single_quoted and not marker_run:
            payload = []
    if payload is not None:
        raise AuditInputError("unterminated legacy command substitution")
    return tuple(payloads)


def logical_shell_lines(text: str) -> Iterator[tuple[int, str]]:
    pending = ""
    start_line = 1
    heredoc: tuple[str, bool] | None = None
    for line_number, line in enumerate(text.splitlines(), 1):
        if heredoc is not None:
            delimiter, strips_tabs = heredoc
            candidate = line.lstrip("\t") if strips_tabs else line
            if candidate == delimiter:
                heredoc = None
            continue
        if not pending:
            start_line = line_number
        trailing_slashes = len(line) - len(line.rstrip("\\"))
        if not line.lstrip().startswith("#") and trailing_slashes % 2 == 1:
            pending += line[:-1] + " "
            continue
        pending += line
        heredoc_match = re.search(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line)
        if heredoc_match is not None:
            heredoc = (heredoc_match.group(3), heredoc_match.group(1) == "-")
        try:
            shell_tokens = lex_shell(pending)
        except AuditInputError:
            pending += "\n"
        else:
            substitution_depth = 0
            previous_character = ""
            for token in shell_tokens:
                for character in token:
                    if character == "(" and (substitution_depth or previous_character == "$"):
                        substitution_depth += 1
                    elif character == ")" and substitution_depth:
                        substitution_depth -= 1
                    previous_character = character
            if substitution_depth:
                pending += "\n"
                continue
            try:
                legacy_backtick_payloads(pending)
            except AuditInputError:
                pending += "\n"
                continue
            yield start_line, pending
            pending = ""
    if heredoc is not None:
        raise AuditInputError(f"unterminated heredoc at line {start_line}")
    if pending:
        lex_shell(pending)
        legacy_backtick_payloads(pending)
        raise AuditInputError(f"unterminated command substitution at line {start_line}")


def direct_install_segment(source: str, *, shell_syntax: bool = False) -> tuple[str, ...] | None:
    normalized = source.replace("\\\r\n", "").replace("\\\n", "")
    if re.search(r"\bspack\b", normalized) is None or re.search(r"\binstall\b", normalized) is None:
        return None
    if shell_syntax:
        for payload in legacy_backtick_payloads(normalized):
            if direct_install_segment(payload, shell_syntax=True) is not None:
                return lex_shell(normalized)
    tokens = lex_shell(normalized)
    for index, token in enumerate(tokens):
        if token != "spack":
            continue
        for following in tokens[index + 1 :]:
            if following in COMMAND_SEPARATORS:
                break
            if following == "install":
                return tokens
    for index, token in enumerate(tokens):
        executable = PurePosixPath(token).name
        payload: str | None = None
        if executable in {"bash", "dash", "ksh", "sh", "zsh"}:
            for option_index in range(index + 1, len(tokens)):
                option = tokens[option_index]
                if option.startswith("-") and not option.startswith("--") and "c" in option[1:]:
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
        elif executable == "env":
            for option_index in range(index + 1, len(tokens)):
                option = tokens[option_index]
                if option == "-S":
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
                if option.startswith("-S") and len(option) > 2:
                    payload = option[2:]
                    break
                if option.startswith("--split-string="):
                    payload = option.partition("=")[2]
                    break
                if option == "--split-string":
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
        if payload is not None and direct_install_segment(payload, shell_syntax=True) is not None:
            return tokens
        if "$(" in token and token != normalized and direct_install_segment(token, shell_syntax=shell_syntax) is not None:
            return tokens
    return None


def shell_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    function: str | None = None
    controls: list[str] = []
    declaration = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
    for line_number, line in logical_shell_lines(text):
        match = declaration.match(line)
        if match is not None:
            function = match.group(1)
            controls = []
            continue
        stripped = line.strip()
        if function is not None and stripped == "}" and not controls:
            function = None
            continue
        tokens = direct_install_segment(line.lstrip("\t"), shell_syntax=True)
        if tokens is not None:
            yield Candidate(path=path, line=line_number, tokens=tokens, function=function, controls=tuple(controls))
        if re.match(r"^(?:(?:fi|done|esac)\b|[})])", stripped) and controls:
            controls.pop()
        opener = re.match(r"^(if|for|while|until|case|select)\b", stripped)
        if opener is not None:
            controls.append(opener.group(1))
        elif stripped == "{" or stripped == "(":
            controls.append(stripped)
        elif re.search(r"\$\(\s*$", stripped):
            controls.append("$(")
