"""Compiles Bija to standalone Python source (SPEC.md §5-§9)."""

from __future__ import annotations

from pathlib import Path

from .lexer import BijaSyntaxError
from .parser import parse
from .syntax import (
    Attempt, Binary, Call, Deed, Depth, Each, Effect, Expr, FlagLit, Generation, Give,
    Index, IntLit, ListLit, Logic, Name, Plant, Program, Ripen, Sow, Stmt, TextLit,
    Unary, Utter, VoidLit, When, While, Wither,
)

BUILTINS = {
    "len": ("_bi_len", 1),
    "push": ("_bi_push", 2),
    "slice": ("_bi_slice", 3),
    "join": ("_bi_join", 2),
    "chars": ("_bi_chars", 1),
    "text": ("_bi_text", 1),
    "number": ("_bi_number", 1),
    "range": ("_bi_range", 2),
    "has": ("_bi_has", 2),
}

BINARY_HELPERS = {
    "+": "_add", "-": "_sub", "*": "_mul", "/": "_div", "%": "_mod", "^": "_pow",
    "=": "_eq", "<>": "_ne", "<": "_lt", "<=": "_le", ">": "_gt", ">=": "_ge",
}

RUNTIME_SOURCE = (Path(__file__).with_name("runtime.py")).read_text(encoding="utf-8")


