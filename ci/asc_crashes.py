#!/usr/bin/env python3
"""Haalt de laatste TestFlight-crashrapporten op en toont alleen de gecrashte thread
(repo is openbaar: geen volledige logs met toestelgegevens afdrukken)."""
import json, sys, time, urllib.request, urllib.error
import jwt

key_id, issuer, p8 = sys.argv[1], sys.argv[2], sys.argv[3]
token = jwt.encode({"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
                   open(p8).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

def call(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, path, e.read()[:300]); return None

apps = call("/v1/apps?filter[bundleId]=be.snoredle.app")
app_id = apps["data"][0]["id"]
subs = call(f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions?limit=3&sort=-createdDate")
for s in (subs or {}).get("data", []):
    a = s["attributes"]
    print("=== crash", a.get("createdDate"), "build?", a.get("appPlatform"), a.get("osVersion"), a.get("deviceModel"))
    log = call(f"/v1/betaFeedbackCrashSubmissions/{s['id']}/crashLog")
    text = ((log or {}).get("data") or {}).get("attributes", {}).get("logText", "") or ""
    lines = text.splitlines()
    keep, on = [], False
    for l in lines:
        if l.startswith(("Version:", "Exception Type", "Exception Codes", "Termination Reason", "Crashed Thread", "Triggered by Thread")):
            keep.append(l)
        if "Crashed:" in l or "crashed" in l.lower() and l.startswith("Thread"):
            on = True; keep.append(l); continue
        if on:
            if not l.strip(): break
            keep.append(l)
    # Fatal error-tekst (Swift) staat vaak bij Application Specific Information
    for i, l in enumerate(lines):
        if "Fatal error" in l or "Application Specific" in l:
            keep += lines[i:i+3]
    print("\n".join(keep[:60]) or text[:1500])
