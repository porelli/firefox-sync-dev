"""The admin UI with Mozilla's accounts: the Sync part only (no FxA database).

Runs after test_client_flow.py in the syncstorage-rs image, see tests/e2e.sh: the
account "alice" of the mock FxA syncs, MAX_USERS is 1 (MAX_USERS=initial:1 in .env, so
that the page manages it). tests/e2e.sh also runs the read-only test (-k read_only) while
the stack has a plain MAX_USERS=1. The test stack sets
ADMIN_STALE_DAYS=0, METRICS_FLUSH_SECONDS=5, HEALTH_CHECK_SECONDS=5 and METRICS_TOKEN
(tests/docker-compose.test.yml).

Environment (besides those of test_client_flow.py):
  ADMIN_URL       the admin UI inside the stack's network (http://ffs-admin:8080)
  ADMIN_PASSWORD  its password
  BACKEND         mysql or postgres
  MAX_USERS_SETTING  MAX_USERS of the stack as in .env (initial:1 or 1), MAX_USERS the number
"""

import json
import os
import re
import time

import pytest
import requests
from sqlalchemy import create_engine
from sqlalchemy.sql import text as sqltext

from test_client_flow import EMAIL_DOMAIN, Storage, db, login  # noqa: F401 (db is a fixture)

ADMIN = os.environ["ADMIN_URL"].rstrip("/")
MYSQL = os.environ["BACKEND"] == "mysql"
METRICS_TOKEN = "ffs-test-metrics-token"
# MAX_USERS=initial:N: max users is changed on the page, otherwise it is read-only there
EDITABLE = os.environ.get("MAX_USERS_SETTING", "").startswith("initial:")
editable = pytest.mark.skipif(not EDITABLE, reason="needs MAX_USERS=initial:N")
# PostgreSQL keeps the storage in the tokenserver database
DB_SIZES = ("Tokenserver", "Sync storage") if MYSQL else ("Sync (tokenserver and storage)",)


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

    def post(self, path, **form):
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', self.get("/")).group(1)
        res = self.http.post(f"{ADMIN}{path}", data={"csrf": csrf, **form}, timeout=30)
        assert res.status_code == 200, res.text[:500]
        assert not failed(res.text), failed(res.text)
        return res.text

    def confirm(self, path, ok=True, **form):
        """Follows a link to a confirm page and submits its form (its token, hidden fields)"""
        page = self.get(path)
        action = re.search(r'<form method="post" action="([^"]+)" id="confirm">', page)
        assert action and 'id="cancel">Cancel</a>' in page, page[:3000]
        fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)">', page.split('id="confirm">')[1]))
        res = self.http.post(f"{ADMIN}{action.group(1).replace('&amp;', '&')}", data={**fields, **form}, timeout=60)
        assert res.status_code == 200, res.text[:500]
        if ok:
            assert not failed(res.text), failed(res.text)
        return page, res.text


@pytest.fixture(scope="module")
def alice():
    # test_client_flow.py ended with a key change of alice: a new tokenserver uid, so
    # new (empty) storage. Sync bookmarks again with new keys, like Firefox after a
    # password reset; the admin UI shows the storage of the current keys.
    # The generation must grow: that key change may have been in this same second.
    time.sleep(1.1)
    now = int(time.time())
    res = login("alice", generation=now, keys_changed_at=now, client_state="cccc")
    assert res.status_code == 200, res.text
    storage = Storage(res.json())
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "x" * 100})} for i in range(5)]
    res = storage.request("POST", "/storage/bookmarks", bookmarks)
    assert res.status_code == 200 and len(res.json()["success"]) == 5, res.text
    return storage


@pytest.fixture(scope="module")
def storage_db():
    # the storage database (with PostgreSQL the tokenserver's)
    url = os.environ["SYNC_SYNCSTORAGE__DATABASE_URL"]
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    conn = create_engine(url).execution_options(isolation_level="AUTOCOMMIT").connect()
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def admin(alice):
    # e2e.sh restarted the admin UI, and with it the Sync server: wait for a health
    # check that sees it up. Not before alice synced: /metrics caches the storage totals
    deadline = time.time() + 30
    while time.time() < deadline:
        res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30)
        if 'ffs_up{component="Sync server"} 1\n' in res.text:
            break
        time.sleep(1)
    return Admin()


