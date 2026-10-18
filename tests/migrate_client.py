"""A Firefox-like client for tests/migrate.sh: the same accounts before and after a move.

Runs inside a syncstorage-rs image of firefox-sync (PYTHONPATH=/app:/app/tools), on the
network of the stack it talks to, with upstream's mock FxA (FXA_OAUTH_SERVER_URL of that
stack pointing to it), like tests/test_client_flow.py whose helpers it uses.

  write              on the old server: alice and bob sign in with fixed keys (generation,
                     keys_changed_at, client_state), store meta/global, 50 bookmarks and 20
                     passwords, and their uids and /info/collections go to STATE
  check              on firefox-sync after the move: the same keys get the same uids, on the
                     new node (SYNC_PUBLIC_URL), and read back exactly what was written;
                     the moved data can be written to (one more bookmark)
  new <name> <ok|refused>   a new account, let in or refused by SYNC_MAX_USERS
  admin <n>          the admin UI's first page (trusted header) lists alice and bob with
                     what they store, and counts n accounts

Environment:
  SYNC_SERVER_URL       where the server listens (http://syncstorage:8000)
  SYNC_PUBLIC_URL    its public URL, the node URL
  STATE                 the JSON file written by write, read by check (default /state/state.json)
  ADMIN_URL             the admin UI (admin)
"""

import json
import os
import re
import sys

from test_client_flow import DOMAIN, Storage, login

STATE = os.environ.get("STATE", "/state/state.json")
# what Firefox sends after signing in: generation and keys_changed_at (seconds), the
# client state (hash of the sync key, 16 bytes)
ACCOUNTS = {
    "alice": {"generation": 1700000000, "keys_changed_at": 1700000000, "client_state": "a1" * 16},
    "bob": {"generation": 1700000100, "keys_changed_at": 1700000050, "client_state": "b2" * 16},
}
SYNC_ID = {"alice": "aliceSyncId1", "bob": "bobSyncId123"}


def items(user):
    bookmarks = [{"id": f"{user}-bm-{i:03d}", "payload": json.dumps({"ciphertext": f"{user} bookmark {i}" * 3})} for i in range(50)]
    passwords = [{"id": f"{user}-pw-{i:03d}", "payload": json.dumps({"ciphertext": f"{user} password {i}"})} for i in range(20)]
    return {"bookmarks": bookmarks, "passwords": passwords}


def fail(message):
    print(f"FAIL: {message}")
    sys.exit(1)


def expect(condition, message):
    if not condition:
        fail(message)


def sign_in(user):
    res = login(user, **ACCOUNTS[user])
    expect(res.status_code == 200, f"{user} sign-in: {res.status_code} {res.text[:300]}")
    token = res.json()
    expect(token["api_endpoint"] == f"{DOMAIN}/1.5/{token['uid']}",
           f"{user} sent to {token['api_endpoint']}, not this server's node {DOMAIN}")
    return token


def write():
    state = {}
    for user in ACCOUNTS:
        token = sign_in(user)
        storage = Storage(token)
        meta = {"id": "global", "payload": json.dumps({"syncID": SYNC_ID[user], "storageVersion": 5})}
        res = storage.request("PUT", "/storage/meta/global", meta)
        expect(res.status_code == 200, f"{user} meta/global: {res.status_code} {res.text[:300]}")
        for collection, records in items(user).items():
            res = storage.request("POST", f"/storage/{collection}", records)
            expect(res.status_code == 200 and len(res.json()["success"]) == len(records),
                   f"{user} {collection}: {res.status_code} {res.text[:300]}")
        res = storage.request("GET", "/info/collections")
        expect(res.status_code == 200, f"{user} info/collections: {res.status_code}")
        state[user] = {"uid": token["uid"], "collections": res.json()}
        print(f"{user}: uid {token['uid']} at {token['api_endpoint']}, collections {sorted(res.json())}")
    with open(STATE, "w") as f:
        json.dump(state, f, indent=1)


