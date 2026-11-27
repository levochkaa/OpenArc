# Build from the repository root: the server shares Core/openarc-sync-protocol with the apps.
#   docker build -f Backend/Dockerfile .
FROM rust:1-bookworm AS build
WORKDIR /app
COPY Core/openarc-sync-protocol ./Core/openarc-sync-protocol
COPY Backend/Cargo.toml Backend/Cargo.lock Backend/rustfmt.toml ./Backend/
COPY Backend/src ./Backend/src
COPY Backend/migrations ./Backend/migrations
COPY Backend/openapi.yaml ./Backend/openapi.yaml
WORKDIR /app/Backend
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
# Migrations and the OpenAPI contract are compiled into the binary.
COPY --from=build /app/Backend/target/release/openarc-sync-server /usr/local/bin/openarc-sync-server
USER nobody
CMD ["openarc-sync-server", "serve"]