def test_sign_in_needs_the_password():
    http = requests.Session()
    res = http.get(f"{ADMIN}/", timeout=30)
    assert res.url.endswith("/login") and "Password" in res.text
    res = http.post(f"{ADMIN}/login", data={"password": "wrong"}, timeout=30)
    assert "Wrong password" in res.text
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
    # a form posted from another site, even with the right password
    res = http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]},
                    headers={"Origin": "http://evil.example"}, timeout=30)
    assert res.status_code == 403
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")


def test_forms_refuse_other_sites_and_missing_tokens(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "50"},
                          headers={"Origin": "http://evil.example"}, timeout=30)
    assert res.status_code == 403
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"max_users": "50"}, timeout=30)
    assert res.status_code == 403
    assert re.search(r'id="sync-max-users">1<', admin.get("/"))


def test_health(admin):
    page = admin.get("/")
    health = page.split('<table id="health"')[1].split("</table>")[0]
    components = ["Admin UI", "Sync server", "Tokenserver database"] + (["Storage database"] if MYSQL else [])
    for component in components:
        row = re.search(r"<td>" + re.escape(component) + r"</td><td>(.*?)</td>", health)
        assert row and '<span class="ok">up</span>' in row.group(1), (component, health)
    # the databases report their versions (MariaDB 11.x, MySQL 8.4.x on your own server, PostgreSQL 18.x)
    database = os.environ.get("DATABASE_SERVER") or ("MariaDB" if MYSQL else "PostgreSQL")
    assert re.search(r"<td>Tokenserver database</td><td>.*?</td><td>" + database + r" \d+\.\d+", health), health
    # without self-hosted accounts there is nothing else to check; no SMTP server
    # (FXA_SMTP_HOST empty), no public checks (ADMIN_PUBLIC_CHECK=false in the test stack)
    assert len(re.findall(r"<tr><td>", health)) == len(components), health
    assert "Accounts" not in health and "Email (SMTP)" not in health and "Public" not in health
    assert 'action="/alerts/test"' not in page and "ffs_cert_expiry_seconds" not in requests.get(
        f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text


def table(page, name):
    """The rows of a table of a page, as lists of cells (tags removed)"""
    body = page.split(f'<table id="{name}"')[1].split("</table>")[0].split("<tbody>")[1]
    return [[re.sub(r"<[^>]+>", "", cell).strip() for cell in re.findall(r"<td>(.*?)</td>", row, re.S)]
            for row in re.findall(r"<tr[^>]*>(.*?)</tr>", body, re.S)]


def test_schema_levels(admin):
    rows = {row[0]: row for row in table(admin.get("/"), "schema")}
    for name in (("Tokenserver", "Sync storage") if MYSQL else ("Sync (tokenserver and storage)",)):
        # the newest migration of syncstorage-rs (diesel) and when it ran
        assert name in rows and re.match(r"^\d{4}", rows[name][1]) and re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d$", rows[name][2]), rows


def test_setup_checks_and_nodes(admin):
    page = admin.get("/")
    checks = {row[0]: row for row in table(page, "setup")}
    domain = os.environ["SYNCSTORAGE_DOMAIN"].rstrip("/")
    assert checks["Sync node"][1] == "ok" and domain in checks["Sync node"][2], checks
    # the mock FxA serves the keys of the sign-ins (FXA_OAUTH_SERVER_URL=http://mock_fxa:6000)
    assert checks["Sign-in keys (FXA_OAUTH_SERVER_URL)"][1] == "ok" and "http://mock_fxa:6000/v1/jwks answers" in checks["Sign-in keys (FXA_OAUTH_SERVER_URL)"][2], checks
    assert checks["Account emails (FXA_EMAIL_DOMAIN)"][1] == "ok", checks
    # users per node, with its capacity, load, places and backoff
    node = [row for row in table(page, "nodes") if row[0] == domain]
    assert node and node[0][1] == "in use" and node[0][2] == "1" and all(re.match(r"^-?\d+$", c) for c in node[0][3:]), table(page, "nodes")


@editable
def test_email_domain_mismatch(admin, db):
    # an account of another FXA_EMAIL_DOMAIN, as after a change of it (max users 2 to let it in)
    admin.post("/sync/max-users", max_users="2")
    other = "0123abcd@old-domain.invalid"
    try:
        db.execute(sqltext("INSERT INTO users (service, email, generation, client_state, created_at, nodeid) "
                           "SELECT service, :email, 1, 'aa', 1, nodeid FROM users WHERE email = :alice"),
                   {"email": other, "alice": f"alice@{EMAIL_DOMAIN}"})
        checks = {row[0]: row for row in table(admin.get("/"), "setup")}
        check = checks["Account emails (FXA_EMAIL_DOMAIN)"]
        assert check[1] == "warning" and f"FXA_EMAIL_DOMAIN is {EMAIL_DOMAIN}" in check[2] and "@old-domain.invalid (1)" in check[2], check
        assert "counts twice against max users (2 of 2 used)" in check[2], check
    finally:
        db.execute(sqltext("DELETE FROM users WHERE email = :email"), {"email": other})
        admin.post("/sync/max-users", max_users="1")
    assert {row[0]: row for row in table(admin.get("/"), "setup")}["Account emails (FXA_EMAIL_DOMAIN)"][1] == "ok"


def test_connect_a_device(admin):
    # Mozilla's accounts: Firefox is pointed to this tokenserver
    page = admin.get("/connect")
    domain = os.environ["SYNCSTORAGE_DOMAIN"].rstrip("/")
    steps = page.split('id="device-steps"')[1]
    assert f"identity.sync.tokenserver.uri and set it to {domain}/1.0/sync/1.5" in steps, steps[:2000]
    assert "Custom Sync Token Server URI" in steps and "autoconfig" not in steps


def test_database_sizes(admin):
    sizes = re.search(r"Databases: (.*?)history on the Activity page", admin.get("/"))
    assert sizes, "database sizes line"
    for name in DB_SIZES:
        assert re.search(re.escape(name) + r" [\d.]+ [KMG]?B;", sizes.group(1)), (name, sizes.group(1))


def test_max_users_and_accounts(admin):
    page = admin.get("/")
    assert re.search(r'id="sync-users">1<', page), page[:3000]
    assert re.search(r'id="sync-max-users">1<', page), page[:3000]
    # Mozilla's accounts: the server only knows the account id, linked to its page
    assert "Sync accounts" in page and "Sign-ups" not in page
    row = re.search(r'<tr><td><a href="/users/alice"><code>alice</code></a></td>(.*?)</tr>', page)
    assert row, page[:3000]
    # ADMIN_STALE_DAYS=0: inactive right away; 5 bookmarks of 100 bytes and more
    assert 'class="badge">inactive' in row.group(1), row.group(1)
    stored = re.search(r"<td>([\d.]+ [KMG]?B), (\d+) items</td>", row.group(1))
    assert stored and int(stored.group(2)) == 5, row.group(1)


def test_account_page(admin):
    page = admin.get("/users/alice")
    assert "<code>alice</code>" in page
    assert "Syncing since" in page
    collections = page.split('<table id="collections"')[1].split("</table>")[0]
    assert re.search(r"<td>bookmarks</td><td>5</td><td>[\d.]+ [KMG]?B</td><td>\d{4}-\d\d-\d\d \d\d:\d\d</td>", collections), collections
    # no devices nor sessions with Mozilla's accounts
    assert "Devices" not in page
    assert admin.http.get(f"{ADMIN}/users/nobody", timeout=30).status_code == 404


def test_prometheus(admin):
    assert requests.get(f"{ADMIN}/metrics", timeout=30).status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer wrong"}, timeout=30)
    assert res.status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30)
    assert res.status_code == 200, res.text
    metrics = res.text
    for line in ("ffs_sync_accounts 1\n", "ffs_sync_max_users 1\n", 'ffs_up{component="Sync server"} 1\n',
                 'ffs_up{component="Tokenserver database"} 1\n') + (('ffs_up{component="Storage database"} 1\n',) if MYSQL else ()):
        assert line in metrics, line
    assert int(re.search(r"^ffs_sync_stored_items (\d+)$", metrics, re.M).group(1)) >= 5, metrics
    assert int(re.search(r"^ffs_sync_stored_bytes (\d+)$", metrics, re.M).group(1)) >= 500, metrics
    for name in DB_SIZES:
        assert re.search(r'^ffs_database_bytes\{database="' + re.escape(name) + r'"\} [1-9]\d*$', metrics, re.M), name
    assert "ffs_accounts " not in metrics
    assert re.search(r'^ffs_statsd_total\{name="syncstorage_request_[^"]*"\} [1-9]', metrics, re.M), metrics[-3000:]


