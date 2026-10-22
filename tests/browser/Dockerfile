# Real Firefox (Mozilla's own build) driven by Selenium, for tests/test_fxa_browser.py
FROM docker.io/library/debian:trixie-slim

ARG GECKODRIVER_VERSION=0.37.1
ARG TARGETARCH

RUN apt-get -q update \
 && apt-get -q install -y --no-install-recommends ca-certificates curl gnupg python3 python3-selenium python3-pytest python3-requests python3-websocket libnss3-tools \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list \
 && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends firefox \
 && case "${TARGETARCH:-$(dpkg --print-architecture)}" in arm64) gd=linux-aarch64 ;; *) gd=linux64 ;; esac \
 && curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/v${GECKODRIVER_VERSION}/geckodriver-v${GECKODRIVER_VERSION}-${gd}.tar.gz" | tar -xz -C /usr/local/bin \
 && apt-get -q purge -y gnupg && apt-get -q autoremove -y && rm -rf /var/lib/apt/lists/* \
 && useradd -m tester

# trust the test reverse proxy's CA (mounted at /caddy-ca/root.crt); libnss3-tools: pk12util
# imports the client certificate of CLIENT_CERT=1 into a profile (tests/test_fxa_browser.py)
COPY policies.json /etc/firefox/policies/policies.json

USER tester
WORKDIR /home/tester
