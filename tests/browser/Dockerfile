# Real Firefox (Mozilla's own build) driven by Selenium, for tests/test_fxa_browser.py
FROM docker.io/library/debian:stable-slim

# empty: geckodriver's latest release (the Firefox is Mozilla's newest too)
ARG GECKODRIVER_VERSION=
ARG TARGETARCH

RUN apt-get -q update \
 && apt-get -q install -y --no-install-recommends ca-certificates curl gnupg python3 python3-selenium python3-pytest python3-requests python3-websocket \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list \
 && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends firefox \
 && case "${TARGETARCH:-$(dpkg --print-architecture)}" in arm64) gd=linux-aarch64 ;; *) gd=linux64 ;; esac \
 && gv="${GECKODRIVER_VERSION:-$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/mozilla/geckodriver/releases/latest | sed -n 's|.*/tag/v||p')}" \
 && test -n "${gv}" \
 && curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/v${gv}/geckodriver-v${gv}-${gd}.tar.gz" | tar -xz -C /usr/local/bin \
 && apt-get -q purge -y gnupg && apt-get -q autoremove -y && rm -rf /var/lib/apt/lists/* \
 && useradd -m tester

# trust the test reverse proxy's CA (mounted at /caddy-ca/root.crt)
COPY policies.json /etc/firefox/policies/policies.json

USER tester
WORKDIR /home/tester
