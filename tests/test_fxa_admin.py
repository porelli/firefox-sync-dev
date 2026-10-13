"""Who can use the self-hosted accounts: sign-up policy, admin UI, rate limits.

Runs after test_fxa_flow.py in the syncstorage-rs image (PyFxA), see tests/e2e-fxa.sh.
The stack starts with FXA_SIGNUPS=allowlist and FXA_SIGNUP_ALLOWLIST=@example.com,
invited@example.net.

Environment (besides those of test_fxa_flow.py):
  ADMIN_URL          public URL of the admin UI
  ADMIN_PASSWORD     its password
  FXA_DIRECT_URL     the auth server itself, without the sign-up gate (http://fxa-auth:9000)
  ADMIN_FXA_CLIENT_ID the admin UI's OAuth client: it signs in with these accounts
                     (ADMIN_ALLOWED_USERS=@example.com)
"""

import json
import os
import re
import time
import uuid
from urllib.parse import parse_qs, urlsplit

import pytest
import requests
from fxa._utils import HawkTokenAuth
from fxa.core import Client
from fxa.errors import ClientError

from test_fxa_flow import AUTH, CONTENT, FIREFOX_CLIENT_ID, SYNC, authorize, storage, sync_token, wait_for_code

ADMIN = os.environ["ADMIN_URL"].rstrip("/")
DIRECT = os.environ["FXA_DIRECT_URL"].rstrip("/")
INVITED = "invited@example.net"  # on FXA_SIGNUP_ALLOWLIST
ADMIN_CLIENT_ID = os.environ.get("ADMIN_FXA_CLIENT_ID", "")
sso = pytest.mark.skipif(not ADMIN_CLIENT_ID, reason="the admin UI does not sign in with these accounts")


def email(domain):
    return f"ffs-admin-{uuid.uuid4().hex[:10]}@{domain}"


def exists(address):
    res = requests.post(f"{AUTH}/v1/account/status", json={"email": address}, timeout=30)
    assert res.status_code == 200, res.text
    return res.json()["exists"]


def create(address, server=AUTH):
    return requests.post(f"{server}/v1/account/create", json={"email": address, "authPW": "00" * 32}, timeout=30)


def failed(page):
    """The errors a page shows (database queries that failed...)"""
    return re.findall(r'class="failed"[^>]*>([^<]*)', page)


class Admin:
    """The admin UI, used like a browser: forms with the CSRF token of the page."""

    def __init__(self):
        self.http = requests.Session()
        res = self.http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
        assert res.status_code == 200 and "Sign out" in res.text, res.text[:500]

    def get(self, path):
        res = self.http.get(f"{ADMIN}{path}", timeout=30)
        assert res.status_code == 200, (path, res.status_code, res.text[:500])
        assert not failed(res.text), (path, failed(res.text))
        return res.text

    def page(self):
        return self.get("/")

    def csrf(self):
        return re.search(r'name="csrf" value="([0-9a-f]+)"', self.page()).group(1)

    def post(self, path, **form):
        res = self.http.post(f"{ADMIN}{path}", data={"csrf": self.csrf(), **form}, timeout=30)
        assert res.status_code == 200, res.text[:500]
        assert not failed(res.text), failed(res.text)
        return res.text

    def uid(self, address):
        row = re.search(r'<tr data-email="' + re.escape(address) + r'">.*?action="/accounts/([0-9a-f]{32})/', self.page(), re.S)
        assert row, f"{address} not in the accounts list"
        return row.group(1)


@pytest.fixture(scope="module")
def admin():
    return Admin()


def test_admin_needs_the_password():
    http = requests.Session()
    res = http.get(f"{ADMIN}/", timeout=30)
    assert res.url.endswith("/login")
    res = http.post(f"{ADMIN}/login", data={"password": "wrong"}, timeout=30)
    assert "Wrong password" in res.text
    # a form posted from another site
    res = http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]},
                    headers={"Origin": "https://evil.example"}, timeout=30)
    assert res.status_code == 403


def test_signup_refused_with_a_readable_error():
    address = email("example.org")
    res = create(address)
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    assert not exists(address)