class Compiler:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.deeds: dict[str, int] = {}
        self.counter = 0

    # --- helpers ---------------------------------------------------------

    def fresh(self, prefix: str) -> str:
        self.counter += 1
        return f"{prefix}{self.counter}"

    def emit(self, indent: int, line: str) -> None:
        self.lines.append("    " * indent + line)

    @staticmethod
    def fail(message: str, node) -> BijaSyntaxError:
        return BijaSyntaxError(message, node.line, node.column)

    # --- entry -----------------------------------------------------------

    def compile_program(self, program: Program, embed: bool = True) -> str:
        for statement in program.statements:
            if isinstance(statement, Deed):
                if statement.name in BUILTINS:
                    raise self.fail(
                        f"{statement.name} is a builtin deed and cannot be redefined", statement
                    )
                if statement.name in self.deeds:
                    raise self.fail(f"deed {statement.name} is declared twice", statement)
                self.deeds[statement.name] = len(statement.parameters)

        self.check_block(program.statements, in_deed=False, in_ripen=False, top_level=True)

        for statement in program.statements:
            if isinstance(statement, Deed):
                self.compile_deed(statement)

        scope = self.fresh("_s")
        self.emit(0, "def _main():")
        self.emit(1, f"{scope} = _Scope(None)")
        body = [s for s in program.statements if not isinstance(s, Deed)]
        self.compile_block(body, scope, 1)
        self.emit(0, "")
        self.emit(0, "_run(_main)")
        body = "\n".join(self.lines) + "\n"
        return RUNTIME_SOURCE + "\n\n" + body if embed else body

    # --- static checks (SPEC.md §8.1) ------------------------------------

    def check_block(self, statements, *, in_deed: bool, in_ripen: bool, top_level: bool) -> None:
        for statement in statements:
            self.check_statement(statement, in_deed=in_deed, in_ripen=in_ripen,
                                 top_level=top_level)

    def check_statement(self, statement: Stmt, *, in_deed: bool, in_ripen: bool,
                        top_level: bool) -> None:
        nested = dict(in_deed=in_deed, in_ripen=in_ripen, top_level=False)
        if isinstance(statement, Deed):
            if not top_level:
                raise self.fail("a deed may only be declared at the top level", statement)
            self.check_block(statement.body, in_deed=True, in_ripen=False, top_level=False)
        elif isinstance(statement, Give):
            if not in_deed:
                raise self.fail("give is only allowed inside a deed", statement)
            if in_ripen:
                raise self.fail("a ripen block cannot give", statement)
            if statement.value is not None:
                self.check_expression(statement.value)
        elif isinstance(statement, Ripen):
            self.check_expression(statement.condition)
            self.check_block(statement.body, in_deed=in_deed, in_ripen=True, top_level=False)
        elif isinstance(statement, When):
            self.check_expression(statement.condition)
            self.check_block(statement.then_block, **nested)
            if statement.else_block is not None:
                self.check_block(statement.else_block, **nested)
        elif isinstance(statement, While):
            self.check_expression(statement.condition)
            self.check_block(statement.body, **nested)
        elif isinstance(statement, Each):
            self.check_expression(statement.sequence)
            self.check_block(statement.body, **nested)
        elif isinstance(statement, Attempt):
            self.check_block(statement.body, **nested)
        elif isinstance(statement, Plant):
            self.check_expression(statement.value)
        elif isinstance(statement, (Utter, Effect)):
            self.check_expression(statement.value)

    def check_expression(self, expression: Expr) -> None:
        if isinstance(expression, Call):
            if expression.callee in BUILTINS:
                arity = BUILTINS[expression.callee][1]
            elif expression.callee in self.deeds:
                arity = self.deeds[expression.callee]
            else:
                raise self.fail(f"no deed named {expression.callee}", expression)
            if len(expression.arguments) != arity:
                raise self.fail(
                    f"{expression.callee} takes {arity} argument(s), "
                    f"found {len(expression.arguments)}",
                    expression,
                )
            for argument in expression.arguments:
                self.check_expression(argument)
        elif isinstance(expression, (Binary, Logic)):
            self.check_expression(expression.left)
            self.check_expression(expression.right)
        elif isinstance(expression, Unary):
            self.check_expression(expression.operand)
        elif isinstance(expression, Index):
            self.check_expression(expression.sequence)
            self.check_expression(expression.index)
        elif isinstance(expression, ListLit):
            for element in expression.elements:
                self.check_expression(element)
        elif isinstance(expression, Generation):
            self.check_expression(expression.back)

    # --- statements -------------------------------------------------------

    def compile_deed(self, deed: Deed) -> None:
        parameters = [f"_p{index}" for index in range(len(deed.parameters))]
        scope = self.fresh("_s")
        self.emit(0, f"def _deed_{deed.name}({', '.join(parameters)}):")
        self.emit(1, f"{scope} = _Scope(None)")
        for name, parameter in zip(deed.parameters, parameters):
            self.emit(1, f"_sow({scope}, {name!r}, {parameter})")
        self.compile_block(deed.body, scope, 1)
        self.emit(1, "return None")
        self.emit(0, "")

    def compile_block(self, statements, scope: str, indent: int) -> None:
        checkpoints = any(isinstance(s, Ripen) for s in statements)
        emitted = False
        for statement in statements:
            self.compile_statement(statement, scope, indent)
            if checkpoints:
                self.emit(indent, f"_checkpoint({scope})")
            emitted = True
        if not emitted:
            self.emit(indent, "pass")

    def compile_statement(self, statement: Stmt, scope: str, indent: int) -> None:
        if isinstance(statement, Plant):
            value = self.expression(statement.value, scope)
            helper = "_sow" if statement.sow else "_plant"
            self.emit(indent, f"{helper}({scope}, {statement.target!r}, {value})")

        elif isinstance(statement, Sow):
            self.emit(indent, f"_sow({scope}, {statement.target!r}, None)")

        elif isinstance(statement, Utter):
            self.emit(indent, f"_utter({self.expression(statement.value, scope)})")

        elif isinstance(statement, Effect):
            self.emit(indent, self.expression(statement.value, scope))

        elif isinstance(statement, When):
            condition = self.expression(statement.condition, scope)
            self.emit(indent, f"if _flag({condition}, 'a when condition'):")
            inner = self.fresh("_s")
            self.emit(indent + 1, f"{inner} = _Scope({scope})")
            self.compile_block(statement.then_block, inner, indent + 1)
            if statement.else_block is not None:
                self.emit(indent, "else:")
                inner = self.fresh("_s")
                self.emit(indent + 1, f"{inner} = _Scope({scope})")
                self.compile_block(statement.else_block, inner, indent + 1)

        elif isinstance(statement, While):
            condition = self.expression(statement.condition, scope)
            self.emit(indent, f"while _flag({condition}, 'a while condition'):")
            inner = self.fresh("_s")
            self.emit(indent + 1, f"{inner} = _Scope({scope})")
            self.compile_block(statement.body, inner, indent + 1)

        elif isinstance(statement, Each):
            sequence = self.expression(statement.sequence, scope)
            item = self.fresh("_it")
            self.emit(indent, f"for {item} in _elements({sequence}):")
            inner = self.fresh("_s")
            self.emit(indent + 1, f"{inner} = _Scope({scope})")
            self.emit(indent + 1, f"_sow({inner}, {statement.name!r}, {item})")
            self.compile_block(statement.body, inner, indent + 1)

        elif isinstance(statement, Give):
            value = "None" if statement.value is None else self.expression(statement.value, scope)
            self.emit(indent, f"return {value}")

        elif isinstance(statement, Attempt):
            mark = self.fresh("_m")
            self.emit(indent, f"{mark} = _mark({scope})")
            self.emit(indent, "try:")
            inner = self.fresh("_s")
            self.emit(indent + 1, f"{inner} = _Scope({scope})")
            self.compile_block(statement.body, inner, indent + 1)
            self.emit(indent, "except _WitherSignal:")
            self.emit(indent + 1, f"_rollback({mark})")

        elif isinstance(statement, Wither):
            self.emit(indent, "_wither()")

        elif isinstance(statement, Ripen):
            # The closures bind the scope by default argument, so a loop that rebinds the
            # scope variable cannot change which scope a registered pending belongs to.
            name = self.fresh("_rip")
            self.emit(indent, f"def {name}_cond({scope}={scope}):")
            self.emit(indent + 1, f"return {self.expression(statement.condition, scope)}")
            self.emit(indent, f"def {name}_body({scope}={scope}):")
            inner = self.fresh("_s")
            self.emit(indent + 1, f"{inner} = _Scope({scope})")
            self.compile_block(statement.body, inner, indent + 1)
            self.emit(indent, f"_ripen({scope}, {name}_cond, {name}_body)")

        else:  # pragma: no cover - every statement kind is handled above
            raise AssertionError(f"unknown statement {statement!r}")

    # --- expressions ------------------------------------------------------

    def expression(self, expression: Expr, scope: str) -> str:
        if isinstance(expression, IntLit):
            return repr(expression.value)
        if isinstance(expression, TextLit):
            return repr(expression.value)
        if isinstance(expression, FlagLit):
            return "True" if expression.value else "False"
        if isinstance(expression, VoidLit):
            return "None"
        if isinstance(expression, Name):
            return f"_read({scope}, {expression.name!r})"
        if isinstance(expression, Generation):
            back = self.expression(expression.back, scope)
            return f"_read_gen({scope}, {expression.name!r}, {back})"
        if isinstance(expression, Depth):
            return f"_depth({scope}, {expression.name!r})"
        if isinstance(expression, ListLit):
            elements = ", ".join(self.expression(e, scope) for e in expression.elements)
            return f"_mklist([{elements}])"
        if isinstance(expression, Unary):
            operand = self.expression(expression.operand, scope)
            return f"_neg({operand})" if expression.op == "-" else f"_not({operand})"
        if isinstance(expression, Binary):
            left = self.expression(expression.left, scope)
            right = self.expression(expression.right, scope)
            return f"{BINARY_HELPERS[expression.op]}({left}, {right})"
        if isinstance(expression, Logic):
            left = self.expression(expression.left, scope)
            right = self.expression(expression.right, scope)
            operator = "and" if expression.op == "and" else "or"
            what = f"an operand of {expression.op}"
            return f"(_flag({left}, {what!r}) {operator} _flag({right}, {what!r}))"
        if isinstance(expression, Index):
            sequence = self.expression(expression.sequence, scope)
            index = self.expression(expression.index, scope)
            return f"_index({sequence}, {index})"
        if isinstance(expression, Call):
            arguments = ", ".join(self.expression(a, scope) for a in expression.arguments)
            if expression.callee in BUILTINS:
                return f"{BUILTINS[expression.callee][0]}({arguments})"
            return f"_deed_{expression.callee}({arguments})"
        raise AssertionError(f"unknown expression {expression!r}")  # pragma: no cover


def compile_source(source: str, embed: bool = True) -> str:
    """Compiles Bija source to Python source.

    With `embed`, the runtime is prepended and the result is standalone, which is what
    `bija build` promises. Without it, the result expects the names of `bija.runtime` to be in
    scope already — how `bija run` executes a program.
    """
    return Compiler().compile_program(parse(source), embed=embed)
