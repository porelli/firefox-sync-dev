"""The admin UI's single sign-on: OpenID Connect (Dex) and a trusted proxy's header.

Runs after test_admin_sync.py in the syncstorage-rs image, see tests/e2e.sh. The test
stack (tests/docker-compose.test.yml) has Dex (tests/dex.yml) at http://dex:5556/dex,
and the admin UI with ADMIN_ALLOWED_USERS=admin@ffs-e2e.invalid,@admins.invalid,
ADMIN_ALLOWED_GROUPS=ffs-admins, the headers X-Test-Email and X-Test-Groups trusted
from the stack's containers (this one too), and the password.

Environment: ADMIN_URL, ADMIN_PASSWORD (see test_admin_sync.py).
"""

import html
import re
import secrets
import time
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit

import pytest
import requests

from test_admin_sync import ADMIN, Admin

DEX = "http://dex:5556/dex"
DEX_PASSWORD = "ffs-test-dex-password"
ALLOWED = "admin@ffs-e2e.invalid"
REFUSED = "mallory@elsewhere.invalid"
CALLBACK = f"{ADMIN}/auth/callback"
STATE_COOKIE = "ffs_admin_oidc"
SESSION_COOKIE = "ffs_admin"


@pytest.fixture(scope="module", autouse=True)
def dex():
    deadline = time.time() + 60
    while True:
        try:
            if requests.get(f"{DEX}/.well-known/openid-configuration", timeout=5).status_code == 200:
                return
        except requests.ConnectionError:
            pass
        assert time.time() < deadline, "Dex did not start"
        time.sleep(1)


def follow(http, url, method="GET", data=None):
    """Follows the redirects until a page, or the admin UI's callback, returned unrequested."""
    for _ in range(10):
        if url.startswith(CALLBACK):
            return url, None
        res = http.request(method, url, data=data, allow_redirects=False, timeout=30)
        method, data = "GET", None
        if res.status_code not in (301, 302, 303, 307):
            return url, res
        url = urljoin(res.url, res.headers["Location"])
    raise AssertionError(f"too many redirects: {url}")


def start(http):
    """The admin UI's /auth/login: the authorization request to Dex"""
    res = http.get(f"{ADMIN}/auth/login", allow_redirects=False, timeout=30)
    assert res.status_code == 303, res.text[:500]
    location = res.headers["Location"]
    assert location.startswith(f"{DEX}/auth?"), location
    query = parse_qs(urlsplit(location).query)
    # authorization code, PKCE S256, state and nonce
    assert query["response_type"] == ["code"] and query["client_id"] == ["ffs-admin"], query
    assert query["redirect_uri"] == [CALLBACK], query
    assert query["code_challenge_method"] == ["S256"] and len(query["code_challenge"][0]) >= 43, query
    assert len(query["state"][0]) >= 32 and len(query["nonce"][0]) >= 32, query
    assert "openid" in query["scope"][0].split(), query
    assert http.cookies.get(STATE_COOKIE) == query["state"][0]
    return location


def dex_sign_in(http, email):
    """Signs in on Dex's login form; returns the callback URL with the code, not yet requested"""
    url, page = follow(http, start(http))
    assert page is not None and page.status_code == 200, url
    form = re.search(r'<form[^>]*method="post"[^>]*>', page.text, re.I)
    assert form and 'name="login"' in page.text and 'name="password"' in page.text, page.text[:2000]
    action = re.search(r'action="([^"]*)"', form.group(0))
    target = urljoin(url, html.unescape(action.group(1))) if action and action.group(1) else url
    callback, page = follow(http, target, "POST", {"login": email, "password": DEX_PASSWORD})
    assert page is None, (callback, page.status_code, page.text[:2000])
    return callback


def with_query(url, **changes):
    parts = urlsplit(url)
    query = {k: v[0] for k, v in parse_qs(parts.query).items()}
    query.update(changes)
    return urlunsplit(parts._replace(query=urlencode(query)))


