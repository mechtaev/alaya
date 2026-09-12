"""The Bija runtime, inlined verbatim into every generated Python program.

Values are represented as: int -> int, text -> str, flag -> bool, void -> None,
list -> tuple. Tuples give the immutability SPEC.md §3 requires for free. Because bool is a
subclass of int in Python, every type test here uses `type(v) is ...` rather than isinstance.
"""

from __future__ import annotations

import sys


class BijaError(Exception):
    """A runtime error, per SPEC.md §8.1."""


class _WitherSignal(Exception):
    """Raised by `wither`, caught by the innermost dynamically enclosing `attempt`."""


class _Scope:
    """A scope: seeds (name -> generation stack) and pendings (SPEC.md §4.2, §4.3)."""

    __slots__ = ("parent", "seeds", "pendings")

    def __init__(self, parent):
        self.parent = parent
        self.seeds = {}
        self.pendings = []


# --- type names and rendering (SPEC.md §3) --------------------------------


def _type_name(value):
    if value is None:
        return "void"
    kind = type(value)
    if kind is bool:
        return "flag"
    if kind is int:
        return "int"
    if kind is str:
        return "text"
    if kind is tuple:
        return "list"
    return "value"  # pragma: no cover - unreachable for well-formed programs


def _a(type_name):
    """The indefinite article for a type name, so messages read naturally."""
    return f"an {type_name}" if type_name == "int" else f"a {type_name}"


def _escape(text):
    out = []
    for character in text:
        if character == "\\":
            out.append("\\\\")
        elif character == '"':
            out.append('\\"')
        elif character == "\n":
            out.append("\\n")
        elif character == "\t":
            out.append("\\t")
        else:
            out.append(character)
    return "".join(out)


def _render(value, nested=False):
    if value is None:
        return "void"
    kind = type(value)
    if kind is bool:
        return "yes" if value else "no"
    if kind is int:
        return str(value)
    if kind is str:
        return '"' + _escape(value) + '"' if nested else value
    if kind is tuple:
        return "[" + ", ".join(_render(item, True) for item in value) + "]"
    return str(value)  # pragma: no cover


def _utter(value):
    sys.stdout.write(_render(value) + "\n")


# --- checks ---------------------------------------------------------------


def _int(value, what):
    if type(value) is not int or type(value) is bool:
        raise BijaError(f"{what} must be an int, found {_type_name(value)}")
    return value


def _flag(value, what="a condition"):
    if type(value) is not bool:
        raise BijaError(f"{what} must be a flag, found {_type_name(value)}")
    return value


# --- seeds and scopes (SPEC.md §4) ----------------------------------------


def _find(scope, name):
    while scope is not None:
        stack = scope.seeds.get(name)
        if stack is not None:
            return stack
        scope = scope.parent
    raise BijaError(f"no seed named {name}")


def _sow(scope, name, value):
    if name in scope.seeds:
        raise BijaError(f"seed {name} is already sown in this scope")
    scope.seeds[name] = [value]


def _plant(scope, name, value):
    _find(scope, name).append(value)


def _read(scope, name):
    return _find(scope, name)[-1]


def _read_gen(scope, name, back):
    _int(back, "a generation index")
    if back < 0:
        raise BijaError(f"generation index for {name} must not be negative, found {back}")
    stack = _find(scope, name)
    if back >= len(stack):
        raise BijaError(
            f"seed {name} has {len(stack)} generation(s), so @{back} does not exist"
        )
    return stack[-1 - back]


def _depth(scope, name):
    return len(_find(scope, name))


# --- attempt / wither (SPEC.md §6.8) --------------------------------------


def _mark(scope):
    marks = []
    while scope is not None:
        depths = {name: len(stack) for name, stack in scope.seeds.items()}
        marks.append((scope, depths, len(scope.pendings)))
        scope = scope.parent
    return marks


def _rollback(marks):
    for scope, depths, pending_count in marks:
        for name in list(scope.seeds):
            if name in depths:
                del scope.seeds[name][depths[name]:]
            else:  # pragma: no cover - `sow` binds innermost, so a marked scope gains no names
                del scope.seeds[name]
        del scope.pendings[pending_count:]


def _wither():
    raise _WitherSignal()


# --- ripening (SPEC.md §6.9) ----------------------------------------------


def _ripen(scope, condition, body):
    scope.pendings.append((condition, body))


def _checkpoint(scope):
    pendings = scope.pendings
    index = 0
    while index < len(pendings):
        condition, body = pendings[index]
        if _flag(condition(), "a ripen condition"):
            del pendings[index]
            body()
        else:
            index += 1


# --- operators (SPEC.md §5) -----------------------------------------------


def _add(left, right):
    kinds = (type(left), type(right))
    if kinds == (int, int):
        return left + right
    if kinds == (str, str):
        return left + right
    if kinds == (tuple, tuple):
        return left + right
    raise BijaError(f"cannot add {_type_name(left)} and {_type_name(right)}")


def _sub(left, right):
    return _int(left, "a subtraction operand") - _int(right, "a subtraction operand")