@pytest.mark.skipif(EDITABLE, reason="MAX_USERS=initial:N, the page manages max users")
def test_max_users_read_only(db):
    # not the admin fixture: this runs before test_client_flow.py, without alice
    admin = Admin()
    page = admin.get("/")
    before = re.search(r'id="sync-max-users">(\d+)<', page).group(1)
    assert re.search(r'<input id="max_users" [^>]*required disabled>', page), page[:3000]
    assert f"managed by MAX_USERS in .env; set MAX_USERS=initial:{before} to manage it here" in page
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": str(int(before) + 1)}, timeout=30)
    assert res.status_code == 200 and "managed by MAX_USERS in .env" in res.text, res.text[:3000]
    assert "Max users set" not in res.text
    assert db.execute(sqltext("SELECT config_value FROM config WHERE config_key = 'max_users'")).scalar() == before
    assert re.search(r'id="sync-max-users">' + before + "<", admin.get("/"))


@editable
def test_max_users_from_the_page(admin, db):
    bob = f"bob@{EMAIL_DOMAIN}"
    page = admin.get("/")
    assert re.search(r'<input id="max_users" [^>]*required>', page) and "Managed here" in page, page[:3000]
    page = admin.post("/sync/max-users", max_users="2")
    assert "Max users set to 2" in page and re.search(r'id="sync-max-users">2<', page)
    try:
        assert db.execute(sqltext("SELECT config_value FROM config WHERE config_key = 'max_users'")).scalar() == "2"
        # the tokenserver lets a second account in right away
        res = login("bob")
        assert res.status_code == 200, res.text
        assert re.search(r'id="sync-users">2<', admin.get("/"))
    finally:
        db.execute(sqltext("DELETE FROM users WHERE email = :email"), {"email": bob})
        # back to 1 for the following tests
        page = admin.post("/sync/max-users", max_users="1")
    assert "Max users set to 1" in page and re.search(r'id="sync-max-users">1<', page)
    assert login("bob").status_code != 200


