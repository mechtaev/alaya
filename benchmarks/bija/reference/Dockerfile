FROM ghcr.io/astral-sh/uv:alpine3.23
WORKDIR /project
COPY . .
RUN uv sync --frozen --no-install-project 2>/dev/null || uv sync
CMD ["uv", "run", "pytest"]
