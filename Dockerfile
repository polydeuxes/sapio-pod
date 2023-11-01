FROM node:lts-bullseye-slim as bitcoin_layer

# Install dependencies
RUN apt-get update && apt-get install -y \
wget git build-essential libtool autotools-dev automake pkg-config bsdmainutils python3 gcc curl \
# Cleanup
&& rm -rf /var/lib/apt/lists/* \
# Add user
&& useradd -ms /bin/bash ubitcoin

USER ubitcoin
WORKDIR /home/ubitcoin

# Build Bitcoin
RUN set -eux; \
git clone --depth 1 https://github.com/bitcoin-inquisition/bitcoin.git -b 24.0; \
cp bitcoin/share/rpcauth/rpcauth.py .; \
cd bitcoin; \
cd depends; \
make HOST=$(gcc -dumpmachine) NO_QT=1; \
cd ..; \
./autogen.sh; \
CONFIG_SITE=$PWD/depends/$(gcc -dumpmachine)/share/config.site ./configure \
--with-incompatible-bdb --without-gui --prefix=$HOME --disable-tests --disable-bench --with-libs=no \
--enable-reduce-exports LDFLAGS=-static-libstdc++; \
make -j $(nproc); \
make install; \
rm -rf /home/ubitcoin/bitcoin

# Clear Bitcoin Setup
FROM node:16-bullseye-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
wget \
git \
build-essential \
llvm \
clang \
&& rm -rf /var/lib/apt/lists/*

# Add user
RUN useradd -ms /bin/bash app

USER app
WORKDIR /home/app
ENV RUSTUP_HOME=/home/app/local/rustup \
    CARGO_HOME=/home/app/local/cargo \
    PATH=/home/app/local/cargo/bin:$PATH \
    RUST_VERSION=nightly-2023-05-01

# Install Rust based on the architecture
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) rustArch='x86_64-unknown-linux-gnu'; rustupSha256='3dc5ef50861ee18657f9db2eeb7392f9c2a6c95c90ab41e45ab4ca71476b4338' ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.24.3/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
    rustup --version; \
    cargo --version; \
    rustc --version; \
    rustup target add wasm32-unknown-unknown

# Clone, build and set up sapio language from master branch
RUN set -eux; \
    git clone --depth=1 https://github.com/sapio-lang/sapio; \
    cd sapio; \
    cargo fetch; \
    RUSTFLAGS="-Zgcc-ld=lld" cargo build --release --bin sapio-cli; \
    cp target/release/sapio-cli /home/app/; \
    cd /home/app/sapio/plugin-example; \
    cargo build --target wasm32-unknown-unknown

# Clone and set up sapio-studio from master branch
RUN set -eux; \
    git clone --depth=1 https://github.com/sapio-lang/sapio-studio; \
    cd /home/app/sapio-studio; \
    yarn install; \
    yarn add serve; \
    yarn cache clean; \
    yarn build; \
    yarn build-electron

# Copy configuration and scripts
USER ubitcoin
WORKDIR /home/ubitcoin/.bitcoin
COPY bitcoin.conf .

USER root
WORKDIR /home/root
COPY ./runner.sh .
# Install Electron runtime dependencies and some development tools
RUN apt-get update && apt-get install -y \
gconf-service libasound2 libatk1.0-0 libc6 libcairo2 libcups2 libdbus-1-3 \
libexpat1 libfontconfig1 libgbm-dev libgcc1 libgconf-2-4 libgdk-pixbuf2.0-0 \
libglib2.0-0 libgtk-3-0 libnspr4 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 \
libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 \
libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 ca-certificates \
fonts-liberation libnss3 lsb-release xdg-utils neovim procps && rm -rf /var/lib/apt/lists/*

# Address Electron sandbox issue
RUN chmod 4755 /home/app/sapio-studio/node_modules/electron/dist/chrome-sandbox && \
chown root:root /home/app/sapio-studio/node_modules/electron/dist/chrome-sandbox

# Copy Bitcoin-related data from the previous layer
RUN useradd -ms /bin/bash ubitcoin
USER ubitcoin
COPY --from=bitcoin_layer /home/ubitcoin /home/ubitcoin

# Set up the main entry point
USER root
RUN chmod +x runner.sh && \
chmod +x /bin/bash && \
chmod +x /bin/sh
ENV PATH="/home/ubitcoin/bin:/home/app:$PATH"
ENTRYPOINT ["/bin/sh", "-c"]
CMD ./runner.sh
