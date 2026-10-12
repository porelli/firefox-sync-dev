"""The optional QR code pairing server (fxa-pairing, Mozilla's channelserver) relays messages.

When Firefox pairs a phone, both devices open a websocket channel through this server
and exchange encrypted messages. Runs in tests/browser on the network of tests/e2e-fxa.sh.

Environment:
  FXA_PAIRING_URL  public URL of the pairing server, e.g. wss://pairing.example.com
  CA_BUNDLE        CA of the test reverse proxy
"""

import base64
import json
import os
import ssl

import websocket

PAIRING = os.environ["FXA_PAIRING_URL"].rstrip("/")
SSLOPT = {"cert_reqs": ssl.CERT_REQUIRED, "ca_certs": os.environ.get("CA_BUNDLE", "/caddy-ca/root.crt")}


def test_two_devices_exchange_a_message():
    first = websocket.create_connection(f"{PAIRING}/v1/ws/", sslopt=SSLOPT, timeout=20)
    channel = json.loads(first.recv())
    assert channel["channelid"] and channel["link"].startswith("/v1/ws/"), channel

    second = websocket.create_connection(f"{PAIRING}{channel['link']}", sslopt=SSLOPT, timeout=20)
    message = base64.urlsafe_b64encode(b"hello from the first device").decode()
    first.send(message)
    # the server also sends its own notices, look for the relayed message
    seen = []
    for _ in range(5):
        frame = json.loads(second.recv())
        seen.append(frame)
        if frame.get("message") == message:
            break
    else:
        raise AssertionError(f"message not relayed, the second device got: {seen}")
    first.close()
    second.close()