def _mul(left, right):
    return _int(left, "a multiplication operand") * _int(right, "a multiplication operand")


def _div(left, right):
    _int(left, "a division operand")
    if _int(right, "a division operand") == 0:
        raise BijaError("division by zero")
    return left // right


def _mod(left, right):
    _int(left, "a remainder operand")
    if _int(right, "a remainder operand") == 0:
        raise BijaError("remainder by zero")
    return left % right


def _pow(left, right):
    _int(left, "an exponentiation operand")
    if _int(right, "an exponent") < 0:
        raise BijaError(f"exponent must not be negative, found {right}")
    return left ** right


def _neg(value):
    return -_int(value, "a negation operand")


def _not(value):
    return not _flag(value, "an operand of not")


def _eq(left, right):
    kinds = (type(left), type(right))
    if kinds[0] is not kinds[1]:
        return False
    if kinds[0] is tuple:
        if len(left) != len(right):
            return False
        return all(_eq(a, b) for a, b in zip(left, right))
    return left == right


def _ne(left, right):
    return not _eq(left, right)


def _ordered(left, right, what):
    kinds = (type(left), type(right))
    if kinds == (int, int) or kinds == (str, str):
        return
    raise BijaError(
        f"cannot compare {_type_name(left)} with {_type_name(right)} using {what}"
    )


def _lt(left, right):
    _ordered(left, right, "<")
    return left < right


def _le(left, right):
    _ordered(left, right, "<=")
    return left <= right


def _gt(left, right):
    _ordered(left, right, ">")
    return left > right


def _ge(left, right):
    _ordered(left, right, ">=")
    return left >= right


def _index(sequence, index):
    kind = type(sequence)
    if kind is not str and kind is not tuple:
        raise BijaError(f"cannot index {_a(_type_name(sequence))}")
    _int(index, "an index")
    if index < 0:
        raise BijaError(f"index must not be negative, found {index}")
    if index >= len(sequence):
        raise BijaError(f"index {index} is out of range for {_a(_type_name(sequence))} of length {len(sequence)}")
    return sequence[index]


def _mklist(items):
    return tuple(items)


def _elements(value):
    kind = type(value)
    if kind is tuple:
        return value
    if kind is str:
        return tuple(value)
    raise BijaError(f"cannot walk over {_a(_type_name(value))}")


# --- builtin deeds (SPEC.md §9) -------------------------------------------


def _bi_len(value):
    kind = type(value)
    if kind is not str and kind is not tuple:
        raise BijaError(f"len needs a text or a list, found {_type_name(value)}")
    return len(value)


def _bi_push(sequence, value):
    if type(sequence) is not tuple:
        raise BijaError(f"push needs a list, found {_type_name(sequence)}")
    return sequence + (value,)


def _bi_slice(sequence, start, end):
    kind = type(sequence)
    if kind is not str and kind is not tuple:
        raise BijaError(f"slice needs a text or a list, found {_type_name(sequence)}")
    _int(start, "a slice start")
    _int(end, "a slice end")
    if not 0 <= start <= end <= len(sequence):
        raise BijaError(
            f"slice {start}..{end} is out of range for a length of {len(sequence)}"
        )
    return sequence[start:end]


def _bi_join(items, separator):
    if type(items) is not tuple:
        raise BijaError(f"join needs a list, found {_type_name(items)}")
    if type(separator) is not str:
        raise BijaError(f"join needs a text separator, found {_type_name(separator)}")
    for item in items:
        if type(item) is not str:
            raise BijaError(f"join needs a list of texts, found {_a(_type_name(item))}")
    return separator.join(items)


def _bi_chars(value):
    if type(value) is not str:
        raise BijaError(f"chars needs a text, found {_type_name(value)}")
    return tuple(value)


def _bi_text(value):
    return _render(value)


def _bi_number(value):
    if type(value) is not str:
        raise BijaError(f"number needs a text, found {_type_name(value)}")
    body = value[1:] if value.startswith("-") else value
    if body == "" or not all("0" <= c <= "9" for c in body):
        raise BijaError(f"number cannot read {_render(value, True)} as an int")
    return int(value)


def _bi_range(start, end):
    _int(start, "a range start")
    _int(end, "a range end")
    return tuple(range(start, end)) if end > start else ()


def _bi_has(sequence, value):
    kind = type(sequence)
    if kind is tuple:
        return any(_eq(item, value) for item in sequence)
    if kind is str:
        if type(value) is not str:
            raise BijaError(f"has needs a text to look for in a text, found {_type_name(value)}")
        return value in sequence
    raise BijaError(f"has needs a text or a list, found {_type_name(sequence)}")


# --- entry point ----------------------------------------------------------


def _run(main):
    try:
        main()
    except BijaError as error:
        sys.stdout.flush()
        sys.stderr.write(f"error: {error}\n")
        sys.exit(1)
    except _WitherSignal:
        sys.stdout.flush()
        sys.stderr.write("error: wither outside attempt\n")
        sys.exit(1)
    except RecursionError:
        sys.stdout.flush()
        sys.stderr.write("error: recursion too deep\n")
        sys.exit(1)
    sys.stdout.flush()
