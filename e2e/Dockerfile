# E2E Test Dockerfile for EctoLiteFS with LiteFS
FROM hexpm/elixir:1.17.3-erlang-26.2.5.4-debian-bookworm-20241016-slim AS build

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Copy mix files first for better caching
COPY mix.exs mix.lock ./
COPY config config

# Fetch dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY e2e/test_app e2e/test_app

# Compile the test app
WORKDIR /app/e2e/test_app
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix compile

# Runtime image
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies including FUSE for LiteFS
RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates fuse3 sqlite3 curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Install LiteFS
COPY --from=flyio/litefs:0.5 /usr/local/bin/litefs /usr/local/bin/litefs

# Create directories
RUN mkdir -p /litefs /var/lib/litefs /app

# Copy Erlang and Elixir runtime from build stage
COPY --from=build /usr/local/lib/erlang /usr/local/lib/erlang
COPY --from=build /usr/local/lib/elixir /usr/local/lib/elixir

# Create symlinks for Erlang and Elixir binaries (Docker COPY doesn't preserve symlinks)
RUN ln -sf /usr/local/lib/erlang/bin/erl /usr/local/bin/erl && \
    ln -sf /usr/local/lib/erlang/bin/erlc /usr/local/bin/erlc && \
    ln -sf /usr/local/lib/elixir/bin/elixir /usr/local/bin/elixir && \
    ln -sf /usr/local/lib/elixir/bin/elixirc /usr/local/bin/elixirc && \
    ln -sf /usr/local/lib/elixir/bin/mix /usr/local/bin/mix && \
    ln -sf /usr/local/lib/elixir/bin/iex /usr/local/bin/iex

# Copy the entire app structure to maintain path dependencies
# test_app uses {:ecto_litefs, path: "../.."} which points to /app from /app/e2e/test_app
COPY --from=build /app/lib /app/lib
COPY --from=build /app/mix.exs /app/mix.exs
COPY --from=build /app/mix.lock /app/mix.lock

# Copy compiled test app
COPY --from=build /app/e2e/test_app/_build /app/e2e/test_app/_build
COPY --from=build /app/e2e/test_app/deps /app/e2e/test_app/deps
COPY --from=build /app/e2e/test_app/lib /app/e2e/test_app/lib
COPY --from=build /app/e2e/test_app/mix.exs /app/e2e/test_app/mix.exs
COPY --from=build /app/e2e/test_app/mix.lock /app/e2e/test_app/mix.lock
COPY --from=build /app/e2e/test_app/config /app/e2e/test_app/config

# Copy hex and rebar from build stage (needed for mix run)
COPY --from=build /root/.mix /root/.mix

WORKDIR /app/e2e/test_app

# Copy startup script
COPY e2e/start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Copy LiteFS config (will be overridden by docker-compose volume mount)
COPY e2e/config/litefs.primary.yml /etc/litefs.yml

# Symlink epmd so it's in PATH
RUN ln -sf /usr/local/lib/erlang/bin/epmd /usr/local/bin/epmd

ENV PATH="/usr/local/lib/erlang/bin:/usr/local/bin:${PATH}"
ENV MIX_ENV=prod
ENV HOME=/root

# LiteFS will be the entrypoint and supervisor
ENTRYPOINT ["litefs", "mount"]
