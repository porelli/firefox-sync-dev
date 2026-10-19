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
import re
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


def start_firefox(**extra_prefs):
    profile = tempfile.mkdtemp(prefix="ffs-firefox-")
    prefs = {
        "identity.fxaccounts.autoconfig.uri": CONTENT,
        "browser.aboutwelcome.enabled": False,
        "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
        "identity.fxaccounts.loglevel": "Debug",
        **extra_prefs,
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

    def finished(heading):
        user = signed_in_user(driver)
        if user and (user["verified"] or "Sync is turned on" in heading or "signed in" in heading.lower()):
            return user

    return fill_in_accounts_pages(driver, finished)


def fill_in_accounts_pages(driver, finished, used_codes=()):
    """The accounts pages, page after page, until finished(heading) returns something.
    used_codes: confirmation codes already in the mailbox, not for this sign-in."""
    used_codes = set(used_codes)
    for _ in range(15):
        time.sleep(3)
        heading = driver.execute_script("return (document.querySelector('h1,h2')||{}).innerText||''")
        result = finished(heading)
        if result:
            return result
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


def test_admin_shows_the_devices_and_the_data(first_device):
    # the two Firefox profiles above, as the admin UI sees them
    if not os.environ.get("ADMIN_PASSWORD"):
        pytest.skip("no admin UI")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    http = requests.Session()
    http.verify = "/caddy-ca/root.crt"
    http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    uid = signed_in_user(first_device)["uid"]
    page = http.get(f"{admin}/users/{uid}", timeout=30).text
    assert EMAIL in page, page[:1000]
    # errors of the queries (Devices: ..., Sync storage: ...)
    assert 'class="failed"' not in page, re.findall(r'class="failed"[^>]*>([^<]*)', page)
    devices = page.split('<table id="devices"')[1].split("</table>")[0]
    assert devices.count("<tr><td>") >= 2 and "Firefox" in devices, devices
    collections = page.split('<table id="collections"')[1].split("</table>")[0]
    assert "<td>bookmarks</td>" in collections, collections


def test_admin_sign_in_with_the_account(first_device):
    # the admin UI signs in with these accounts: ADMIN_ALLOWED_USERS=@example.com in
    # tests/e2e-fxa.sh, a new Firefox with the account of the tests above
    if not os.environ.get("ADMIN_FXA_CLIENT_ID"):
        pytest.skip("the admin UI does not sign in with these accounts")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    driver = start_firefox()
    try:
        stale = set(mail_codes(EMAIL))
        driver.get(f"{admin}/login")
        driver.find_element(By.LINK_TEXT, "Sign in with Mozilla account").click()

        def finished(heading):
            # the callback's page moves on to the dashboard by itself
            if driver.current_url == f"{admin}/" and "Sign out" in driver.page_source:
                return driver.page_source

        page = fill_in_accounts_pages(driver, finished, used_codes=stale)
        assert f'<span class="hint">{EMAIL}</span>' in page, page[:2000]
    finally:
        driver.quit()


def test_refused_sign_up_shows_an_error():
    # FXA_SIGNUP_ALLOWLIST of tests/e2e-fxa.sh: example.org is not on it
    driver = start_firefox()
    try:
        driver.get(f"{CONTENT}/")
        address = f"ffs-refused-{uuid.uuid4().hex[:8]}@example.org"
        text = ""
        for _ in range(10):
            time.sleep(3)
            text = driver.execute_script("return document.body.innerText")
            if "blocked" in text.lower():
                break
            if visible(driver, CODE_INPUT):
                raise AssertionError("refused sign-up got to the confirmation code")
            if visible(driver, "input[type=email]") and not visible(driver, "input[type=password]"):
                field = visible(driver, "input[type=email]")[0]
                field.clear()
                field.send_keys(address)
            elif visible(driver, "input[type=password]"):
                for field in visible(driver, "input[type=password]"):
                    field.clear()
                    field.send_keys(PASSWORD)
            buttons = visible(driver, "button[type=submit]")
            if buttons:
                buttons[0].click()
        assert "blocked" in text.lower(), text[:600]
    finally:
        driver.quit()


def admin_browser(**prefs):
    """A Firefox signed in to the admin UI with the password, or None without it"""
    if not os.environ.get("ADMIN_PASSWORD"):
        return None, None
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    driver = start_firefox(**prefs)
    driver.get(f"{admin}/login")
    driver.find_element(By.ID, "password").send_keys(os.environ["ADMIN_PASSWORD"])
    driver.find_element(By.CSS_SELECTOR, "form[action='/login'] button[type=submit]").click()
    for _ in range(20):
        if driver.current_url == f"{admin}/" and "Sign out" in driver.page_source:
            return driver, admin
        time.sleep(0.5)
    driver.quit()
    raise AssertionError(f"admin sign-in failed: {driver.current_url}")


def test_admin_fits_a_phone():
    # a window is at least 500 px wide: zoomed in to 139%, the page gets 360 CSS pixels,
    # like most phones (the media queries follow the zoom)
    driver, admin = admin_browser()
    if not driver:
        pytest.skip("no admin UI")
    try:
        driver.set_window_size(500, 1028)
        for path in ("/", "/activity", "/security", "/config"):
            driver.get(f"{admin}{path}")
            with driver.context(driver.CONTEXT_CHROME):
                driver.execute_script("gBrowser.selectedBrowser.fullZoom = 500 / 360")
            time.sleep(0.5)
            width = driver.execute_script("return window.innerWidth")
            assert 350 <= width <= 370, f"the window is {width} CSS px wide"
            # the page itself does not scroll sideways, the wide tables do in their box
            scroll = driver.execute_script("return Math.max(document.body.scrollWidth, document.documentElement.scrollWidth)")
            # (what sticks out, for the error)
            widest = driver.execute_script("""return [...document.querySelectorAll('body *')].map(e => [e.getBoundingClientRect().right, e.tagName + '.' + e.className])
                .sort((x, y) => y[0] - x[0]).slice(0, 3)""")
            assert scroll <= width, (path, scroll, width, widest)
            # the stylesheet applies (style-src 'self' of the CSP): buttons tall enough to tap
            # (the shown ones: those of a closed <details> have no box)
            heights = driver.execute_script("return [...document.querySelectorAll('main button, header nav a')].map(e => e.getBoundingClientRect().height).filter(h => h > 0)")
            assert heights and min(heights) >= 44, (path, heights)
            if path == "/":
                accounts = driver.find_element(By.ID, "accounts")
                assert accounts.find_element(By.XPATH, "..").get_attribute("class") == "scroll"
    finally:
        driver.quit()


def test_admin_disables_through_the_confirm_page(first_device):
    # last of the tests of this account: it gets signed out, then enabled again
    driver, admin = admin_browser()
    if not driver:
        pytest.skip("no admin UI")
    try:
        uid = signed_in_user(first_device)["uid"]
        # the account through the search of the list (50 a page)
        driver.find_element(By.ID, "find-q").send_keys(EMAIL)
        driver.find_element(By.CSS_SELECTOR, "#find button[type=submit]").click()
        time.sleep(1)
        driver.find_element(By.CSS_SELECTOR, f'tr[data-email="{EMAIL}"] a[href="/accounts/{uid}/disable"]').click()
        assert driver.current_url == f"{admin}/accounts/{uid}/disable"
        page = driver.page_source
        assert f"Disable {EMAIL}?" in page and "Firefox" in page.split('id="confirm-devices"')[1], page[:3000]
        # the CSP blocks inline styles and scripts: the page is styled by the stylesheet only
        color = driver.execute_script("return getComputedStyle(document.querySelector('#confirm button.danger')).backgroundColor")
        assert color == "rgb(180, 35, 42)", color
        assert driver.find_element(By.ID, "cancel").get_attribute("href") == f"{admin}/users/{uid}"
        driver.find_element(By.ID, "reason").send_keys("browser test")
        driver.find_element(By.CSS_SELECTOR, "#confirm button[type=submit]").click()
        time.sleep(1)
        assert driver.current_url == f"{admin}/users/{uid}", driver.current_url
        message = driver.find_element(By.CSS_SELECTOR, "p.message[role=status]").text
        assert message.startswith(f"Disabled {EMAIL} (uid {uid[:8]})"), message
        assert "disabled" in driver.find_element(By.TAG_NAME, "main").text
        # enabling is one click
        driver.find_element(By.CSS_SELECTOR, f'form[action="/accounts/{uid}/enable"] button').click()
        time.sleep(1)
        assert driver.find_element(By.CSS_SELECTOR, "p.message[role=status]").text.startswith(f"Enabled {EMAIL}")
    finally:
        driver.quit()


def test_invite_link_fills_in_the_email():
    # the link of an invitation (docs/admin/accounts.md#invitations): the accounts pages open with the email filled in
    if not os.environ.get("ADMIN_PASSWORD"):
        pytest.skip("no admin UI")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    http = requests.Session()
    http.verify = "/caddy-ca/root.crt"
    http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', http.get(f"{admin}/", timeout=30).text).group(1)
    address = f"ffs-invite-{uuid.uuid4().hex[:8]}@example.com"
    res = http.post(f"{admin}/accounts/invite", data={"csrf": csrf, "email": address}, timeout=30)
    assert f"Invited {address}" in res.text, res.text[:2000]
    link = None
    for _ in range(30):
        found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{address}"}, timeout=10).json().get("messages", [])
        if found:
            text = requests.get(f"{MAILPIT}/api/v1/message/{found[0]['ID']}", timeout=10).json()["Text"]
            link = re.search(r"https://\S+/\?email=\S+", text).group(0)
            break
        time.sleep(1)
    assert link and link.startswith(CONTENT), link
    driver = start_firefox()
    try:
        driver.get(link)
        seen = ""
        for _ in range(20):
            time.sleep(1.5)
            values = [e.get_attribute("value") for e in visible(driver, "input[type=email]")]
            seen = " ".join(values) + " " + driver.execute_script("return document.body.innerText")
            if address in seen:
                break
        # filled in the email field, or shown on the sign-up page it moves on to
        assert address in seen, (driver.current_url.split("?")[0], seen[:600])
        print(f"invite link: {driver.current_url.split('?')[0]}, email in a field: {address in values}")
    finally:
        driver.quit()
