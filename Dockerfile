# Stage 1: Build
FROM haskell:9.10.3-slim-bookworm AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libpq-dev \
      zlib1g-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Step 1: Copy dependency files only (cached unless deps change)
COPY package.yaml cabal.project backend.cabal ./

RUN cabal update && \
    cabal build --only-dependencies -j

# Step 2: Copy source and build
COPY app/ app/
COPY src/ src/
COPY config/ config/

RUN cabal build -j && \
    cp "$(cabal list-bin backend)" /build/backend-bin

# Stage 2: Runtime
FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/homeaccounting/backend"

ARG APP_COMMIT_HASH=dev
ENV APP_COMMIT_HASH=${APP_COMMIT_HASH}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libpq5 \
      libgmp10 \
      zlib1g \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/backend-bin ./backend
COPY --from=builder /build/config/ ./config/

ENV CONFIG_FILE=config/prod.yaml

EXPOSE 8080

CMD ["./backend"]