def test_signup_refused_without_the_gate():
    # straight to the auth server: the database refuses it
    address = email("example.org")
    res = create(address, server=DIRECT)
    assert res.status_code >= 400, res.text
    assert not exists(address)


def test_allowlist_matches_emails_and_domains():
    # @example.com is on the list, of example.net only invited@example.net
    assert create(email("example.com")).status_code == 200
    res = create(email("example.net"))
    assert res.status_code == 400, res.text


def test_signups_closed_and_reopened(admin):
    admin.post("/accounts/signups", mode="closed", allowlist="")
    res = create(email("example.com"))
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    admin.post("/accounts/signups", mode="open", allowlist="")
    address = email("example.org")
    assert create(address).status_code == 200
    assert exists(address)
    # kept by tests/e2e-fxa.sh after a restart, @example.com for the browser tests
    page = admin.post("/accounts/signups", mode="allowlist", allowlist=f"@example.com\n{INVITED}\nkept@example.net")
    assert "kept@example.net" in page


@pytest.fixture(scope="module")
def invited():
    password = uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    session = client.create_account(INVITED, password, keys=True)
    session.verify_email_code(wait_for_code(INVITED))
    return {"client": client, "session": session, "password": password, "keys_changed_at": created}


def tokenserver(bearer, key_id):
    return requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)


def test_admin_lists_accounts(admin, invited):
    page = admin.page()
    assert INVITED in page
    assert invited["session"].uid in page


def sso_start(http):
    """The admin UI's /auth/login: the authorization request to the accounts pages"""
    res = http.get(f"{ADMIN}/auth/login", allow_redirects=False, timeout=30)
    assert res.status_code == 303, res.text[:500]
    url = urlsplit(res.headers["Location"])
    assert f"{url.scheme}://{url.netloc}{url.path}" == f"{CONTENT}/authorization", res.headers["Location"]
    query = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert query["client_id"] == ADMIN_CLIENT_ID and query["redirect_uri"] == f"{ADMIN}/auth/callback", query
    assert query["code_challenge_method"] == "S256" and query["code_challenge"] and query["state"], query
    return query


def sso_code(session, query):
    """What the accounts pages do for a signed-in user: a code for the admin UI"""
    token_id = HawkTokenAuth(session.token, "sessionToken").id
    keys = ("client_id", "scope", "state", "code_challenge", "code_challenge_method", "redirect_uri")
    return requests.post(f"{AUTH}/v1/oauth/authorization", json={k: query[k] for k in keys},
                         headers={"Authorization": f"Bearer fxs_{token_id}"}, timeout=30)


def sso_callback(http, session):
    query = sso_start(http)
    res = sso_code(session, query)
    assert res.status_code == 200, res.text
    assert res.json()["state"] == query["state"], res.text
    return http.get(f"{ADMIN}/auth/callback", params={"code": res.json()["code"], "state": query["state"]}, timeout=30)


@sso
def test_admin_sso_client_registered():
    # discovery of the accounts as an OpenID Connect provider, and the admin UI's client
    discovery = requests.get(f"{CONTENT}/.well-known/openid-configuration", timeout=30).json()
    assert discovery["issuer"] == CONTENT and discovery["authorization_endpoint"] == f"{CONTENT}/authorization", discovery
    client = requests.get(f"{AUTH}/v1/client/{ADMIN_CLIENT_ID}", timeout=30).json()
    assert client["trusted"] is True and client["redirect_uri"] == f"{ADMIN}/auth/callback", client
    assert "Sign in with Mozilla account" in requests.get(f"{ADMIN}/login", timeout=30).text


@sso
def test_admin_sso_with_an_allowed_account():
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    # a password alone is not enough (SERVICES_WITH_EMAIL_VERIFICATION): no code yet
    res = sso_code(session, sso_start(requests.Session()))
    assert res.status_code == 400 and res.json()["errno"] == 138, res.text
    session.verify_email_code(wait_for_code(address))
    http = requests.Session()
    res = sso_callback(http, session)
    assert res.status_code == 200 and urlsplit(res.url).path == "/auth/callback", (res.url, res.text[:500])
    page = http.get(f"{ADMIN}/", timeout=30)
    assert page.url == f"{ADMIN}/" and "Sign out" in page.text, (page.url, page.text[:500])
    assert f'<span class="hint">{address}</span>' in page.text
    assert f"signed in: {address} (oidc)" in Admin().get("/activity?range=24h")


