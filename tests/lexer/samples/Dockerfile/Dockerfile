# syntax=docker/dockerfile:1.7
# escape=\
# Dockerfile lexer stress: heredocs, line continuations, variables, JSON/shell forms

ARG BASE_IMAGE=node:20-bookworm-slim
ARG BUILD_DATE
ARG VERSION="1.0.0"
ARG PLATFORM=${TARGETPLATFORM:-linux/amd64}

FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS base
LABEL org.opencontainers.image.title="My \"App\"" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created=$BUILD_DATE \
      maintainer='someone@example.com' \
      description="Multi-line label \
continued on the next line without indentation"

ENV NODE_ENV=production \
    APP_HOME=/app \
    PATH="/app/node_modules/.bin:${PATH}" \
    GREETING="Hello, ${USER:-world}!" \
    EMPTY= \
    WITH_SPACES="a b c"
ENV LEGACY_FORM value with spaces after key

WORKDIR ${APP_HOME}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# RUN with shell form and line continuations
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      # comment inside a continued RUN is stripped by Docker
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && echo "installed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/build-info

# RUN with exec (JSON) form
RUN ["/bin/sh", "-c", "echo \"exec form with escaped quotes\" && ls -la"]

# RUN with a heredoc
RUN <<EOF
set -eux
echo "Heredoc line one: $APP_HOME"
for i in 1 2 3; do
  echo "iteration ${i}"
done
cat /etc/os-release | grep -E '^(NAME|VERSION)='
EOF

# Heredoc with a quoted delimiter (no expansion)
RUN <<'SCRIPT'
echo "No expansion here: $HOME ${PATH}"
echo 'single quotes' and `backticks`
SCRIPT

# Heredoc with dash (strip tabs) and custom interpreter
RUN <<-PY python3
	import os, json
	print(json.dumps({"home": os.environ.get("APP_HOME", "/")}))
	PY

# Multiple heredocs on one line
RUN <<FILE1 cat > /tmp/a.txt && <<FILE2 cat > /tmp/b.txt
contents of file one with $VERSION
FILE1
contents of file two
FILE2

# COPY with heredoc creating a file
COPY <<EOF /app/config.json
{
  "version": "${VERSION}",
  "env": "production",
  "features": ["a", "b"]
}
EOF

COPY --chown=node:node --chmod=0755 package*.json ./
COPY --from=builder /src/dist ./dist
COPY ["file with spaces.txt", "dest dir/"]
ADD --checksum=sha256:24454f830cdb571e2c4ad15481119c43b3cafd48dd869a9b2945d1036d1dc68d https://example.com/archive.tar.gz /tmp/
ADD https://github.com/user/repo.git#v1.0.0 /src/repo

RUN --mount=type=cache,target=/root/.npm \
    --mount=type=secret,id=npmrc,target=/root/.npmrc \
    --mount=type=bind,source=package.json,target=package.json \
    npm ci --omit=dev

FROM base AS builder
ARG VERSION
RUN echo "Building version ${VERSION:?VERSION is required}" \
    && test -n "${VERSION}" \
    && echo 'done'

FROM gcr.io/distroless/nodejs20-debian12:nonroot AS runtime
COPY --from=base /app /app
COPY --from=base ["/usr/bin/tini", "/tini"]
USER 65532:65532
EXPOSE 8080/tcp 9090/udp
EXPOSE ${PORT:-3000}
VOLUME ["/data", "/logs"]
VOLUME /cache
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://localhost:8080/healthz', r => process.exit(r.statusCode === 200 ? 0 : 1))"]
ONBUILD RUN echo "onbuild trigger"
ONBUILD COPY . /app/src
ENTRYPOINT ["/tini", "--"]
CMD ["node", "dist/server.js", "--port", "8080"]

# lowercase instructions are valid too
run echo lowercase instruction
from scratch as final
copy --from=runtime / /

# A line ending with a backslash continues even across a comment line
RUN echo "first part" \
# this comment line is skipped by the parser
    && echo "second part"

# Heredoc whose body contains lines that look like Dockerfile instructions
RUN <<BODY
FROM not-a-stage
COPY not-a-copy /
# a hash line inside a heredoc body is content, not a comment
echo "${VERSION}" > /version
BODY

# Heredoc with redirection and a pipe after the marker
RUN <<EOF tee /etc/motd | wc -l
Welcome to the "lexer" image.
Built: ${BUILD_DATE:-unknown}
EOF

# JSON form with escaped characters and a trailing comment-looking string
CMD ["sh", "-c", "echo '# not a comment' && printf '%s\\n' \"$HOME\""]

# Instruction keywords used as arguments
RUN echo FROM RUN COPY ENV ARG LABEL
LABEL "com.example.quoted-key"="value" multi.word="a b c"

# Line continuation followed by an empty line (deprecated but accepted)
RUN echo "before blank" \

    && echo "after blank"

# Escaped dollar and backslash-escaped quote in ENV
ENV PRICE=\$5 QUOTE=\"literal\" PATHS=/a:/b:$PATH

# Unusual variable forms
ENV A=${B:+alternate} C=${D:-default} E=$F G=\$NOT_EXPANDED H='$also_not'
ARG UNTERMINATED="this quote never closes
RUN echo after-unterminated
