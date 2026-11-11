# إعداد رابط TestFlight عام للتجربة الخارجية عبر App Store Connect API
# الوضع status: يعرض الحالة فقط. الوضع setup: ينشئ المجموعة والرابط ويرسل النسخة لمراجعة Beta.
# لا يطبع أي بيانات شخصية (البريد والجوال تُقرأ من الأسرار ولا تظهر في السجل).
import json, os, sys, time, urllib.request, urllib.error
import jwt
APP = "6833357928"
mode = sys.argv[1] if len(sys.argv) > 1 else "status"
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                 headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read(); return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode()
        try: msg = "; ".join(f"{x.get('code')}: {x.get('detail')}" for x in json.loads(msg)["errors"])
        except Exception: pass
        print(f"HTTP {e.code} {method} {path.split('?')[0]} -> {msg[:600]}"); return None

builds = call("GET", f"/v1/builds?filter[app]={APP}&sort=-uploadedDate&limit=3&include=buildBetaDetail") or {}
for b in builds.get("data", []):
    a = b["attributes"]; print("build", a["version"], a["processingState"], "expired" if a.get("expired") else "")
inc = {i["id"]: i["attributes"] for i in builds.get("included", [])}
for i, a in inc.items(): print("  external state:", a.get("externalBuildState"), "internal:", a.get("internalBuildState"))
groups = call("GET", f"/v1/apps/{APP}/betaGroups?limit=20") or {}
for g in groups.get("data", []):
    a = g["attributes"]; print("group", a["name"], "internal" if a["isInternalGroup"] else "external",
                               "publicLink:", a.get("publicLink"), "enabled:", a.get("publicLinkEnabled"))
loc = call("GET", f"/v1/apps/{APP}/betaAppLocalizations") or {}
for l in loc.get("data", []):
    a = l["attributes"]; print("localization", a["locale"], "desc:", bool(a.get("description")), "feedbackEmail:", bool(a.get("feedbackEmail")))
rd = call("GET", f"/v1/apps/{APP}/betaAppReviewDetail") or {}
ra = rd.get("data", {}).get("attributes", {})
print("reviewDetail contact set:", all(ra.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")))
if mode != "setup": sys.exit(0)

E = os.environ
latest = builds["data"][0]
if latest["attributes"]["processingState"] != "VALID": sys.exit("آخر نسخة لم تنتهِ معالجتها بعد")
desc = ("تطبيق ملاحة برية للمملكة العربية السعودية ودول الخليج: خرائط تفاعلية وخرائط دون اتصال، "
        "تسجيل المسارات، حفظ المواقع والإحداثيات، والعودة لنقطة البداية. جرّب تنزيل خريطة منطقة، وحفظ موقع، "
        "وتسجيل مسار قصير، والبحث عن روضة أو جبل.")
ar = [l for l in loc.get("data", []) if l["attributes"]["locale"] in ("ar-SA", "ar")]
attrs = {"description": desc}
if E.get("CONTACT_EMAIL"): attrs["feedbackEmail"] = E["CONTACT_EMAIL"]
if ar: call("PATCH", f"/v1/betaAppLocalizations/{ar[0]['id']}", {"data": {"type": "betaAppLocalizations", "id": ar[0]["id"], "attributes": attrs}})
else:
    r = call("POST", "/v1/betaAppLocalizations", {"data": {"type": "betaAppLocalizations", "attributes": {"locale": "ar-SA", **attrs},
             "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if r is None and not loc.get("data"):
        call("POST", "/v1/betaAppLocalizations", {"data": {"type": "betaAppLocalizations", "attributes": {"locale": "en-US", **attrs},
             "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
print("localization ok")
if rd.get("data") and E.get("CONTACT_PHONE"):
    r = call("PATCH", f"/v1/betaAppReviewDetails/{rd['data']['id']}", {"data": {"type": "betaAppReviewDetails", "id": rd["data"]["id"], "attributes": {
        "contactFirstName": E["CONTACT_FIRST"], "contactLastName": E["CONTACT_LAST"], "contactPhone": E["CONTACT_PHONE"],
        "contactEmail": E["CONTACT_EMAIL"], "demoAccountRequired": False,
        "notes": "التطبيق لا يتطلب تسجيل دخول. ميزة المشاركة المجتمعية اختيارية وتتطلب قبول الشروط داخل التطبيق، وتتيح الإبلاغ عن المحتوى وحجب الناشر."}}})
    print("review detail", "ok" if r is not None else "FAILED")
ext = [g for g in groups.get("data", []) if not g["attributes"]["isInternalGroup"]]
if ext: gid = ext[0]["id"]
else:
    r = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": {"name": "تجربة عامة"},
             "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if r is None: sys.exit(1)
    gid = r["data"]["id"]
call("POST", f"/v1/betaGroups/{gid}/relationships/builds", {"data": [{"type": "builds", "id": latest["id"]}]})
r = call("PATCH", f"/v1/betaGroups/{gid}", {"data": {"type": "betaGroups", "id": gid, "attributes": {
    "publicLinkEnabled": True, "publicLinkLimitEnabled": True, "publicLinkLimit": 1000, "feedbackEnabled": True}}})
s = call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
         "relationships": {"build": {"data": {"type": "builds", "id": latest["id"]}}}}})
print("review submission:", (s or {}).get("data", {}).get("attributes", {}).get("betaReviewState", "see error above"))
g = call("GET", f"/v1/betaGroups/{gid}") or {}
print("PUBLIC LINK:", g.get("data", {}).get("attributes", {}).get("publicLink"))
