"""Bija: a small imperative language whose variables remember every generation."""

from .compiler import compile_source
from .lexer import BijaSyntaxError

__all__ = ["compile_source", "BijaSyntaxError"]
__version__ = "1.0.0"