@editable
def test_bad_max_users_refused(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "-1"}, timeout=30)
    assert "max users must be a number" in res.text
    assert re.search(r'id="sync-max-users">1<', admin.get("/"))


@editable
def test_activity_page(admin, alice):
    # metrics are written every METRICS_FLUSH_SECONDS (5 in the tests)
    deadline = time.time() + 60
    while True:
        # the Sync server buffers its metrics until a datagram is full: more traffic sends them
        for _ in range(10):
            assert alice.request("GET", "/info/collections").status_code == 200
        page = admin.get("/activity?range=24h")
        requests_total = int(re.search(r"Sync requests: <strong>(\d+)</strong>", page).group(1))
        tokens = re.search(r"Sync tokens issued: <strong>[1-9]\d*</strong>", page)
        if requests_total > 0 and tokens and "Max users set to 1" in page or time.time() > deadline:
            break
        time.sleep(3)
    assert requests_total > 0, page[:3000]
    assert "Last metrics received" in page
    assert re.search(r"Sync tokens issued: <strong>[1-9]\d*</strong>", page), page[:3000]
    assert "<code>syncstorage.request.post_collection</code>" in page
    events = page.split('<table id="events"')[1].split("</table>")[0]
    for event in ("signed in (password)", "failed sign-in (password)", "Max users set to 2 by admin (password)", "Max users set to 1 by admin (password)"):
        assert f"<td>{event}</td>" in events, (event, events[:3000])
    for name in DB_SIZES:
        assert re.search(r"Database " + re.escape(name) + r": <strong>[\d.]+ [KMG]?B</strong>", page), (name, page[:3000])
    for span in ("7d", "30d"):
        assert "Sync requests" in admin.get(f"/activity?range={span}")


def events_of(page):
    """The rows of the event log of an activity page: (when, kind, detail)"""
    table = page.split('<table id="events"')[1].split("</table>")[0]
    return re.findall(r"<tr><td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td></tr>", table)