def refused(http, url, **kwargs):
    """The callback refuses: back to the login page with the error, no session"""
    res = http.get(url, timeout=30, **kwargs)
    assert urlsplit(res.url).path == "/login" and "error=sso" in res.url, (res.url, res.text[:500])
    assert "Single sign-on failed" in res.text
    assert SESSION_COOKIE not in http.cookies
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")


@pytest.fixture(scope="module")
def oidc_admin():
    """A browser signed in with Dex, and what the sign-in left to replay"""
    http = requests.Session()
    callback = dex_sign_in(http, ALLOWED)
    state = http.cookies.get(STATE_COOKIE)
    res = http.get(callback, timeout=30)
    assert res.status_code == 200, res.text[:500]
    # a page of our own that moves on to /, for the SameSite=Strict session cookie
    assert '<meta http-equiv="refresh" content="0;url=/">' in res.text, res.text[:500]
    assert STATE_COOKIE not in http.cookies, "state cookie not cleared"
    return http, callback, state


def test_login_page_lists_the_methods():
    page = requests.get(f"{ADMIN}/login", timeout=30).text
    assert '<a class="button" href="/auth/login">Sign in with Dex</a>' in page, page
    assert 'name="password"' in page


def test_oidc_allowed_user_gets_the_dashboard(oidc_admin):
    http, _, _ = oidc_admin
    res = http.get(f"{ADMIN}/", timeout=30)
    assert res.status_code == 200 and res.url == f"{ADMIN}/", res.url
    assert "Sign out" in res.text and "Sync accounts" in res.text, res.text[:1000]
    assert f'<span class="hint">{ALLOWED}</span>' in res.text
    # the session's forms still need its CSRF token
    assert http.post(f"{ADMIN}/sync/max-users", data={"max_users": "1"}, timeout=30).status_code == 403
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', res.text).group(1)
    res = http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "1"}, timeout=30)
    assert res.status_code == 200 and "Max users set to 1" in res.text, res.text[:500]


def test_oidc_replayed_callback_refused(oidc_admin):
    _, callback, state = oidc_admin
    # the same answer of Dex again, even with the state cookie of that browser
    refused(requests.Session(), callback, headers={"Cookie": f"{STATE_COOKIE}={state}"})


def test_oidc_not_allowed_user_refused():
    http = requests.Session()
    refused(http, dex_sign_in(http, REFUSED))


def test_oidc_tampered_state_refused():
    http = requests.Session()
    callback = dex_sign_in(http, ALLOWED)
    refused(http, with_query(callback, state=secrets.token_hex(32)))
    # nor the right state in another browser (no state cookie): a sign-in pushed on someone
    http = requests.Session()
    refused(http, dex_sign_in(requests.Session(), ALLOWED))


def test_oidc_tampered_code_refused():
    http = requests.Session()
    refused(http, with_query(dex_sign_in(http, ALLOWED), code="forged"))


def header_get(http, path="/", **headers):
    return http.get(f"{ADMIN}{path}", headers=headers, timeout=30)


def signed_in_as(res, user):
    assert res.url == f"{ADMIN}/" and "Sign out" in res.text, (res.url, res.text[:500])
    assert f'<span class="hint">{user}</span>' in res.text, res.text[:1000]


def test_header_allowed_user():
    http = requests.Session()
    page = header_get(http, "/login", **{"X-Test-Email": "Someone@Admins.invalid"}).text
    assert "Signed in by your proxy as someone@admins.invalid" in page, page
    res = header_get(http, **{"X-Test-Email": "Someone@Admins.invalid"})
    signed_in_as(res, "someone@admins.invalid")
    session = http.cookies.get(SESSION_COOKIE)
    assert session
    # the session is reused while the header stays
    signed_in_as(header_get(http, **{"X-Test-Email": "someone@admins.invalid"}), "someone@admins.invalid")
    assert http.cookies.get(SESSION_COOKIE) == session


