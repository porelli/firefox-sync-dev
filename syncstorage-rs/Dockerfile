# Declare ARG globally for reusability
ARG TARGETPLATFORM=linux/amd64
ARG BUILDPLATFORM=linux/amd64

# NOTE: Ensure builder's Rust version matches CI's in .circleci/config.yml
# Stage: Base Image
FROM --platform=$BUILDPLATFORM docker.io/lukemathwalker/cargo-chef:0.1.67-rust-1.78-bullseye AS chef
WORKDIR /app

# Stage: Planner
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Stage: Cacher
FROM chef AS cacher
ARG TARGETPLATFORM

# cmake is required to build grpcio-sys for Spanner builds
RUN \
    apt-get -q update && \
    apt-get -q install -y --no-install-recommends libmariadb-dev-compat libmariadb-dev cmake

COPY --from=planner /app/recipe.json recipe.json
# Dynamically determine the target triple and cross compile when needed
RUN TARGET=$(rustc --print target-list | grep -m1 `uname -m`-unknown-linux-gnu) && \
    cargo chef cook --release --target $TARGET --recipe-path recipe.json

# Stage: Builder
FROM chef AS builder
ARG TARGETPLATFORM
ARG DATABASE_BACKEND=spanner

COPY . /app
COPY --from=cacher /app/target /app/target
COPY --from=cacher $CARGO_HOME /app/$CARGO_HOME

RUN \
    # Fetch and load the MySQL public key
    wget -qO- https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 > /etc/apt/trusted.gpg.d/mysql.asc && \
    echo "deb https://repo.mysql.com/apt/debian/ bullseye mysql-8.0" >> /etc/apt/sources.list && \
    # mysql_pubkey.asc from:
    # https://dev.mysql.com/doc/refman/8.0/en/checking-gpg-signature.html
    # related:
    # https://dev.mysql.com/doc/mysql-apt-repo-quick-guide/en/#repo-qg-apt-repo-manual-setup
    apt-get -q update && \
    apt-get -q install -y --no-install-recommends libmariadb-dev-compat libmariadb-dev cmake golang-go python3-dev python3-pip python3-setuptools python3-wheel && \
    pip3 install -r requirements.txt && \
    rm -rf /var/lib/apt/lists/*

ENV PATH=$PATH:/root/.cargo/bin

RUN \
    TARGET=$(rustc --print target-list | grep -m1 `uname -m`-unknown-linux-gnu) && \
    cargo --version && \
    rustc --version && \
    cargo install --path ./syncserver --target $TARGET --no-default-features --features=syncstorage-db/$DATABASE_BACKEND --features=py_verifier --locked --root /app && \
    if [ "$DATABASE_BACKEND" = "spanner" ]; then \
        cargo install --path ./syncstorage-spanner --locked --root /app --bin purge_ttl; \
    fi

# Final Stage: Runtime
FROM docker.io/library/debian:bullseye-slim
WORKDIR /app
COPY --from=builder /app/requirements.txt /app

# Due to a build error that occurs with the Python cryptography package, we
# have to set this env var to prevent the cryptography package from building
# with Rust. See this link for more information:
# https://pythonshowcase.com/question/problem-installing-cryptography-on-raspberry-pi
ENV CRYPTOGRAPHY_DONT_BUILD_RUST=1

RUN \
    groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --home /app --create-home app && \
    apt-get -q update && apt-get -qy install gnupg ca-certificates wget && \
    echo "deb https://repo.mysql.com/apt/debian/ bullseye mysql-8.0" >> /etc/apt/sources.list && \
    wget -qO- https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 > /etc/apt/trusted.gpg.d/mysql.asc && \
    # update again now that we trust repo.mysql.com
    apt-get -q update && \
    apt-get -q install -y build-essential libmariadb-dev-compat libmariadb-dev libssl-dev libffi-dev libcurl4 python3-dev python3-pip python3-setuptools python3-wheel cargo curl jq && \
    # The python3-cryptography debian package installs version 2.6.1, but we
    # we want to use the version specified in requirements.txt. To do this,
    # we have to remove the python3-cryptography package here.
    apt-get -q remove -y python3-cryptography && \
    pip3 install -r /app/requirements.txt && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/bin /app/bin
COPY --from=builder /app/syncserver/version.json /app
COPY --from=builder /app/tools/spanner /app/tools/spanner
COPY --from=builder /app/tools/integration_tests /app/tools/integration_tests
COPY --from=builder /app/tools/tokenserver /app/tools/tokenserver
COPY --from=builder /app/scripts/prepare-spanner.sh /app/scripts/prepare-spanner.sh
COPY --from=builder /app/scripts/start_mock_fxa_server.sh /app/scripts/start_mock_fxa_server.sh
COPY --from=builder /app/syncstorage-spanner/src/schema.ddl /app/schema.ddl

RUN chmod +x /app/scripts/prepare-spanner.sh
RUN pip3 install -r /app/tools/integration_tests/requirements.txt
RUN pip3 install -r /app/tools/tokenserver/requirements.txt

USER app:app

ENTRYPOINT ["/app/bin/syncserver"]
