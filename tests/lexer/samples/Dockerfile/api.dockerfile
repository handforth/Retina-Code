# api.dockerfile — second Dockerfile sample: Python API, multi-stage, ends inside an unterminated heredoc
# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.4.20
ARG APP_USER=api
ARG APP_UID=10001

############################
# Stage 1: dependency build
############################
FROM python:${PYTHON_VERSION}-slim AS deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    UV_LINK_MODE=copy

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        pkg-config

COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /usr/local/bin/uv

WORKDIR /build
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

############################
# Stage 2: tests
############################
FROM deps AS test
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen
RUN <<EOT bash
  set -euo pipefail
  echo "Running tests for $(python --version 2>&1)"
  uv run pytest -q --maxfail=1 \
    --cov=app --cov-report=term-missing \
    -k "not slow and not integration"
  uv run ruff check .
  uv run mypy app/ --strict || { echo "mypy failed with code $?"; exit 1; }
EOT

############################
# Stage 3: runtime
############################
FROM python:${PYTHON_VERSION}-slim AS runtime
ARG APP_USER
ARG APP_UID

RUN groupadd --system --gid ${APP_UID} ${APP_USER} \
 && useradd --system --uid ${APP_UID} --gid ${APP_USER} --home /app --shell /usr/sbin/nologin ${APP_USER}

COPY --from=deps --chown=${APP_USER}:${APP_USER} /build/.venv /app/.venv
COPY --chown=${APP_USER}:${APP_USER} app/ /app/app/

COPY <<-"EOF" /app/gunicorn.conf.py
	import multiprocessing
	bind = "0.0.0.0:8000"
	workers = multiprocessing.cpu_count() * 2 + 1
	worker_class = "uvicorn.workers.UvicornWorker"
	accesslog = "-"
	# The $VARIABLE below is not expanded because the delimiter is quoted
	raw_env = ["HOME=$HOME"]
	EOF

COPY <<EOF /app/.env.defaults
API_TITLE="Example API"
API_VERSION=${PYTHON_VERSION}
LOG_FORMAT='%(asctime)s %(levelname)s %(name)s: %(message)s'
EOF

RUN <<EOF
#!/usr/bin/env python3
import pathlib, sys
p = pathlib.Path("/app/.env.defaults")
print(f"defaults: {p.read_text()!r}", file=sys.stderr)
EOF

ENV PATH="/app/.venv/bin:$PATH" \
    PORT=8000 \
    WEB_CONCURRENCY=2

WORKDIR /app
USER ${APP_USER}

EXPOSE ${PORT}
HEALTHCHECK --interval=15s --timeout=2s CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status == 200 else 1)"

ENTRYPOINT ["gunicorn", "-c", "/app/gunicorn.conf.py"]
CMD ["app.main:app"]

############################
# Stage 4: debug image
############################
FROM runtime AS debug
USER root
RUN pip install --no-cache-dir debugpy ipython \
    && echo 'alias ll="ls -la"' >> /etc/bash.bashrc \
    && echo "export PS1='\u@\h:\w\$ '" >> /etc/bash.bashrc
ENV PYTHONBREAKPOINT=ipdb.set_trace \
    DEBUG=1
USER ${APP_USER}
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "-m", "uvicorn", "app.main:app", "--reload"]

# Edge cases
# A comment with a trailing backslash does not continue \
RUN echo "this RUN is a new instruction"
RUN echo one; \
    echo two; \
    echo three
RUN echo "quote spanning \
continued lines"
RUN echo 'single \
quote across continuation'
RUN echo $((1 + 2)) ${VAR//pattern/replacement} ${#VAR} "${ARR[@]}"
MAINTAINER legacy@example.com
ARG EMPTY_DEFAULT=
ENV KEY1=value1 KEY2="value 2" KEY3='value 3'

############################
# Stage 5: docs
############################
FROM node:20-alpine AS docs
WORKDIR /docs
COPY docs/ ./
RUN <<SH sh -e
npm ci --ignore-scripts
npx --yes @redocly/cli build-docs openapi.yaml -o /docs/index.html
echo 'docs built' >&2
SH
COPY --from=docs /docs/index.html /app/static/docs.html

# Multiple heredocs feeding different commands on one RUN line
RUN <<ONE bash && <<TWO python3
echo "bash heredoc: ${PYTHON_VERSION}"
ONE
print("python heredoc")
TWO

# Exec-form ENTRYPOINT with nested quotes and unicode
ENTRYPOINT ["/bin/sh", "-c", "exec \"$@\" # ✓", "--"]
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop';"]

# Final heredoc never closes
RUN <<NEVER_CLOSED
echo "This heredoc has no terminator."
FROM alpine
RUN echo "these lines are still heredoc body"
CMD ["not", "an", "instruction"]