@sso
def test_admin_sso_refuses_other_accounts(invited):
    # on the sign-up allowlist, not on ADMIN_ALLOWED_USERS
    http = requests.Session()
    res = sso_callback(http, invited["session"])
    assert urlsplit(res.url).path == "/login" and "Single sign-on failed" in res.text, res.url
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
    assert f"failed sign-in: {INVITED} (oidc): not allowed" in Admin().get("/activity?range=24h")


def test_disabled_account_is_locked_out(admin, invited):
    session = invited["session"]
    bearer, key_id = sync_token(session, invited["keys_changed_at"])
    assert tokenserver(bearer, key_id).status_code == 200
    # another one, not used yet: the tokenserver caches what /v1/verify said for 5 minutes
    unused = authorize(session)
    uid = admin.uid(INVITED)
    assert uid == session.uid
    admin.post(f"/accounts/{uid}/disable")
    assert "disabled" in admin.page()

    # signed out everywhere, and no new sign-in
    with pytest.raises(ClientError):
        session.get_email_status()
    with pytest.raises(ClientError):
        invited["client"].login(INVITED, invited["password"], keys=True)
    # and its access tokens are revoked, for the tokenserver too
    verified = requests.post(f"{AUTH}/v1/verify", json={"token": unused}, timeout=30)
    assert verified.status_code != 200, verified.text
    res = tokenserver(unused, key_id)
    assert res.status_code == 401, res.text

    admin.post(f"/accounts/{uid}/enable")
    session = invited["client"].login(INVITED, invited["password"], keys=True)
    assert session.uid == uid


def test_access_tokens_are_short_lived():
    # FXA_ACCESS_TOKEN_LIFETIME, 60 minutes by default
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex, keys=True)
    session.verify_email_code(wait_for_code(address))
    granted = authorize(session, full=True)
    assert 0 < granted["expires_in"] <= 3600, granted


def test_max_users_from_admin(admin):
    page = admin.page()
    users = int(re.search(r'id="sync-users">(\d+)<', page).group(1))
    before = int(re.search(r'id="sync-max-users">(\d+)<', page).group(1))
    # tests/e2e-fxa.sh runs the stack with MAX_USERS=initial:10: the page manages it
    assert "Managed here" in page and not re.search(r'<input id="max_users" [^>]*disabled>', page), page[:3000]
    admin.post("/sync/max-users", max_users=str(users))
    try:
        # a new account cannot start syncing while the server is full
        client = Client(server_url=f"{AUTH}/v1")
        address = email("example.com")
        created = int(time.time() * 1000)
        session = client.create_account(address, uuid.uuid4().hex, keys=True)
        session.verify_email_code(wait_for_code(address))
        bearer, key_id = sync_token(session, created)
        res = tokenserver(bearer, key_id)
        assert res.status_code != 200, res.text
        # room again: the same account gets in
        admin.post("/sync/max-users", max_users=str(users + 1))
        assert tokenserver(bearer, key_id).status_code == 200
    finally:
        # 7: tests/e2e-fxa.sh checks that a restart keeps it
        admin.post("/sync/max-users", max_users="7" if before != 7 else "8")


def test_spoofed_forwarded_for_does_not_bypass_rate_limit():
    # the auth server takes the client IP from X-Forwarded-For (CLIENT_ADDRESS_DEPTH):
    # a client sending its own must still be counted as itself
    address = email("example.com")
    for i in range(10):
        res = requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32},
                            headers={"X-Forwarded-For": f"198.51.100.{i + 1}"}, timeout=30)
        if res.status_code == 429:
            assert res.json()["errno"] == 114, res.text
            return
    raise AssertionError("a new X-Forwarded-For on every attempt escaped the rate limit")


