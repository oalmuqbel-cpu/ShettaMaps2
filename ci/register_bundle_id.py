# يسجّل معرّف التطبيق (Bundle ID) في حساب المطوّر عبر App Store Connect API إن لم يكن مسجلًا.
import json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT

key_id = os.environ["ASC_KEY_ID"]
issuer = os.environ["ASC_ISSUER_ID"]
key_path = os.environ["ASC_KEY_PATH"]
bundle_id = sys.argv[1]
name = sys.argv[2]

token = jwt.encode({"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
                   open(key_path).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(e.code, e.read().decode()); raise

found = call("GET", f"/v1/bundleIds?filter[identifier]={bundle_id}&limit=5")
if any(d["attributes"]["identifier"] == bundle_id for d in found.get("data", [])):
    print(f"Bundle ID already registered: {bundle_id}")
else:
    call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": bundle_id, "name": name, "platform": "IOS"}}})
    print(f"Registered Bundle ID: {bundle_id}")

apps = call("GET", f"/v1/apps?filter[bundleId]={bundle_id}&limit=5")
if apps.get("data"):
    print("App record exists in App Store Connect")
else:
    print("::warning::App record not found in App Store Connect. Create it (My Apps > + > New App) then rerun.")
    sys.exit(2)