def check():
    with open(STATE) as f:
        state = json.load(f)
    for user in ACCOUNTS:
        token = sign_in(user)
        expect(token["uid"] == state[user]["uid"],
               f"{user} got uid {token['uid']}, had {state[user]['uid']}: a new account, its data is not found")
        storage = Storage(token)
        res = storage.request("GET", "/info/collections")
        expect(res.status_code == 200, f"{user} info/collections: {res.status_code} {res.text[:300]}")
        collections = res.json()
        saved = state[user]["collections"]
        for name in ("meta", "passwords"):
            expect(collections.get(name) == saved[name], f"{user} {name} modified {collections.get(name)}, was {saved[name]}")
        # bookmarks: one more is written below, a later check sees a newer time
        expect(collections.get("bookmarks", 0) >= saved["bookmarks"], f"{user} bookmarks {collections.get('bookmarks')} < {saved['bookmarks']}")
        res = storage.request("GET", "/storage/meta/global")
        expect(res.status_code == 200 and json.loads(res.json()["payload"])["syncID"] == SYNC_ID[user],
               f"{user} meta/global: {res.status_code} {res.text[:300]}")
        for collection, records in items(user).items():
            res = storage.request("GET", f"/storage/{collection}?full=1")
            expect(res.status_code == 200, f"{user} {collection}: {res.status_code}")
            got = {r["id"]: r["payload"] for r in res.json()}
            for r in records:
                expect(got.get(r["id"]) == r["payload"], f"{user} {collection} {r['id']} missing or changed")
        # the moved data is writable
        extra = {"id": f"{user}-after-move", "payload": json.dumps({"ciphertext": "written after the move"})}
        res = storage.request("PUT", f"/storage/bookmarks/{extra['id']}", extra)
        expect(res.status_code == 200, f"{user} write after the move: {res.status_code} {res.text[:300]}")
        res = storage.request("GET", f"/storage/bookmarks/{extra['id']}")
        expect(res.status_code == 200 and res.json()["payload"] == extra["payload"], f"{user} read after the move")
        print(f"{user}: uid {token['uid']} at {token['api_endpoint']}: meta/global, 50 bookmarks, 20 passwords as written")


def new(user, outcome):
    res = login(user, generation=1700000200, keys_changed_at=1700000200, client_state="c3" * 16)
    if outcome == "ok":
        expect(res.status_code == 200, f"new account {user} refused: {res.status_code} {res.text[:300]}")
        expect(res.json()["api_endpoint"].startswith(f"{DOMAIN}/1.5/"), f"new account {user} on {res.json()['api_endpoint']}")
        print(f"{user}: new account let in, uid {res.json()['uid']}")
    else:
        expect(res.status_code != 200, f"new account {user} let in, SYNC_MAX_USERS should refuse it")
        print(f"{user}: new account refused ({res.status_code})")


def admin(count):
    import requests

    url = os.environ["ADMIN_URL"].rstrip("/")
    res = requests.get(f"{url}/", headers={"X-Test-Email": "admin@ffs-e2e.invalid"}, timeout=30)
    expect(res.status_code == 200 and 'id="sync-accounts"' in res.text, f"admin UI: {res.status_code} {res.text[:300]}")
    page = res.text
    expect(re.search(r'id="sync-users">' + count + "<", page), f"admin UI does not count {count} accounts")
    table = page.split('id="sync-accounts"')[1].split("</table>")[0]
    for user in ACCOUNTS:
        row = re.search(r"<tr><td><a href=\"/users/" + user + r"\">.*?</tr>", table, re.S)
        # meta/global, 50 bookmarks (51 after check), 20 passwords
        expect(row and re.search(r"7[12] items", row.group(0)), f"admin UI: no row for {user} with its items: {table[:1500]}")
    print(f"admin UI: alice and bob listed with their items, {count} accounts")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "write":
        write()
    elif mode == "check":
        check()
    elif mode == "new":
        new(sys.argv[2], sys.argv[3])
    elif mode == "admin":
        admin(sys.argv[2])
    else:
        fail(f"unknown mode {mode}")
