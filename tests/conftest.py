"""The access control of tests/e2e-fxa.sh for the tests' requests sessions, as the Firefox of
the tests has it:
- FFS_CLIENT_CERT and FFS_CLIENT_KEY (CLIENT_CERT=1): every session presents that client
  certificate;
- FFS_SSO_USER and FFS_SSO_PASSWORD (SSO=authelia): signed in to Authelia once, every session
  sends its session cookie.
"""

import os

import requests

_init = requests.Session.__init__
_cookie = None

if os.environ.get("FFS_SSO_USER"):
    res = requests.post("https://auth.fxa.test/api/firstfactor", verify=os.environ.get("REQUESTS_CA_BUNDLE", "/caddy-ca/root.crt"),
                        json={"username": os.environ["FFS_SSO_USER"], "password": os.environ["FFS_SSO_PASSWORD"], "keepMeLoggedIn": False},
                        timeout=30)
    assert res.status_code == 200 and "authelia_session" in res.cookies, (res.status_code, res.text[:300])
    _cookie = res.cookies["authelia_session"]


def _with_access(self, *args, **kwargs):
    _init(self, *args, **kwargs)
    if os.environ.get("FFS_CLIENT_CERT"):
        self.cert = (os.environ["FFS_CLIENT_CERT"], os.environ["FFS_CLIENT_KEY"])
    if _cookie:
        self.cookies.set("authelia_session", _cookie, domain=".fxa.test")


if os.environ.get("FFS_CLIENT_CERT") or _cookie:
    requests.Session.__init__ = _with_access