@editable
def test_audit_trail_filters_and_pages(admin, db):
    admin.post("/sync/max-users", max_users="1")
    page = admin.get("/activity?kind=admin&q=MAX")
    events = events_of(page)
    assert events and all(kind == "admin" and "max" in detail.lower() for _, kind, detail in events), events
    assert "Max users set to 1 by admin (password)" in [detail for _, _, detail in events], events
    assert '<option value="admin" selected>' in page and 'name="q" type="search" value="MAX"' in page
    # older than ADMIN_RETENTION_DAYS (30), kept for ADMIN_AUDIT_RETENTION_DAYS: 350 of them, 100 a page
    old = int((time.time() - 40 * 86400) * 1000)
    marker = f"ffs-page-{int(time.time())}"
    try:
        for i in range(350):
            db.execute(sqltext("INSERT INTO ffs_events (at, kind, detail) VALUES (:at, 'admin', :detail)"),
                       {"at": old + i, "detail": f"{marker} {i:03d} by admin (password)"})
        seen, path, pages = [], f"/activity?kind=admin&q={marker}", 0
        while path:
            page = admin.get(path)
            seen += [detail for _, _, detail in events_of(page)]
            older = re.search(r'<a href="([^"]*)" rel="next" id="older">', page)
            path = older.group(1).replace("&amp;", "&") if older else None
            pages += 1
            assert pages < 10, path
        assert pages == 4 and seen == [f"{marker} {i:03d} by admin (password)" for i in reversed(range(350))], (pages, seen[:3], len(seen))
        # the link back to the newest
        assert 'id="newest"' in page and f"q={marker}" in page
    finally:
        db.execute(sqltext("DELETE FROM ffs_events WHERE detail LIKE :marker"), {"marker": f"{marker} %"})


def test_local_time_label(admin):
    # ADMIN_TZ=Europe/Rome in tests/docker-compose.test.yml: said once, at the bottom
    for path in ("/", "/activity", "/users/alice"):
        page = admin.get(path)
        assert page.count("Times in Europe/Rome") == 1 and "UTC" not in page.replace("Times in Europe/Rome", ""), (path, page[-500:])


def test_no_security_page_without_accounts(admin):
    for path in ("/", "/activity", "/users/alice"):
        assert 'href="/security"' not in admin.get(path), path
    assert admin.http.get(f"{ADMIN}/security", timeout=30).status_code == 404
    # nor the forms of the self-hosted accounts
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    for path in ("/accounts/signups", "/accounts/alice/disable", "/accounts/invite", "/accounts/allowlist/remove"):
        assert admin.http.post(f"{ADMIN}{path}", data={"csrf": csrf, "mode": "closed"}, timeout=30).status_code == 404, path


def test_label_on_a_sync_account(admin):
    # Mozilla's accounts: only the id is known, the note says whose it is
    page = admin.post("/users/alice/note", note="Alice <laptop>")
    assert 'Note of account alice set to &#34;Alice &lt;laptop&gt;&#34;' in page, page[:3000]
    assert 'value="Alice &lt;laptop&gt;"' in page
    row = re.search(r'<tr><td><a href="/users/alice"><code>alice</code></a>(.*?)</td>', admin.get("/"))
    assert row and row.group(1) == ' <span class="note">Alice &lt;laptop&gt;</span>', row and row.group(1)
    assert "<td>admin</td><td>Note of account alice set to &#34;Alice &lt;laptop&gt;&#34; by admin (password)</td>" in admin.get("/activity?kind=admin&q=alice")
    # only accounts the server knows, at most 500 characters
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    assert admin.http.post(f"{ADMIN}/users/nobody/note", data={"csrf": csrf, "note": "x"}, timeout=30).status_code == 404
    res = admin.http.post(f"{ADMIN}/users/alice/note", data={"csrf": csrf, "note": "x" * 501}, timeout=30)
    assert failed(res.text) == ["a note has at most 500 characters, not 501"], failed(res.text)
    page = admin.post("/users/alice/note", note="")
    assert "Removed the note of account alice" in page and 'class="note"' not in admin.get("/")


def rows_of(db, email):
    return db.execute(sqltext("SELECT uid, client_state, replaced_at FROM users WHERE email = :email ORDER BY uid"),
                      {"email": email}).fetchall()


