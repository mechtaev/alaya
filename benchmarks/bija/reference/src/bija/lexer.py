"""Tokenizer for Bija (SPEC.md §2)."""

from __future__ import annotations

from dataclasses import dataclass

KEYWORDS = frozenset(
    """and attempt deed depth each end give in no not or otherwise ripen sow
    utter void when while wither yes""".split()
)

# Longest match first.
SYMBOLS = [
    "=>", "<>", "<=", ">=",
    "@", ".", ":", ",", "(", ")", "[", "]",
    "+", "-", "*", "/", "%", "^", "=", "<", ">",
]

ESCAPES = {"\\": "\\", '"': '"', "n": "\n", "t": "\t"}


class BijaSyntaxError(Exception):
    """A lexical or syntactic error, carrying a source position."""

    def __init__(self, message: str, line: int, column: int) -> None:
        super().__init__(message)
        self.message = message
        self.line = line
        self.column = column

    def report(self, filename: str) -> str:
        return f"{filename}:{self.line}:{self.column}: error: {self.message}"


@dataclass(frozen=True)
class Token:
    kind: str  # "int" | "text" | "name" | "keyword" | "symbol" | "eof"
    value: str
    line: int
    column: int

    def __str__(self) -> str:  # pragma: no cover - diagnostics only
        return self.value or self.kind


def _is_name_start(c: str) -> bool:
    return c == "_" or ("a" <= c <= "z")


def _is_name_part(c: str) -> bool:
    return c == "_" or c.isascii() and (c.isalpha() or c.isdigit())


def tokenize(source: str) -> list[Token]:
    tokens: list[Token] = []
    i, line, column = 0, 1, 1
    n = len(source)

    def advance(count: int) -> None:
        nonlocal i, line, column
        for _ in range(count):
            if source[i] == "\n":
                line += 1
                column = 1
            else:
                column += 1
            i += 1

    while i < n:
        c = source[i]
        if c in " \t\r\n":
            advance(1)
            continue
        if source.startswith("~~", i):
            while i < n and source[i] != "\n":
                advance(1)
            continue

        start_line, start_column = line, column

        if c.isdigit():
            j = i
            while j < n and source[j].isdigit():
                j += 1
            digits = source[i:j]
            advance(j - i)
            if i < n and _is_name_start(source[i]):
                raise BijaSyntaxError(
                    "a digit may not be followed by a letter", start_line, start_column
                )
            tokens.append(Token("int", digits, start_line, start_column))
            continue

        if _is_name_start(c):
            j = i
            while j < n and _is_name_part(source[j]):
                j += 1
            word = source[i:j]
            advance(j - i)
            kind = "keyword" if word in KEYWORDS else "name"
            tokens.append(Token(kind, word, start_line, start_column))
            continue

        if c.isalpha():
            raise BijaSyntaxError(
                f"identifiers must start with a lowercase letter or underscore, got {c!r}",
                start_line,
                start_column,
            )

        if c == '"':
            advance(1)
            pieces: list[str] = []
            while True:
                if i >= n:
                    raise BijaSyntaxError("unterminated text literal", start_line, start_column)
                ch = source[i]
                if ch == '"':
                    advance(1)
                    break
                if ch == "\\":
                    if i + 1 >= n:
                        raise BijaSyntaxError(
                            "unterminated text literal", start_line, start_column
                        )
                    esc = source[i + 1]
                    if esc not in ESCAPES:
                        raise BijaSyntaxError(f"unknown escape \\{esc}", line, column)
                    pieces.append(ESCAPES[esc])
                    advance(2)
                    continue
                pieces.append(ch)
                advance(1)
            tokens.append(Token("text", "".join(pieces), start_line, start_column))
            continue

        for symbol in SYMBOLS:
            if source.startswith(symbol, i):
                advance(len(symbol))
                tokens.append(Token("symbol", symbol, start_line, start_column))
                break
        else:
            raise BijaSyntaxError(f"unexpected character {c!r}", start_line, start_column)

    tokens.append(Token("eof", "", line, column))
    return tokens
