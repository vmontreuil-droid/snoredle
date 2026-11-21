#!/usr/bin/env python3
"""Ruimt tijdelijke ontwikkelcertificaten op die door cloud-builds via de API zijn aangemaakt.

Raakt GEEN distributiecertificaten aan, en ook geen ontwikkelcertificaten die met Xcode
op een Mac zijn gemaakt. Gebruik: asc_certs.py <key_id> <issuer_id> <p8_path>
"""
import json, sys, time, urllib.request
import jwt  # pyjwt

key_id, issuer, p8 = sys.argv[1], sys.argv[2], sys.argv[3]
token = jwt.encode(
    {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
    open(p8).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

def call(method, path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as r:
        body = r.read()
        return json.loads(body) if body else None

certs = call("GET", "/v1/certificates?limit=200")["data"]
for c in certs:
    a = c["attributes"]
    print(f'- {a.get("certificateType")}: {a.get("name")} / {a.get("displayName")} (vervalt {a.get("expirationDate", "")[:10]})')

dev_types = {"DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT"}
removed = 0
for c in certs:
    a = c["attributes"]
    label = f'{a.get("name", "")} {a.get("displayName", "")}'
    if a.get("certificateType") in dev_types and "Created via API" in label:
        call("DELETE", f'/v1/certificates/{c["id"]}')
        removed += 1
        print(f'  ingetrokken: {label.strip()}')
print(f"{removed} tijdelijke ontwikkelcertificaten opgeruimd.")
