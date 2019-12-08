FROM node:8.15-slim as builder

ARG STANDALONE

RUN mkdir /opt/local && apt-get update && apt-get install -y --no-install-recommends git \
    $([ -n "$STANDALONE" ] || echo "autoconf automake build-essential gettext libtool libgmp-dev \
                                     libsqlite3-dev python python3 python3-mako wget zlib1g-dev")

ARG TESTRUNNER

ENV LIGHTNINGD_VERSION=v0.7.3
ENV LIGHTNINGD_PGP_KEY=30DE693AE0DE9E37B3E7EB6BBFF0F67810C1EED1

RUN [ -n "$STANDALONE" ] || \
    (git clone https://github.com/ElementsProject/lightning.git /opt/lightningd \
    && cd /opt/lightningd \
    && gpg --keyserver keyserver.ubuntu.com --recv-keys "$LIGHTNINGD_PGP_KEY" \
    && git verify-tag $LIGHTNINGD_VERSION \
    && git checkout $LIGHTNINGD_VERSION \
    && DEVELOPER=$TESTRUNNER ./configure --prefix=./target \
    && make -j3 \
    && make install \
    && rm -r target/share \
    && mv -f target/* /opt/local/)

ENV BEYONDCOIN_VERSION 0.16.3
ENV BEYONDCOIN_FILENAME beyondcoin-$BEYONDCOIN_VERSION-x86_64-linux-gnu.tar.gz
ENV BEYONDCOIN_URL https://beyondcoin.io/bin/beyondcoin-core-$BEYONDCOIN_VERSION/$BEYONDCOIN_FILENAME
ENV BEYONDCOIN_SHA256 732cc96ae2e5e25603edf76b8c8af976fe518dd925f7e674710c6c8ee5189204
ENV BEYONDCOIN_ASC_URL https://beyondcoin.io/bin/beyondcoin-core-$BEYONDCOIN_VERSION/SHA256SUMS.asc
ENV BEYONDCOIN_PGP_KEY 01EA5486DE18A882D4C2684590C8019E36C2E964
RUN [ -n "$STANDALONE" ] || \
    (mkdir /opt/beyondcoin && cd /opt/beyondcoin \
    && wget -qO "$BEYONDCOIN_FILENAME" "$BEYONDCOIN_URL" \
    && echo "$BEYONDCOIN_SHA256 $BEYONDCOIN_FILENAME" | sha256sum -c - \
    && gpg --keyserver keyserver.ubuntu.com --recv-keys "$BEYONDCOIN_PGP_KEY" \
    && wget -qO beyondcoin.asc "$BEYONDCOIN_ASC_URL" \
    && gpg --verify beyondcoin.asc \
    && cat beyondcoin.asc | grep "$BEYONDCOIN_FILENAME" | sha256sum -c - \
    && BD=beyondcoin-$BEYONDCOIN_VERSION/bin \
    && tar -xzvf "$BEYONDCOIN_FILENAME" $BD/beyondcoind $BD/beyondcoin-cli --strip-components=1 \
    && mv bin/* /opt/local/bin/)

WORKDIR /opt/charged

COPY package.json npm-shrinkwrap.json ./
RUN npm install \
   && test -n "$TESTRUNNER" || { \
      cp -r node_modules node_modules.dev \
      && npm prune --production \
      && mv -f node_modules node_modules.prod \
      && mv -f node_modules.dev node_modules; }

COPY . .
RUN npm run dist \
    && rm -rf src \
    && test -n "$TESTRUNNER" || (rm -rf test node_modules && mv -f node_modules.prod node_modules)

FROM node:8.15-slim

WORKDIR /opt/charged
ARG TESTRUNNER
ENV HOME /tmp
ENV NODE_ENV production
ARG STANDALONE
ENV STANDALONE=$STANDALONE

RUN apt-get update \
    && apt-get install -y --no-install-recommends inotify-tools \
    && ([ -n "$STANDALONE" ] || apt-get install -y --no-install-recommends libgmp-dev libsqlite3-dev) \
    && ([ -z "$TESTRUNNER" ] || apt-get install -y --no-install-recommends jq procps) \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /opt/charged/bin/charged /usr/bin/charged \
    && mkdir /data \
    && ln -s /data/lightning /tmp/.lightning

COPY --from=builder /opt/local /usr/local
COPY --from=builder /opt/charged /opt/charged

CMD [ "bin/docker-entrypoint.sh" ]
EXPOSE 9112 9735