@editable
def test_sync_rows_after_a_key_change(admin, alice, db):
    # the fixture changed alice's keys (client state cccc, a new keys_changed_at)
    rows = rows_of(db, f"alice@{EMAIL_DOMAIN}")
    assert len(rows) >= 2 and rows[-1][1] == "cccc" and rows[-1][2] is None and all(r[2] is not None for r in rows[:-1]), rows
    page = admin.get("/users/alice")
    shown = table(page, "sync-rows")
    assert [int(r[0].split()[0]) for r in shown] == [r[0] for r in rows], shown
    assert shown[-1][0] == f"{rows[-1][0]} current" and shown[-1][1] == "cccc" and shown[-1][5] == "", shown
    # the old ones replaced (a date), not current
    assert all("current" not in r[0] and re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d$", r[5]) for r in shown[:-1]), shown
    assert 'id="flags">Nothing odd in these rows.' in page, page.split('id="sync-rows"')[1][:3000]
    # found by its tokenserver uid
    res = admin.http.get(f"{ADMIN}/find", params={"q": str(rows[0][0])}, timeout=30)
    assert res.url == f"{ADMIN}/users/alice", res.url
    res = admin.http.get(f"{ADMIN}/find", params={"q": "999999999"}, timeout=30)
    assert failed(res.text) == ['No account &#34;999999999&#34;: search an email, an account id or a tokenserver uid.'], failed(res.text)
    # and the search of the overview, by any of its tokenserver uids (the replaced one too)
    for uid in (rows[0][0], rows[-1][0]):
        page = admin.get(f"/?q={uid}")
        assert [r[0] for r in table(page, "sync-accounts")] == ["alice"], table(page, "sync-accounts")
        assert f'id="search-result">1 account matching &#34;{uid}&#34;' in page and f'value="{uid}"' in page, page[:3000]
    page = admin.get("/?q=999999999")
    assert "No account matches." in page and table(page, "sync-accounts") == [[]], table(page, "sync-accounts")
    # part of the id, or of the label
    assert [r[0] for r in table(admin.get("/?q=lic"), "sync-accounts")] == ["alice"]


def collections_of(storage):
    res = storage.request("GET", "/info/collections")
    assert res.status_code == 200, res.text
    return set(res.json())


@editable
def test_reset_sync_data(admin, alice, db):
    history = [{"id": f"history{i}", "payload": json.dumps({"url": "x" * 50})} for i in range(3)]
    assert alice.request("POST", "/storage/history", history).status_code == 200
    assert collections_of(alice) == {"bookmarks", "history"}
    users = len(rows_of(db, f"alice@{EMAIL_DOMAIN}"))
    # a collection it does not have: no confirm page
    assert admin.http.get(f"{ADMIN}/users/alice/reset-sync?collection=nosuch", timeout=30).status_code == 404

    # one collection: only that one goes
    page, done = admin.confirm("/users/alice/reset-sync?collection=history")
    assert "Reset the history collection of account alice?" in page and "3 items" in page, page[:3000]
    assert "Reset the history collection of account alice (3 items" in done, done[:3000]
    assert collections_of(alice) == {"bookmarks"}
    assert len(alice.request("GET", "/storage/bookmarks").json()) == 5

    # everything: the next sync finds the server empty, the account and its row stay
    page, done = admin.confirm("/users/alice/reset-sync")
    assert "Data that is only on the server is lost" in page and 'name="free_slot"' in page, page[:3000]
    assert "Reset the Sync data of account alice (5 items" in done, done[:3000]
    assert collections_of(alice) == set()
    assert alice.request("GET", "/storage/meta/global").status_code == 404
    assert len(rows_of(db, f"alice@{EMAIL_DOMAIN}")) == users and re.search(r'id="sync-users">1<', admin.get("/"))
    # and Firefox uploads again
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "y" * 100})} for i in range(2)]
    assert alice.request("POST", "/storage/bookmarks", bookmarks).status_code == 200
    assert collections_of(alice) == {"bookmarks"}
    assert "<td>admin</td><td>Reset the Sync data of account alice (5 items" in admin.get("/activity?kind=admin&q=Reset")

    # freeing the slot: the rows go, max users counts it no more
    page, done = admin.confirm("/users/alice/reset-sync", free_slot="1")
    assert f"and freed its max users slot ({users} tokenserver rows)" in done, done[:3000]
    assert rows_of(db, f"alice@{EMAIL_DOMAIN}") == [] and re.search(r'id="sync-users">0<', admin.get("/"))
    # the next token goes through max users again (1: room for one)
    res = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="eeee")
    assert res.status_code == 200, res.text
    assert collections_of(Storage(res.json())) == set()
    assert re.search(r'id="sync-users">1<', admin.get("/"))


def storage_ids(storage_db, query, **args):
    return [r[0] for r in storage_db.execute(sqltext(query), args).fetchall()]


