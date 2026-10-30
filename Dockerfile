# The swarm as an Elixir release. Built by .github/workflows/ci.yml and pushed to GHCR; runs as a
# StatefulSet (see k8s/). Same Elixir/OTP as development.

FROM hexpm/elixir:1.20.3-erlang-28.5.0.5-debian-bookworm-20260824-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so code changes don't rebuild them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY lib lib
COPY config/runtime.exs config/
RUN mix release

FROM debian:bookworm-20260824-slim

# ca-certificates: the NetRTS server is HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
RUN useradd --create-home swarm && mkdir /data && chown swarm /data

WORKDIR /app
COPY --from=build --chown=swarm /app/_build/prod/rel/swarm ./
USER swarm

# The ra log, on the pod's volume. Node name, cookie, peers and the API key come from the
# StatefulSet's environment.
ENV SWARM_DATA_DIR=/data
CMD ["/app/bin/swarm", "start"]
