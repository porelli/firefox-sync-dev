"""A small household on a fresh stack, for the screenshots of ADMIN.md.

  python3 /tests/demo_seed.py fxa    self-hosted accounts (tests/e2e-fxa.sh DEMO=1)
  python3 /tests/demo_seed.py sync   Mozilla's accounts, Sync only (tests/e2e.sh mysql DEMO=1)

Everything goes through the public flows the tests use, with the user agents of Firefox
(not "Python Requests"): sign-up with the email code from Mailpit, sign-ins with theirs,
devices registered on /account/device, OAuth and the tokenserver, then Sync writes of
encrypted-looking records (the admin UI shows only counts and sizes). With the accounts:
alice@example.com, bob@example.com, carol@example.org (two-step authentication on),
dave@example.net invited, a note on alice. Sync only (the mock FxA of the tests): three
accounts known by their id, a note on each saying whose it is.

Runs inside the syncstorage-rs image (PyFxA, upstream's test helpers), with the
environment of test_fxa_flow.py and test_fxa_admin.py (fxa), test_client_flow.py (sync),
and ADMIN_URL, ADMIN_PASSWORD.
"""

import base64
import json
import os
import random
import re
import sys
import time
import uuid

import requests

ADMIN = os.environ["ADMIN_URL"].rstrip("/")

DESKTOP_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.5; rv:131.0) Gecko/20100101 Firefox/131.0"
DESKTOP_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0"
DESKTOP_LINUX = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0"
ANDROID = "Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 Firefox/131.0"
IOS = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/131.0 Mobile/15E148 Safari/605.1.15"

# every request (PyFxA's, the Sync ones, Mailpit's) with the user agent of the device at hand
USER_AGENT = [DESKTOP_MAC]
_request = requests.Session.request


def _with_user_agent(self, method, url, **kwargs):
    kwargs["headers"] = {**(kwargs.get("headers") or {}), "User-Agent": USER_AGENT[0]}
    return _request(self, method, url, **kwargs)


requests.Session.request = _with_user_agent

# the household: per person its devices (name, type, user agent) and how much it syncs
PEOPLE = [
    {"email": "alice@example.com", "devices": [("Alice's MacBook", "desktop", DESKTOP_MAC), ("Alice's iPhone", "mobile", IOS)],
     "data": {"bookmarks": 214, "history": 1180, "passwords": 38, "forms": 62, "addons": 6, "prefs": 1},
     "note": "Mum's laptop too", "totp": False},
    {"email": "bob@example.com", "devices": [("Bob's Pixel", "mobile", ANDROID), ("Bob's ThinkPad", "desktop", DESKTOP_WIN)],
     "data": {"bookmarks": 57, "history": 640, "passwords": 21, "addons": 3, "prefs": 1},
     "note": "", "totp": False},
    {"email": "carol@example.org", "devices": [("Carol's desktop", "desktop", DESKTOP_LINUX)],
     "data": {"bookmarks": 126, "history": 310, "passwords": 85, "forms": 14, "prefs": 1},
     "note": "", "totp": True},
]
INVITED = "dave@example.net"
# a payload as Firefox stores it: encrypted (the size of the record's JSON, roughly)
SIZES = {"bookmarks": 330, "history": 420, "passwords": 520, "forms": 190, "addons": 380, "prefs": 2600, "tabs": 1400, "clients": 560}


class Admin:
    """The admin UI with its password, its forms with the page's CSRF token"""

    def __init__(self):
        self.http = requests.Session()
        self.http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, allow_redirects=False, timeout=30)
        # (Sync only: http://ffs-admin:8080 inside the network, the cookie is for https)
        for cookie in self.http.cookies:
            cookie.secure = False
        assert "Sign out" in self.get("/"), "not signed in to the admin UI"

    def get(self, path):
        res = self.http.get(f"{ADMIN}{path}", timeout=30)
        assert res.status_code == 200, (path, res.status_code, res.text[:500])
        return res.text

    def post(self, path, **form):
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', self.get("/")).group(1)
        res = self.http.post(f"{ADMIN}{path}", data={"csrf": csrf, **form}, timeout=60)
        failed = re.findall(r'class="failed"[^>]*>([^<]*)', res.text)
        assert res.status_code == 200 and not failed, (path, res.status_code, failed)
        return res.text


