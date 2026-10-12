"""A real Firefox signs up and syncs with the self-hosted Mozilla accounts.

Two Firefox profiles go through the accounts web pages like a user would: the first
signs up (confirmation code from the mail catcher) and syncs a bookmark, the second
signs in and must receive it. Runs in tests/browser (Mozilla's Firefox build and
geckodriver) on the network of tests/e2e-fxa.sh.

Environment:
  FXA_CONTENT_URL  public URL of the accounts web pages
  MAILPIT_URL      mail catcher API, e.g. http://mailpit:8025
  FIREFOX_BINARY   default: /usr/bin/firefox
  GECKODRIVER      default: /usr/local/bin/geckodriver
"""

import json
import os
import tempfile
import time
import uuid

import pytest
import requests
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.firefox.service import Service

CONTENT = os.environ["FXA_CONTENT_URL"].rstrip("/")
MAILPIT = os.environ.get("MAILPIT_URL", "http://mailpit:8025").rstrip("/")
EMAIL = f"ffs-browser-{uuid.uuid4().hex[:12]}@example.com"
PASSWORD = f"Ffs-{uuid.uuid4().hex}"
BOOKMARK_URL = "https://example.org/self-hosted-fxa"
BOOKMARK_TITLE = "Self-hosted FxA test bookmark"
CODE_INPUT = "input[autocomplete=one-time-code], input[name=code], input[inputmode=numeric]"


def start_firefox():
    profile = tempfile.mkdtemp(prefix="ffs-firefox-")
    prefs = {
        "identity.fxaccounts.autoconfig.uri": CONTENT,
        "browser.aboutwelcome.enabled": False,
        "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
        "identity.fxaccounts.loglevel": "Debug",
    }
    with open(os.path.join(profile, "user.js"), "w") as f:
        for k, v in prefs.items():
            f.write(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n")
    opts = Options()
    opts.binary_location = os.environ.get("FIREFOX_BINARY", "/usr/bin/firefox")
    opts.add_argument("-headless")
    opts.add_argument("-profile")
    opts.add_argument(profile)
    log = open(os.path.join(tempfile.gettempdir(), f"{os.path.basename(profile)}.log"), "w")
    service = Service(
        executable_path=os.environ.get("GECKODRIVER", "/usr/local/bin/geckodriver"),
        service_args=["--allow-system-access"],
        log_output=log,
    )
    return webdriver.Firefox(options=opts, service=service)


def chrome(driver, script, *args):
    """Privileged JavaScript in the browser (async: resolve with the last argument)."""
    with driver.context(driver.CONTEXT_CHROME):
        return driver.execute_async_script(script, *args)


def mail_codes(email):
    found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{email}"}, timeout=10).json()
    for message in found.get("messages", []):
        headers = requests.get(f"{MAILPIT}/api/v1/message/{message['ID']}/headers", timeout=10).json()
        for name in ("X-Verify-Short-Code", "X-Verify-Code", "X-Signin-Verify-Code"):
            if headers.get(name):
                yield headers[name][0]


def visible(driver, css):
    return [e for e in driver.find_elements(By.CSS_SELECTOR, css) if e.is_displayed() and e.is_enabled()]


def signed_in_user(driver):
    return chrome(driver, """
        const done = arguments[arguments.length - 1];
        const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
        getFxAccountsSingleton().getSignedInUser().then(u => done(u ? { email: u.email, uid: u.uid, verified: !!u.verified } : null), e => done(null));
    """)


def sign_in(driver):
    """Click 'Sign in' in the Sync preferences, then fill in the accounts pages."""
    chrome(driver, """
        const done = arguments[arguments.length - 1];
        Services.wm.getMostRecentWindow("navigator:browser").gSync.openFxAEmailFirstPage("preferences").then(() => done(), () => done());
    """)
    time.sleep(3)
    driver.switch_to.window(driver.window_handles[-1])
    used_codes = set()
    for _ in range(15):
        time.sleep(3)
        user = signed_in_user(driver)
        heading = driver.execute_script("return (document.querySelector('h1,h2')||{}).innerText||''")
        if user and (user["verified"] or "Sync is turned on" in heading or "signed in" in heading.lower()):
            return user
        if visible(driver, "input[type=email]") and not visible(driver, "input[type=password]"):
            field = visible(driver, "input[type=email]")[0]
            field.clear()
            field.send_keys(EMAIL)
        elif visible(driver, "input[type=password]"):
            for field in visible(driver, "input[type=password]"):
                field.clear()
                field.send_keys(PASSWORD)
        elif visible(driver, CODE_INPUT):
            codes = [c for c in mail_codes(EMAIL) if c not in used_codes]
            if not codes:
                continue
            used_codes.add(codes[0])
            field = visible(driver, CODE_INPUT)[0]
            field.clear()
            field.send_keys(codes[0])
        buttons = visible(driver, "button[type=submit]")
        if buttons:
            buttons[0].click()
    raise AssertionError(f"sign-in did not finish, last page: {driver.current_url.split('?')[0]} {heading!r}")


def wait_for_sync(driver, timeout=180):
    """Firefox finishes in the background: Sync keys from the web pages, then Sync itself."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = chrome(driver, """
            const done = arguments[arguments.length - 1];
            const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
            const { Weave } = ChromeUtils.importESModule("resource://services-sync/main.sys.mjs");
            getFxAccountsSingleton().keys.hasKeysForScope("https://identity.mozilla.com/apps/oldsync")
              .then(keys => done({ keys, setup: Weave.Status.checkSetup() }), e => done({ error: String(e) }));
        """)
        if state.get("keys") and state.get("setup") != "service.client_not_configured":
            return state
        time.sleep(5)
    raise AssertionError(f"Firefox never got the Sync keys: {state}")


SYNC = """
    const [url, title, done] = arguments;
    const { PlacesUtils } = ChromeUtils.importESModule("resource://gre/modules/PlacesUtils.sys.mjs");
    const { Weave } = ChromeUtils.importESModule("resource://services-sync/main.sys.mjs");
    (async () => {
      if (title) {
        await PlacesUtils.bookmarks.insert({ parentGuid: PlacesUtils.bookmarks.toolbarGuid, url, title });
      }
      for (let i = 0; i < 3; i++) { await Weave.Service.sync({ why: "user" }); }
      const found = [];
      await PlacesUtils.bookmarks.fetch({ url }, b => found.push(b.title));
      return { status: Weave.Status.sync, cluster: Weave.Service.clusterURL, found };
    })().then(done, e => done({ error: String(e) }));
"""


@pytest.fixture(scope="module")
def first_device():
    driver = start_firefox()
    yield driver
    driver.quit()


def test_sign_up_and_sync(first_device):
    user = sign_in(first_device)
    assert user["email"] == EMAIL
    wait_for_sync(first_device)
    result = chrome(first_device, SYNC, BOOKMARK_URL, BOOKMARK_TITLE)
    assert result.get("status") == "success.sync", result
    assert result["found"] == [BOOKMARK_TITLE]


def test_second_device_gets_the_bookmark(first_device):
    driver = start_firefox()
    try:
        user = sign_in(driver)
        assert user["uid"] == signed_in_user(first_device)["uid"]
        wait_for_sync(driver)
        result = chrome(driver, SYNC, BOOKMARK_URL, None)
        assert result.get("status") == "success.sync", result
        assert result["found"] == [BOOKMARK_TITLE], result
    finally:
        driver.quit()