def test_header_posts_need_the_csrf_token():
    http = requests.Session()
    user = {"X-Test-Email": "someone@admins.invalid"}
    page = header_get(http, **user).text
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    post = lambda data, **h: http.post(f"{ADMIN}/sync/max-users", data=data, headers={**user, **h}, timeout=30)
    assert post({"max_users": "1"}).status_code == 403
    assert post({"csrf": "0" * len(csrf), "max_users": "1"}).status_code == 403
    assert post({"csrf": csrf, "max_users": "1"}, Origin="http://evil.example").status_code == 403
    res = post({"csrf": csrf, "max_users": "1"})
    assert res.status_code == 200 and "Max users set to 1" in res.text, res.text[:500]


def test_header_change_or_removal_ends_the_session():
    http = requests.Session()
    signed_in_as(header_get(http, **{"X-Test-Email": "someone@admins.invalid"}), "someone@admins.invalid")
    first = http.cookies.get(SESSION_COOKIE)
    # another user: a new session, the first one ended
    signed_in_as(header_get(http, **{"X-Test-Email": "other@admins.invalid"}), "other@admins.invalid")
    second = http.cookies.get(SESSION_COOKIE)
    assert second and second != first
    old = requests.get(f"{ADMIN}/", headers={"Cookie": f"{SESSION_COOKIE}={first}"}, timeout=30)
    assert old.url.endswith("/login")
    # no header any more: the session ends, even if the header comes back
    assert header_get(http).url.endswith("/login")
    again = requests.get(f"{ADMIN}/", headers={"Cookie": f"{SESSION_COOKIE}={second}"}, timeout=30)
    assert again.url.endswith("/login")
    # a user who is not allowed: the session ends too
    signed_in_as(header_get(http, **{"X-Test-Email": "someone@admins.invalid"}), "someone@admins.invalid")
    third = http.cookies.get(SESSION_COOKIE)
    assert header_get(http, **{"X-Test-Email": "intruder@elsewhere.invalid"}).url.endswith("/login")
    gone = requests.get(f"{ADMIN}/", headers={"Cookie": f"{SESSION_COOKIE}={third}"}, timeout=30)
    assert gone.url.endswith("/login")


def test_header_not_allowed_user_refused():
    http = requests.Session()
    res = header_get(http, **{"X-Test-Email": "intruder@elsewhere.invalid"})
    assert res.url.endswith("/login") and SESSION_COOKIE not in http.cookies, res.url
    assert "intruder@elsewhere.invalid is not an admin" in res.text, res.text
    # a group alone does not make a session, it needs a user
    res = header_get(http, **{"X-Test-Groups": "ffs-admins"})
    assert res.url.endswith("/login") and SESSION_COOKIE not in http.cookies


def test_header_allowed_group():
    http = requests.Session()
    res = header_get(http, **{"X-Test-Email": "guest@elsewhere.invalid", "X-Test-Groups": "staff, ffs-admins"})
    signed_in_as(res, "guest@elsewhere.invalid")
    res = header_get(requests.Session(), **{"X-Test-Email": "guest@elsewhere.invalid", "X-Test-Groups": "staff"})
    assert res.url.endswith("/login")


def test_events_say_who_and_how():
    admin = Admin()
    # sign-ins and changes are of kind admin, refused sign-ins of their own kind
    events = "".join(admin.get(f"/activity?kind={kind}").split('<table id="events"')[1].split("</table>")[0] for kind in ("admin", "sign-in"))
    for event in (f"signed in: {ALLOWED} (oidc)",
                  f"failed sign-in: {REFUSED} (oidc): not allowed",
                  "failed sign-in: unknown (oidc): bad state",
                  "failed sign-in: unknown (oidc): token request failed",
                  "signed in: someone@admins.invalid (header)",
                  "signed in: other@admins.invalid (header)",
                  "signed in: guest@elsewhere.invalid (header)",
                  "failed sign-in: intruder@elsewhere.invalid (header): not allowed",
                  "signed in (password)",
                  # the changes name the admin and how they signed in
                  f"Max users set to 1 by {ALLOWED} (oidc)",
                  "Max users set to 1 by someone@admins.invalid (header)"):
        assert f"<td>{html.escape(event)}</td>" in events, (event, events[:3000])
