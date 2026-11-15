# يعرض صلاحيات معرّف التطبيق، ويحاول تفعيل CarPlay للملاحة إن لم تكن مفعلة (لا يوقف البناء عند الفشل).
import json, os, sys, time, urllib.request, urllib.error
import jwt

token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 600,
                    "aud": "appstoreconnect-v1"}, open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                   headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

bundle = sys.argv[1]
_, found = call("GET", f"/v1/bundleIds?filter[identifier]={bundle}&limit=5")
bid = next(d["id"] for d in found["data"] if d["attributes"]["identifier"] == bundle)
_, caps = call("GET", f"/v1/bundleIds/{bid}/bundleIdCapabilities")
types = [c["attributes"]["capabilityType"] for c in caps.get("data", [])]
print("Capabilities:", types)
if any("CARPLAY" in t for t in types):
    print("CarPlay capability already enabled"); sys.exit(0)
for t in ["CARPLAY_NAVIGATION", "CARPLAY_MAPS", "CARPLAY"]:
    code, res = call("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
        "attributes": {"capabilityType": t}, "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
    print(t, code, str(res)[:400])
    if code in (200, 201):
        print("Enabled", t); sys.exit(0)
print("::warning::Could not enable CarPlay via API; enable it in the developer portal.")