def test_user_page_shows_what_is_stored(admin):
    address = email("example.com")
    created = int(time.time() * 1000)
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex, keys=True)
    session.verify_email_code(wait_for_code(address))
    bearer, key_id = sync_token(session, created)
    token = tokenserver(bearer, key_id).json()
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "x" * 100})} for i in range(3)]
    assert storage(token, "POST", "/storage/bookmarks", bookmarks).status_code == 200
    page = admin.get(f"/users/{session.uid}")
    assert address in page
    assert re.search(r"<td>bookmarks</td><td>3</td>", page), page[:2000]
    assert "Sessions" in page and "Python" in page  # PyFxA's session


def test_activity_page():
    # a fresh session: the events of the other tests are there, and the metrics of
    # the sync above (written every METRICS_FLUSH_SECONDS in the tests)
    admin = Admin()
    deadline = time.time() + 30
    while True:
        page = admin.get("/activity?range=24h")
        requests_total = int(re.search(r"Sync requests: <strong>(\d+)</strong>", page).group(1))
        if requests_total > 0 or time.time() > deadline:
            break
        time.sleep(3)
    assert requests_total > 0, page[:2000]
    assert "syncstorage.request.post_collection" in page
    for event in ("sign-up refused", "signed in", "Max users set", "Disabled account", "sign-up"):
        assert event in page, event
    assert re.search(r"Database Tokenserver: <strong>[\d.]+ [KMG]?B", page), "database size chart"
    admin.get("/activity?range=30d")


def test_health_and_sizes(admin):
    page = admin.page()
    health = page.split('<table id="health">')[1].split("</table>")[0]
    for component in ("Sync server", "Tokenserver database", "Storage database", "Accounts API", "Accounts pages",
                      "Profile server", "Accounts database", "Accounts Redis"):
        row = re.search(r"<td>" + component + r"</td><td>(.*?)</td><td>(.*?)</td>", health)
        assert row and "up" in row.group(1), (component, health)
    # versions from /__version__ (our syncstorage images fill it in since APP_BUILD_REVISION 2)
    assert re.search(r"<td>Accounts API</td><td>[^<]*<span[^>]*>up</span></td><td>\d+\.\d+", health), health
    assert re.search(r"Databases: .*Tokenserver \d", page), page[:3000]
    for component, v in (("Accounts database", r"MySQL 8\.4"), ("Accounts Redis", r"Redis \d"), ("Profile server", r"\d+\.\d+")):
        assert re.search(r"<td>" + component + r"</td><td>[^<]*<span[^>]*>up</span></td><td>" + v, health), (component, health)


def test_inactive_and_unconfirmed_badges(admin):
    # the test stack marks right away (ADMIN_STALE_DAYS=0, ADMIN_UNCONFIRMED_HOURS=0)
    page = admin.page()
    assert 'class="badge">inactive' in page and 'class="badge">unconfirmed' in page


def test_security_page_lifts_a_block(admin):
    address = email("example.com")
    login = lambda: requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32}, timeout=30)
    codes = [login().status_code for _ in range(7)]
    assert 429 in codes, codes
    page = admin.get("/security")
    key = re.search(r'name="key" value="(rate-limit:block:[^"]*' + re.escape(address) + r'[^"]*)"', page)
    assert key, page[:3000]
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/security/unblock", data={"csrf": csrf, "key": key.group(1)}, timeout=30)
    assert "Lifted the block" in res.text
    assert login().status_code == 400


def test_security_page_lists_attempts(admin):
    # below the block (5 in 15 minutes), at least half way: listed
    address = email("example.com")
    for _ in range(3):
        res = requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32}, timeout=30)
        assert res.status_code == 400, res.text
    attempts = admin.get("/security").split('<table id="attempts">')[1].split("</table>")[0]
    assert re.search(r"<code>[^<]*" + re.escape(address) + r"[^<]*</code></td><td>accountLogin</td><td>3 of \d+</td>", attempts), attempts[:3000]
    # only blocks can be lifted
    res = admin.http.post(f"{ADMIN}/security/unblock", data={"csrf": admin.csrf(), "key": f"rate-limit:attempts:email={address}:accountLogin:5-900-900"}, timeout=30)
    assert failed(res.text) == ["not a block"], failed(res.text)


