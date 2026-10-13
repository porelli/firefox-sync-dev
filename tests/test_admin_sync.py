"""The admin UI with Mozilla's accounts: the Sync part only (no FxA database).

Runs after test_client_flow.py in the syncstorage-rs image, see tests/e2e.sh: the
account "alice" of the mock FxA syncs, MAX_USERS is 1. The test stack sets
ADMIN_STALE_DAYS=0, METRICS_FLUSH_SECONDS=5, HEALTH_CHECK_SECONDS=5 and METRICS_TOKEN
(tests/docker-compose.test.yml).

Environment (besides those of test_client_flow.py):
  ADMIN_URL       the admin UI inside the stack's network (http://ffs-admin:8080)
  ADMIN_PASSWORD  its password
  BACKEND         mysql or postgres
"""

import json
import os
import re
import time

import pytest
import requests
from sqlalchemy.sql import text as sqltext

from test_client_flow import EMAIL_DOMAIN, Storage, db, login  # noqa: F401 (db is a fixture)

ADMIN = os.environ["ADMIN_URL"].rstrip("/")
MYSQL = os.environ["BACKEND"] == "mysql"
METRICS_TOKEN = "ffs-test-metrics-token"
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
    health = page.split('<table id="health">')[1].split("</table>")[0]
    components = ["Admin UI", "Sync server", "Tokenserver database"] + (["Storage database"] if MYSQL else [])
    for component in components:
        row = re.search(r"<td>" + re.escape(component) + r"</td><td>(.*?)</td>", health)
        assert row and '<span class="ok">up</span>' in row.group(1), (component, health)
    # the databases report their versions (MariaDB 11.x, PostgreSQL 18.x)
    database = "MariaDB" if MYSQL else "PostgreSQL"
    assert re.search(r"<td>Tokenserver database</td><td>.*?</td><td>" + database + r" \d+\.\d+", health), health
    # without self-hosted accounts there is nothing else to check
    assert len(re.findall(r"<tr><td>", health)) == len(components), health
    assert "Accounts" not in health


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
    collections = page.split('<table id="collections">')[1].split("</table>")[0]
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


def test_max_users_from_the_page(admin, db):
    bob = f"bob@{EMAIL_DOMAIN}"
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


def test_bad_max_users_refused(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "-1"}, timeout=30)
    assert "max users must be a number" in res.text
    assert re.search(r'id="sync-max-users">1<', admin.get("/"))


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
    events = page.split('<table id="events">')[1].split("</table>")[0]
    for event in ("signed in (password)", "failed sign-in (password)", "Max users set to 2", "Max users set to 1"):
        assert f"<td>{event}</td>" in events, (event, events[:3000])
    for name in DB_SIZES:
        assert re.search(r"Database " + re.escape(name) + r": <strong>[\d.]+ [KMG]?B</strong>", page), (name, page[:3000])
    for span in ("7d", "30d"):
        assert "Sync requests" in admin.get(f"/activity?range={span}")


def test_no_security_page_without_accounts(admin):
    for path in ("/", "/activity", "/users/alice"):
        assert 'href="/security"' not in admin.get(path), path
    assert admin.http.get(f"{ADMIN}/security", timeout=30).status_code == 404
    # nor the forms of the self-hosted accounts
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    for path in ("/accounts/signups", "/accounts/alice/disable"):
        assert admin.http.post(f"{ADMIN}{path}", data={"csrf": csrf, "mode": "closed"}, timeout=30).status_code == 404, path


def test_sign_out(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/logout", data={"csrf": csrf}, timeout=30)
    assert res.url.endswith("/login")
    assert admin.http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
