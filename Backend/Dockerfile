FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock rustfmt.toml ./
COPY src ./src
COPY migrations ./migrations
COPY openapi.yaml ./openapi.yaml
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
# Migrations and the OpenAPI contract are compiled into the binary.
COPY --from=build /app/target/release/openarc-sync-server /usr/local/bin/openarc-sync-server
USER nobody
CMD ["openarc-sync-server", "serve"]