def bearer(session):
    from fxa._utils import HawkTokenAuth
    return {"Authorization": f"Bearer fxs_{HawkTokenAuth(session.token, 'sessionToken').id}"}


def test_sign_out_one_session_and_one_device(admin):
    import hashlib
    from fxa._utils import HawkTokenAuth
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    first = client.create_account(address, password)
    first.verify_email_code(wait_for_code(address))
    second = client.login(address, password)
    third = client.login(address, password)
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs test device", "type": "desktop"},
                           headers=bearer(third), timeout=30)
    assert device.status_code == 200, device.text

    # one session: the others keep working
    ref = hashlib.sha256(bytes.fromhex(HawkTokenAuth(second.token, "sessionToken").id)).hexdigest()
    page = admin.get(f"/users/{first.uid}")
    assert f"/sessions/{ref}/sign-out" in page and "ffs test device" in page, page[:3000]
    # in the event log as a new device
    assert f"<td>new device</td><td>{address}: ffs test device (desktop)</td>" in admin.get("/activity"), "new device event"
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/users/{first.uid}/sessions/{ref}/sign-out", data={"csrf": csrf}, timeout=30)
    assert "Signed out a session" in res.text
    with pytest.raises(ClientError):
        second.get_email_status()
    first.get_email_status()

    # one device, with its session
    res = admin.http.post(f"{ADMIN}/users/{first.uid}/devices/{device.json()['id']}/sign-out", data={"csrf": csrf}, timeout=30)
    assert "Signed out a device" in res.text and "ffs test device" not in res.text
    with pytest.raises(ClientError):
        third.get_email_status()
    first.get_email_status()


def test_sign_out_a_device_of_a_refresh_token(admin):
    # the mobile apps register their device with an OAuth refresh token, not a session
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    session.verify_email_code(wait_for_code(address))
    refresh = authorize(session, full=True, offline=True)["refresh_token"]
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs mobile device", "type": "mobile"},
                           headers={"Authorization": f"Bearer {refresh}"}, timeout=30)
    assert device.status_code == 200, device.text
    renew = lambda: requests.post(f"{AUTH}/v1/oauth/token", json={"grant_type": "refresh_token", "client_id": FIREFOX_CLIENT_ID,
                                                                   "refresh_token": refresh}, timeout=30)
    assert renew().status_code == 200
    assert "ffs mobile device" in admin.get(f"/users/{session.uid}")

    page = admin.post(f"/users/{session.uid}/devices/{device.json()['id']}/sign-out")
    assert "Signed out a device" in page and "ffs mobile device" not in page
    # no new access tokens with it; the session of the account is another sign-in
    res = renew()
    assert res.status_code in (400, 401), res.text
    session.get_email_status()


def test_alert_emails():
    # sent every ALERT_INTERVAL_SECONDS (5 in the tests) to ADMIN_ALERT_EMAIL
    from test_fxa_flow import MAILPIT
    deadline = time.time() + 60
    while time.time() < deadline:
        found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": "to:admin@fxa.test"}, timeout=10).json()
        text = " ".join(requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}", timeout=10).json().get("Text", "")
                        for m in found.get("messages", []))
        # health: the components that came up after the admin UI (the Sync server)
        if "sign-up refused" in text and "admin: signed in" in text and "sign-up: " in text and "health: " in text:
            return
        time.sleep(3)
    raise AssertionError(f"alerts missing: {text[:2000]}")


def test_prometheus():
    assert requests.get(f"{ADMIN}/metrics", timeout=30).status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30)
    assert res.status_code == 200, res.text
    for line in ("ffs_sync_accounts ", 'ffs_up{component="Sync server"} 1', "ffs_accounts ", 'ffs_database_bytes{database="Accounts"}',
                 'ffs_statsd_total{name="syncstorage_'):
        assert line in res.text, line
