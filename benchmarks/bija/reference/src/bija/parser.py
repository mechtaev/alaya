"""Recursive-descent parser for Bija (SPEC.md §5-§8)."""

from __future__ import annotations

from .lexer import BijaSyntaxError, Token, tokenize
from .syntax import (
    Attempt, Binary, Call, Deed, Depth, Each, Effect, Expr, FlagLit, Generation, Give,
    Index, IntLit, ListLit, Logic, Name, Plant, Program, Ripen, Sow, Stmt, TextLit,
    Unary, Utter, VoidLit, When, While, Wither,
)

COMPARISONS = {"=", "<>", "<", "<=", ">", ">="}
SUM_OPS = {"+", "-"}
PRODUCT_OPS = {"*", "/", "%"}


class Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.tokens = tokens
        self.position = 0

    # --- token plumbing --------------------------------------------------

    @property
    def current(self) -> Token:
        return self.tokens[self.position]

    def at(self, kind: str, value: str | None = None) -> bool:
        token = self.current
        return token.kind == kind and (value is None or token.value == value)

    def accept(self, kind: str, value: str | None = None) -> Token | None:
        if self.at(kind, value):
            token = self.current
            self.position += 1
            return token
        return None

    def expect(self, kind: str, value: str | None = None) -> Token:
        token = self.accept(kind, value)
        if token is None:
            wanted = value if value is not None else kind
            found = self.current.value if self.current.kind != "eof" else "end of file"
            raise self.error(f"expected {wanted!r}, found {found!r}")
        return token

    def error(self, message: str) -> BijaSyntaxError:
        return BijaSyntaxError(message, self.current.line, self.current.column)

    # --- program and statements ------------------------------------------

    def parse_program(self) -> Program:
        statements = []
        while not self.at("eof"):
            statements.append(self.parse_statement())
        return Program(tuple(statements))

    def parse_block(self, *terminators: str) -> tuple[Stmt, ...]:
        statements = []
        while not any(self.at("keyword", word) for word in terminators):
            if self.at("eof"):
                wanted = " or ".join(repr(word) for word in terminators)
                raise self.error(f"expected {wanted} before end of file")
            statements.append(self.parse_statement())
        return tuple(statements)

    def parse_statement(self) -> Stmt:
        token = self.current
        if token.kind == "keyword":
            handler = {
                "sow": self.parse_sow,
                "utter": self.parse_utter,
                "when": self.parse_when,
                "while": self.parse_while,
                "each": self.parse_each,
                "deed": self.parse_deed,
                "give": self.parse_give,
                "attempt": self.parse_attempt,
                "wither": self.parse_wither,
                "ripen": self.parse_ripen,
            }.get(token.value)
            if handler is not None:
                return handler()
        return self.parse_plant_or_effect()

    def parse_plant_or_effect(self) -> Stmt:
        token = self.current
        value = self.parse_expression()
        if self.accept("symbol", "=>"):
            sow = self.accept("keyword", "sow") is not None
            target = self.expect("name")
            self.expect("symbol", ".")
            return Plant(value, target.value, sow, line=token.line, column=token.column)
        self.expect("symbol", ".")
        return Effect(value, line=token.line, column=token.column)

    def parse_sow(self) -> Stmt:
        token = self.expect("keyword", "sow")
        target = self.expect("name")
        self.expect("symbol", ".")
        return Sow(target.value, line=token.line, column=token.column)

    def parse_utter(self) -> Stmt:
        token = self.expect("keyword", "utter")
        value = self.parse_expression()
        self.expect("symbol", ".")
        return Utter(value, line=token.line, column=token.column)

    def parse_when(self) -> Stmt:
        token = self.expect("keyword", "when")
        condition = self.parse_expression()
        self.expect("symbol", ":")
        then_block = self.parse_block("otherwise", "end")
        else_block = None
        if self.accept("keyword", "otherwise"):
            self.expect("symbol", ":")
            else_block = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        return When(condition, then_block, else_block, line=token.line, column=token.column)

    def parse_while(self) -> Stmt:
        token = self.expect("keyword", "while")
        condition = self.parse_expression()
        self.expect("symbol", ":")
        body = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        return While(condition, body, line=token.line, column=token.column)

    def parse_each(self) -> Stmt:
        token = self.expect("keyword", "each")
        name = self.expect("name")
        self.expect("keyword", "in")
        sequence = self.parse_expression()
        self.expect("symbol", ":")
        body = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        return Each(name.value, sequence, body, line=token.line, column=token.column)

    def parse_deed(self) -> Stmt:
        token = self.expect("keyword", "deed")
        name = self.expect("name")
        self.expect("symbol", "(")
        parameters: list[str] = []
        if not self.at("symbol", ")"):
            parameters.append(self.expect("name").value)
            while self.accept("symbol", ","):
                parameters.append(self.expect("name").value)
        self.expect("symbol", ")")
        self.expect("symbol", ":")
        body = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        if len(set(parameters)) != len(parameters):
            raise BijaSyntaxError(
                f"deed {name.value} has duplicate parameter names", token.line, token.column
            )
        return Deed(name.value, tuple(parameters), body, line=token.line, column=token.column)

    def parse_give(self) -> Stmt:
        token = self.expect("keyword", "give")
        if self.accept("symbol", "."):
            return Give(None, line=token.line, column=token.column)
        value = self.parse_expression()
        self.expect("symbol", ".")
        return Give(value, line=token.line, column=token.column)

    def parse_attempt(self) -> Stmt:
        token = self.expect("keyword", "attempt")
        self.expect("symbol", ":")
        body = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        return Attempt(body, line=token.line, column=token.column)

    def parse_wither(self) -> Stmt:
        token = self.expect("keyword", "wither")
        self.expect("symbol", ".")
        return Wither(line=token.line, column=token.column)

    def parse_ripen(self) -> Stmt:
        token = self.expect("keyword", "ripen")
        self.expect("keyword", "when")
        condition = self.parse_expression()
        self.expect("symbol", ":")
        body = self.parse_block("end")
        self.expect("keyword", "end")
        self.expect("symbol", ".")
        return Ripen(condition, body, line=token.line, column=token.column)

    # --- expressions ------------------------------------------------------

    def parse_expression(self) -> Expr:
        return self.parse_disjunction()

    def parse_disjunction(self) -> Expr:
        left = self.parse_conjunction()
        while self.at("keyword", "or"):
            token = self.current
            self.position += 1
            right = self.parse_conjunction()
            left = Logic("or", left, right, line=token.line, column=token.column)
        return left

    def parse_conjunction(self) -> Expr:
        left = self.parse_negation()
        while self.at("keyword", "and"):
            token = self.current
            self.position += 1
            right = self.parse_negation()
            left = Logic("and", left, right, line=token.line, column=token.column)
        return left

    def parse_negation(self) -> Expr:
        if self.at("keyword", "not"):
            token = self.current
            self.position += 1
            return Unary("not", self.parse_negation(), line=token.line, column=token.column)
        return self.parse_comparison()

    def parse_comparison(self) -> Expr:
        left = self.parse_sum()
        if self.current.kind == "symbol" and self.current.value in COMPARISONS:
            token = self.current
            self.position += 1
            right = self.parse_sum()
            if self.current.kind == "symbol" and self.current.value in COMPARISONS:
                raise self.error("comparisons do not chain; use parentheses")
            return Binary(token.value, left, right, line=token.line, column=token.column)
        return left

    def parse_sum(self) -> Expr:
        left = self.parse_product()
        while self.current.kind == "symbol" and self.current.value in SUM_OPS:
            token = self.current
            self.position += 1
            right = self.parse_product()
            left = Binary(token.value, left, right, line=token.line, column=token.column)
        return left

    def parse_product(self) -> Expr:
        left = self.parse_unary()
        while self.current.kind == "symbol" and self.current.value in PRODUCT_OPS:
            token = self.current
            self.position += 1
            right = self.parse_unary()
            left = Binary(token.value, left, right, line=token.line, column=token.column)
        return left

    def parse_unary(self) -> Expr:
        # Unary minus is looser than `^`, so -2^2 is -(2^2); see SPEC.md §5.
        if self.at("symbol", "-"):
            token = self.current
            self.position += 1
            return Unary("-", self.parse_unary(), line=token.line, column=token.column)
        return self.parse_power()

    def parse_power(self) -> Expr:
        base = self.parse_base()
        if self.at("symbol", "^"):
            token = self.current
            self.position += 1
            exponent = self.parse_unary()
            return Binary("^", base, exponent, line=token.line, column=token.column)
        return base

    def parse_base(self) -> Expr:
        if self.at("keyword", "depth"):
            token = self.current
            self.position += 1
            name = self.expect("name")
            return Depth(name.value, line=token.line, column=token.column)
        return self.parse_postfix()

    def parse_postfix(self) -> Expr:
        expression = self.parse_primary()
        while True:
            if self.at("symbol", "("):
                token = self.current
                if not isinstance(expression, Name):
                    raise self.error("only a deed name can be called")
                self.position += 1
                arguments: list[Expr] = []
                if not self.at("symbol", ")"):
                    arguments.append(self.parse_expression())
                    while self.accept("symbol", ","):
                        arguments.append(self.parse_expression())
                self.expect("symbol", ")")
                expression = Call(
                    expression.name, tuple(arguments), line=token.line, column=token.column
                )
                continue
            if self.at("symbol", "["):
                token = self.current
                self.position += 1
                index = self.parse_expression()
                self.expect("symbol", "]")
                expression = Index(expression, index, line=token.line, column=token.column)
                continue
            return expression

    def parse_primary(self) -> Expr:
        token = self.current
        if token.kind == "int":
            self.position += 1
            return IntLit(int(token.value), line=token.line, column=token.column)
        if token.kind == "text":
            self.position += 1
            return TextLit(token.value, line=token.line, column=token.column)
        if token.kind == "keyword" and token.value in ("yes", "no"):
            self.position += 1
            return FlagLit(token.value == "yes", line=token.line, column=token.column)
        if token.kind == "keyword" and token.value == "void":
            self.position += 1
            return VoidLit(line=token.line, column=token.column)
        if token.kind == "name":
            self.position += 1
            if self.at("symbol", "@"):
                self.position += 1
                back = self.parse_primary()
                return Generation(token.value, back, line=token.line, column=token.column)
            return Name(token.value, line=token.line, column=token.column)
        if token.kind == "symbol" and token.value == "(":
            self.position += 1
            inner = self.parse_expression()
            self.expect("symbol", ")")
            return inner
        if token.kind == "symbol" and token.value == "[":
            self.position += 1
            elements: list[Expr] = []
            if not self.at("symbol", "]"):
                elements.append(self.parse_expression())
                while self.accept("symbol", ","):
                    elements.append(self.parse_expression())
            self.expect("symbol", "]")
            return ListLit(tuple(elements), line=token.line, column=token.column)
        found = token.value if token.kind != "eof" else "end of file"
        raise self.error(f"expected an expression, found {found!r}")


def parse(source: str) -> Program:
    return Parser(tokenize(source)).parse_program()