@editable
def test_purge_expired_and_orphaned_data(admin, db, storage_db):
    alice_email = f"alice@{EMAIL_DOMAIN}"
    # new keys again (a newer keys_changed_at): the eeee row is replaced now, kept a day
    time.sleep(1.1)
    token = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="eeef").json()
    live = Storage(token)
    assert live.request("POST", "/storage/bookmarks", [{"id": "kept", "payload": "x" * 20}]).status_code == 200
    current = token["uid"]
    bso, user, coll = ("bso", "userid", "collection") if MYSQL else ("bsos", "user_id", "collection_id")
    history = storage_db.execute(sqltext("SELECT " + ("id" if MYSQL else "collection_id") + " FROM collections WHERE name = 'history'")).scalar()
    now = int(time.time() * 1000)
    day = 86400 * 1000
    # a row of alice replaced two days ago, with data on its keys
    db.execute(sqltext("INSERT INTO users (service, email, generation, client_state, created_at, replaced_at, nodeid, keys_changed_at) "
                       "SELECT service, email, 0, 'dddd', :created, :replaced, nodeid, 1 FROM users WHERE uid = :uid"),
               {"created": now - 3 * day, "replaced": now - 2 * day, "uid": current})
    old = db.execute(sqltext("SELECT MAX(uid) FROM users WHERE email = :email AND client_state = 'dddd'"), {"email": alice_email}).scalar()

    def put(userid, item, expired):
        if MYSQL:
            # as the Sync server does: a write changes the collections, which the storage report's cache watches
            storage_db.execute(sqltext("INSERT INTO user_collections (userid, collection, last_modified) VALUES (:u, :c, :m) "
                                       "ON DUPLICATE KEY UPDATE last_modified = GREATEST(last_modified, VALUES(last_modified))"),
                               {"u": userid, "c": history, "m": now - day})
            storage_db.execute(sqltext("INSERT INTO bso (userid, collection, id, payload, payload_size, modified, ttl) "
                                       "VALUES (:u, :c, :i, :p, 10, :m, :t)"),
                               {"u": userid, "c": history, "i": item, "p": "z" * 10, "m": now - day, "t": now - 1000 if expired else now + 365 * day})
        else:
            storage_db.execute(sqltext("INSERT INTO user_collections (user_id, collection_id, modified) VALUES (:u, :c, NOW() - INTERVAL '1 day') "
                                       "ON CONFLICT DO NOTHING"), {"u": userid, "c": history})
            storage_db.execute(sqltext("INSERT INTO bsos (user_id, collection_id, bso_id, payload, modified, expiry) "
                                       "VALUES (:u, :c, :i, :p, NOW() - INTERVAL '1 day', NOW() + " + ("INTERVAL '-1 second'" if expired else "INTERVAL '365 days'") + ")"),
                               {"u": userid, "c": history, "i": item, "p": "z" * 10})
    for i in range(2):
        put(old, f"old{i}", False)
    for i in range(3):
        put(current, f"expired{i}", True)

    page = admin.get("/")
    totals = {r[0]: r for r in table(page, "storage-totals")}
    assert totals["Expired"][1] == "3" and totals["Orphaned"][1] == "2", totals
    orphans = table(page, "orphans")
    assert orphans == [["replaced keys", alice_email, str(old), "2 items, 20 B"]], orphans
    live_before = int(totals["Live"][1])

    confirm, done = admin.confirm("/storage/purge")
    assert "1 orphans: 2 items, 20 B" in confirm and "3 expired items, 30 B" in confirm, confirm[:3000]
    assert "Purged the Sync storage: 1 orphans (2 items, 20 B, 1 tokenserver rows), 3 expired items (30 B), 0 stale batches" in done, done[:3000]
    # exactly those: the replaced row and its data, the expired items; the live data stays
    assert storage_ids(storage_db, f"SELECT {coll} FROM {bso} WHERE {user} = :u", u=old) == []
    assert db.execute(sqltext("SELECT COUNT(*) FROM users WHERE uid = :u"), {"u": old}).scalar() == 0
    assert storage_ids(storage_db, f"SELECT {coll} FROM {bso} WHERE {user} = :u AND " + ("ttl < :now" if MYSQL else "expiry < NOW()"), u=current, now=now) == []
    assert live.request("GET", "/storage/bookmarks").json() == ["kept"]
    after = {r[0]: r for r in table(admin.get("/"), "storage-totals")}
    assert after["Expired"][1] == "0" and after["Orphaned"][1] == "0" and int(after["Live"][1]) == live_before, after
    assert re.search(r'id="sync-users">1<', admin.get("/"))


