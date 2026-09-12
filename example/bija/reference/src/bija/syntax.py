"""Abstract syntax for Bija (SPEC.md §5-§8)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Union


@dataclass(frozen=True)
class Node:
    line: int = field(default=0, kw_only=True)
    column: int = field(default=0, kw_only=True)


# --- expressions ---------------------------------------------------------


@dataclass(frozen=True)
class IntLit(Node):
    value: int


@dataclass(frozen=True)
class TextLit(Node):
    value: str


@dataclass(frozen=True)
class FlagLit(Node):
    value: bool


@dataclass(frozen=True)
class VoidLit(Node):
    pass


@dataclass(frozen=True)
class Name(Node):
    name: str


@dataclass(frozen=True)
class Generation(Node):
    name: str
    back: "Expr"


@dataclass(frozen=True)
class Depth(Node):
    name: str


@dataclass(frozen=True)
class ListLit(Node):
    elements: tuple["Expr", ...]


@dataclass(frozen=True)
class Unary(Node):
    op: str
    operand: "Expr"


@dataclass(frozen=True)
class Binary(Node):
    op: str
    left: "Expr"
    right: "Expr"


@dataclass(frozen=True)
class Logic(Node):
    op: str  # "and" | "or"
    left: "Expr"
    right: "Expr"


@dataclass(frozen=True)
class Index(Node):
    sequence: "Expr"
    index: "Expr"


@dataclass(frozen=True)
class Call(Node):
    callee: str
    arguments: tuple["Expr", ...]


Expr = Union[
    IntLit, TextLit, FlagLit, VoidLit, Name, Generation, Depth,
    ListLit, Unary, Binary, Logic, Index, Call,
]


# --- statements ----------------------------------------------------------


@dataclass(frozen=True)
class Plant(Node):
    value: Expr
    target: str
    sow: bool


@dataclass(frozen=True)
class Sow(Node):
    target: str


@dataclass(frozen=True)
class Utter(Node):
    value: Expr


@dataclass(frozen=True)
class When(Node):
    condition: Expr
    then_block: tuple["Stmt", ...]
    else_block: tuple["Stmt", ...] | None


@dataclass(frozen=True)
class While(Node):
    condition: Expr
    body: tuple["Stmt", ...]


@dataclass(frozen=True)
class Each(Node):
    name: str
    sequence: Expr
    body: tuple["Stmt", ...]


@dataclass(frozen=True)
class Deed(Node):
    name: str
    parameters: tuple[str, ...]
    body: tuple["Stmt", ...]


@dataclass(frozen=True)
class Give(Node):
    value: Expr | None


@dataclass(frozen=True)
class Attempt(Node):
    body: tuple["Stmt", ...]


@dataclass(frozen=True)
class Wither(Node):
    pass


@dataclass(frozen=True)
class Ripen(Node):
    condition: Expr
    body: tuple["Stmt", ...]


@dataclass(frozen=True)
class Effect(Node):
    value: Expr


Stmt = Union[Plant, Sow, Utter, When, While, Each, Deed, Give, Attempt, Wither, Ripen, Effect]


@dataclass(frozen=True)
class Program(Node):
    statements: tuple[Stmt, ...]