def encrypted(rng, size):
    """What an encrypted record's payload looks like: ciphertext, IV and HMAC"""
    raw = rng.randbytes(max(16, int(size * rng.uniform(0.6, 1.4)) * 3 // 4))
    return json.dumps({"ciphertext": base64.b64encode(raw).decode(), "IV": base64.b64encode(rng.randbytes(16)).decode(),
                       "hmac": rng.randbytes(32).hex()})


def record_id(rng):
    return base64.urlsafe_b64encode(rng.randbytes(9)).decode()


def write(storage, collection, records):
    """POSTs the records 100 at a time (the server's max_post_records)"""
    for i in range(0, len(records), 100):
        for _ in range(10):
            res = storage("POST", f"/storage/{collection}", records[i:i + 100])
            # a write of the same second as the last one (MySQL): try again, as Firefox does
            if res.status_code != 503:
                break
            time.sleep(1)
        assert res.status_code == 200 and not res.json().get("failed"), (collection, res.status_code, res.text[:300])


def first_sync(storage, rng, data):
    """What the first device uploads: meta/global, the keys, then each engine's records"""
    engines = {name: {"version": 1, "syncID": record_id(rng)} for name in list(data) + ["tabs", "clients"]}
    meta = {"id": "global", "payload": json.dumps({"syncID": record_id(rng), "storageVersion": 5, "engines": engines, "declined": []})}
    assert storage("PUT", "/storage/meta/global", meta).status_code == 200
    assert storage("PUT", "/storage/crypto/keys", {"id": "keys", "payload": encrypted(rng, 280)}).status_code == 200
    for collection, count in data.items():
        write(storage, collection, [{"id": record_id(rng), "payload": encrypted(rng, SIZES[collection]),
                                     "sortindex": rng.randint(0, 1000)} for _ in range(count)])


def device_sync(storage, rng, device_id):
    """What every device writes: its clients record and its open tabs"""
    assert storage("GET", "/info/collections").status_code == 200
    write(storage, "clients", [{"id": device_id[:12], "payload": encrypted(rng, SIZES["clients"]), "ttl": 15552000}])
    write(storage, "tabs", [{"id": device_id[:12], "payload": encrypted(rng, SIZES["tabs"] * rng.randint(1, 4)), "ttl": 1814400}])


def seed_fxa():
    from fxa._utils import HawkTokenAuth
    from fxa.core import Client

    from test_fxa_admin import bearer, enable_totp, mails
    from test_fxa_flow import AUTH, MAILPIT, SYNC, storage, sync_token

    def code_after(address, seen):
        deadline = time.time() + 120
        while time.time() < deadline:
            for m in mails(address):
                if m["ID"] not in seen:
                    headers = requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}/headers", timeout=10).json()
                    for name in ("X-Verify-Short-Code", "X-Verify-Code", "X-Signin-Verify-Code"):
                        if headers.get(name):
                            return headers[name][0]
            time.sleep(1)
        raise AssertionError(f"no code for {address}")

    def sync_client(session, keys_changed_at):
        bearer_token, key_id = sync_token(session, keys_changed_at)
        res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer_token}", "X-KeyID": key_id}, timeout=30)
        assert res.status_code == 200, res.text
        token = res.json()
        return lambda method, path, body=None: storage(token, method, path, body)

    admin = Admin()
    for person in PEOPLE:
        address, password, rng = person["email"], uuid.uuid4().hex, random.Random(person["email"])
        client, keys_changed_at = None, int(time.time() * 1000)
        for n, (name, kind, agent) in enumerate(person["devices"]):
            USER_AGENT[0] = agent
            client = Client(server_url=f"{AUTH}/v1")
            seen = {m["ID"] for m in mails(address)}
            if n == 0:
                session = client.create_account(address, password, keys=True)
                session.verify_email_code(code_after(address, seen))
            else:
                session = client.login(address, password, keys=True)
                if not session.verified:
                    res = requests.post(f"{AUTH}/v1/session/verify_code", json={"code": code_after(address, seen)},
                                        auth=HawkTokenAuth(session.token, "sessionToken"), timeout=30)
                    assert res.status_code == 200, res.text
            res = requests.post(f"{AUTH}/v1/account/device", json={"name": name, "type": kind}, headers=bearer(session), timeout=30)
            assert res.status_code == 200, res.text
            sync = sync_client(session, keys_changed_at)
            if n == 0:
                first_sync(sync, rng, person["data"])
            device_sync(sync, rng, res.json()["id"])
            print(f"{address}: {name} ({kind}) signed in and synced")
        if person["totp"]:
            enable_totp(session, address)
            print(f"{address}: two-step authentication on")
        if person["note"]:
            admin.post(f"/users/{session.uid}/note", note=person["note"])
    USER_AGENT[0] = DESKTOP_MAC
    page = admin.post("/accounts/invite", email=INVITED)
    assert f"Invited {INVITED}" in page, page[:2000]
    print(f"{INVITED}: invited")


def seed_sync():
    from test_client_flow import Storage, login

    admin = Admin()
    for person in PEOPLE:
        rng = random.Random(person["email"])
        # Mozilla's accounts: the tokenserver knows the account's id only (what the mock FxA
        # of the tests passes on as user), the note says whose it is
        uid = rng.randbytes(16).hex()
        keys_changed_at = int(time.time()) - rng.randint(30, 400) * 86400
        client_state = rng.randbytes(16).hex()
        for n, (name, kind, agent) in enumerate(person["devices"]):
            USER_AGENT[0] = agent
            res = login(uid, generation=keys_changed_at, keys_changed_at=keys_changed_at, client_state=client_state)
            assert res.status_code == 200, res.text
            store = Storage(res.json())
            sync = lambda method, path, body=None: store.request(method, path, body)
            if n == 0:
                first_sync(sync, rng, person["data"])
            device_sync(sync, rng, uuid.UUID(bytes=rng.randbytes(16)).hex)
            print(f"{uid}: {name} synced")
        devices = " and ".join(name.split("'s ")[1] for name, _, _ in person["devices"])
        owner = person["email"].split("@")[0].capitalize()
        admin.post(f"/users/{uid}/note", note=f"{owner}: {devices}" + (f"; {person['note']}" if person["note"] else ""))


if __name__ == "__main__":
    {"fxa": seed_fxa, "sync": seed_sync}[sys.argv[1]]()
    print("demo seeded")