@editable
def test_delete_the_sync_data_of_an_account(admin, db):
    # Mozilla's accounts: the rows and the data of the id, the account itself is Mozilla's
    alice_email = f"alice@{EMAIL_DOMAIN}"
    assert rows_of(db, alice_email)
    page = admin.get("/users/alice")
    assert 'href="/users/alice/delete"' in page
    confirm = admin.get("/users/alice/delete")
    assert "Delete the Sync data of account alice?" in confirm and '<label for="confirm_email">Type the account id to confirm</label>' in confirm, confirm[:3000]
    # the id typed must be this one
    _, res = admin.confirm("/users/alice/delete", ok=False, confirm_email="bob")
    assert failed(res) == ["the account id typed is not this one: nothing deleted"], failed(res)
    assert rows_of(db, alice_email)
    _, done = admin.confirm("/users/alice/delete", confirm_email="alice")
    assert "Deleted the Sync data of account alice (" in done, done[:3000]
    assert rows_of(db, alice_email) == [] and re.search(r'id="sync-users">0<', done)
    assert admin.http.get(f"{ADMIN}/users/alice", timeout=30).status_code == 404
    assert "<td>admin</td><td>Deleted the Sync data of account alice" in admin.get("/activity?kind=admin&q=Deleted")
    # it can sync here again, as a new account
    res = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="ffff")
    assert res.status_code == 200, res.text


def attention_of(page):
    """The lines of Needs attention: (text, link)"""
    box = page.split('<section id="attention">')[1].split("</section>")[0]
    return [(re.sub(r"<[^>]+>", "", text).strip(), href) for text, href in re.findall(r'<li>(.*?) <a href="([^"]*)">', box, re.S)]


def test_backups_on_the_overview(admin):
    # tests/e2e.sh ran the backup service (with EXTERNAL_DB=1: the INSERT of your own backups)
    deadline = time.time() + 30
    while True:
        page = admin.get("/")
        line = re.search(r'<p class="hint" data-scope="sync">(.*?)</p>', page, re.S)
        if line or time.time() > deadline:
            break
        time.sleep(1)
    assert line, page.split('<div id="backups">')[1][:1000]
    text = re.sub(r"<[^>]+>", "", line.group(1))
    assert re.match(r"Last backup of the Sync databases: \d{4}-\d\d-\d\d \d\d:\d\d, [\d.]+ [KMG]?B, ok\.$", text), text
    assert not [a for a in attention_of(page) if "backup" in a[0]], attention_of(page)
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    age = re.search(r'^ffs_backup_age_seconds\{scope="sync"\} (\d+)$', metrics, re.M)
    assert age and int(age.group(1)) < 3600 and 'ffs_backup_last_ok{scope="sync"} 1' in metrics, metrics[-2000:]


@editable
def test_near_max_users_line(admin, db):
    before = re.search(r'id="sync-max-users">(\d+)<', admin.get("/")).group(1)
    users = int(re.search(r'id="sync-users">(\d+)<', admin.get("/")).group(1))
    try:
        # every place taken: a line, a link to the form, a gauge, an event (and alert) once
        page = admin.post("/sync/max-users", max_users=str(users))
        assert (f"{users} of {users} accounts are taken (90% or more): new accounts are refused once all are.", "#sync") in attention_of(page), attention_of(page)
        assert 'id="sync">' in page
        metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
        assert "ffs_sync_near_max_users 1\n" in metrics
        query = sqltext("SELECT COUNT(*) FROM ffs_events WHERE kind = 'attention' AND detail LIKE '%accounts are taken (90% or more)%'")
        deadline = time.time() + 30
        while db.execute(query).scalar() == 0 and time.time() < deadline:
            time.sleep(1)
        assert db.execute(query).scalar() >= 1
        page = admin.post("/sync/max-users", max_users=str(users * 10 + 10))
        assert not [a for a in attention_of(page) if "90%" in a[0]], attention_of(page)
        metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
        assert "ffs_sync_near_max_users 0\n" in metrics
    finally:
        admin.post("/sync/max-users", max_users=before)


def test_sign_out(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/logout", data={"csrf": csrf}, timeout=30)
    assert res.url.endswith("/login")
    assert admin.http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
