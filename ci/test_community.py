# اختبار شامل لخدمة المشاركة: دخول مجهول، نشر، استعلام، إبلاغ، رفض بيانات مخالفة، حذف
import json, sys, urllib.request, urllib.error, uuid, datetime
KEY = "AIzaSyBAR0YbiZgooW7XuERAgAALJL7EpXikS8I"; PID = "samt-maps"
BASE = f"https://firestore.googleapis.com/v1/projects/{PID}/databases/(default)/documents"
def req(method, url, body=None, token=None):
    r = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(r) as resp: return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:300]
def fields(name="روضة اختبار", lat=25.0, lon=46.0, uid="", kind="rawdah"):
    return {"fields": {"name": {"stringValue": name}, "kind": {"stringValue": kind}, "lat": {"doubleValue": lat},
            "lon": {"doubleValue": lon}, "notes": {"stringValue": "اختبار آلي"}, "authorUid": {"stringValue": uid},
            "createdAt": {"timestampValue": datetime.datetime.utcnow().isoformat() + "Z"}, "reportCount": {"integerValue": "0"}}}
ok = True
def check(label, cond):
    global ok; print(("PASS " if cond else "FAIL ") + label); ok = ok and cond
s, a = req("POST", f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={KEY}", {"returnSecureToken": True})
check("anonymous sign-in", s == 200); tok, uid = a["idToken"], a["localId"]
doc = str(uuid.uuid4())
s, r = req("POST", f"{BASE}/places?documentId={doc}", fields(uid=uid), tok); check("create valid place", s == 200)
s, r = req("POST", f"{BASE}/places?documentId={uuid.uuid4()}", fields(uid=uid, lat=40.0), tok); check("reject outside Gulf", s == 403)
s, r = req("POST", f"{BASE}/places?documentId={uuid.uuid4()}", fields(uid="someone-else"), tok); check("reject spoofed author", s == 403)
s, r = req("POST", f"{BASE}/places?documentId={uuid.uuid4()}", fields(uid=uid)); check("reject unauthenticated create", s in (401, 403))
q = {"structuredQuery": {"from": [{"collectionId": "places"}], "where": {"compositeFilter": {"op": "AND", "filters": [
    {"fieldFilter": {"field": {"fieldPath": "lat"}, "op": "GREATER_THAN_OR_EQUAL", "value": {"doubleValue": 24.5}}},
    {"fieldFilter": {"field": {"fieldPath": "lat"}, "op": "LESS_THAN_OR_EQUAL", "value": {"doubleValue": 25.5}}}]}}, "limit": 50}}
s, rows = req("POST", f"{BASE}:runQuery?key={KEY}", q); check("public query (no auth)", s == 200 and any(doc in json.dumps(x) for x in rows))
s, a2 = req("POST", f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={KEY}", {"returnSecureToken": True}); tok2 = a2["idToken"]
commit = {"writes": [{"transform": {"document": f"projects/{PID}/databases/(default)/documents/places/{doc}",
          "fieldTransforms": [{"fieldPath": "reportCount", "increment": {"integerValue": "1"}}]}}]}
s, r = req("POST", f"{BASE}:commit", commit, tok2); check("report by another user", s == 200)
s, r = req("PATCH", f"{BASE}/places/{doc}?updateMask.fieldPaths=name", {"fields": {"name": {"stringValue": "تخريب"}}}, tok2); check("reject editing others' place", s == 403)
s, r = req("DELETE", f"{BASE}/places/{doc}", None, tok2); check("reject deleting others' place", s == 403)
s, r = req("DELETE", f"{BASE}/places/{doc}", None, tok); check("owner deletes own place", s == 200)
# مسارات المجتمع
def tfields(uid, minLat=24.6, maxLat=24.8, poly="_p~iF~ps|U_ulLnnqC_mqNvxq`@", name="مسار اختبار"):
    f = {"name": name, "notes": "اختبار آلي", "authorUid": uid, "polyline": poly}
    out = {k: {"stringValue": v} for k, v in f.items()}
    out.update({"createdAt": {"timestampValue": datetime.datetime.utcnow().isoformat() + "Z"}, "reportCount": {"integerValue": "0"},
                "distance": {"doubleValue": 1234.5}, "minLat": {"doubleValue": minLat}, "maxLat": {"doubleValue": maxLat},
                "minLon": {"doubleValue": 46.5}, "maxLon": {"doubleValue": 46.8}})
    return {"fields": out}
tdoc = str(uuid.uuid4())
s, r = req("POST", f"{BASE}/tracks?documentId={tdoc}", tfields(uid), tok); check("create valid track", s == 200)
s, r = req("POST", f"{BASE}/tracks?documentId={uuid.uuid4()}", tfields(uid, minLat=5, maxLat=6), tok); check("reject track outside Gulf", s == 403)
s, r = req("POST", f"{BASE}/tracks?documentId={uuid.uuid4()}", tfields("someone-else"), tok); check("reject spoofed track author", s == 403)
s, r = req("POST", f"{BASE}/tracks?documentId={uuid.uuid4()}", tfields(uid, poly="x" * 70000), tok); check("reject oversized track", s == 403)
tq = {"structuredQuery": {"from": [{"collectionId": "tracks"}], "where": {"compositeFilter": {"op": "AND", "filters": [
    {"fieldFilter": {"field": {"fieldPath": "minLat"}, "op": "GREATER_THAN_OR_EQUAL", "value": {"doubleValue": 22.0}}},
    {"fieldFilter": {"field": {"fieldPath": "minLat"}, "op": "LESS_THAN_OR_EQUAL", "value": {"doubleValue": 25.5}}}]}}, "limit": 50}}
s, rows = req("POST", f"{BASE}:runQuery?key={KEY}", tq); check("public track query", s == 200 and any(tdoc in json.dumps(x) for x in rows))
s, r = req("DELETE", f"{BASE}/tracks/{tdoc}", None, tok2); check("reject deleting others' track", s == 403)
s, r = req("DELETE", f"{BASE}/tracks/{tdoc}", None, tok); check("owner deletes own track", s == 200)
# الرحلة الآمنة
import random, string
def sfields(uid, hours=6, lat=24.7, active=True):
    now = datetime.datetime.utcnow().isoformat() + "Z"
    return {"fields": {"owner": {"stringValue": uid}, "name": {"stringValue": "اختبار"}, "hours": {"integerValue": str(hours)},
            "startedAt": {"timestampValue": now}, "updatedAt": {"timestampValue": now}, "lat": {"doubleValue": lat},
            "lon": {"doubleValue": 46.6}, "acc": {"doubleValue": 8.0}, "active": {"booleanValue": active}}}
stoken = "".join(random.choice(string.ascii_letters) for _ in range(24))
s, r = req("PATCH", f"{BASE}/safetrips/{stoken}", sfields(uid), tok); check("create safe trip", s == 200)
s, r = req("GET", f"{BASE}/safetrips/{stoken}?key={KEY}"); check("public get safe trip by token", s == 200 and "اختبار" in json.dumps(r, ensure_ascii=False))
s, r = req("PATCH", f"{BASE}/safetrips/{stoken}", sfields(uid, lat=24.9), tok2); check("reject others updating safe trip", s == 403)
s, r = req("PATCH", f"{BASE}/safetrips/{stoken}", sfields(uid, hours=500), tok); check("reject invalid hours", s == 403)
s, r = req("PATCH", f"{BASE}/safetrips/short123", sfields(uid), tok); check("reject short token", s == 403)
lq = {"structuredQuery": {"from": [{"collectionId": "safetrips"}], "limit": 5}}
s, r = req("POST", f"{BASE}:runQuery?key={KEY}", lq); check("reject listing safe trips", s == 403)
s, r = req("PATCH", f"{BASE}/safetrips/{stoken}", sfields(uid, active=False), tok); check("owner ends safe trip", s == 200)
s, r = req("DELETE", f"{BASE}/safetrips/{stoken}", None, tok); check("owner deletes safe trip", s == 200)
# تغطية الشبكة
def cfields(uid, level="data", carrier="stc", lat=24.71, radio="4G"):
    return {"fields": {"cell": {"stringValue": "24.710_46.675"}, "lat": {"doubleValue": lat}, "lon": {"doubleValue": 46.675},
            "carrier": {"stringValue": carrier}, "level": {"stringValue": level}, "source": {"stringValue": "auto"},
            "author": {"stringValue": uid}, "at": {"timestampValue": datetime.datetime.utcnow().isoformat() + "Z"},
            "radio": {"stringValue": radio}}}
cid = f"24.710_46.675_stc_{uid}"
s, r = req("PATCH", f"{BASE}/coverage/{cid}", cfields(uid), tok); check("create coverage sample", s == 200)
s, r = req("PATCH", f"{BASE}/coverage/{cid}", cfields(uid, level="none"), tok); check("update own coverage sample", s == 200)
s, r = req("PATCH", f"{BASE}/coverage/{cid}", cfields(uid), tok2); check("reject writing others' coverage", s == 403)
s, r = req("PATCH", f"{BASE}/coverage/24.710_46.675_stc_{a2['localId']}", cfields(uid), tok2); check("reject spoofed coverage author", s == 403)
s, r = req("PATCH", f"{BASE}/coverage/{cid}", cfields(uid, level="great"), tok); check("reject invalid level", s == 403)
s, r = req("PATCH", f"{BASE}/coverage/{cid}", cfields(uid, lat=50.0), tok); check("reject coverage outside Gulf", s == 403)
cq = {"structuredQuery": {"from": [{"collectionId": "coverage"}], "where": {"compositeFilter": {"op": "AND", "filters": [
    {"fieldFilter": {"field": {"fieldPath": "lat"}, "op": "GREATER_THAN_OR_EQUAL", "value": {"doubleValue": 24.6}}},
    {"fieldFilter": {"field": {"fieldPath": "lat"}, "op": "LESS_THAN_OR_EQUAL", "value": {"doubleValue": 24.8}}}]}}, "limit": 50}}
s, rows = req("POST", f"{BASE}:runQuery?key={KEY}", cq); check("public coverage query", s == 200 and any(cid in json.dumps(x) for x in rows))
s, r = req("DELETE", f"{BASE}/coverage/{cid}", None, tok); check("owner deletes coverage sample", s == 200)
# معرّف سَمْت والمتابعون
code = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
cf = lambda u: {"fields": {"uid": {"stringValue": u}, "createdAt": {"timestampValue": datetime.datetime.utcnow().isoformat() + "Z"}}}
s, r = req("POST", f"{BASE}/codes?documentId={code}", cf(uid), tok); check("create samt code", s == 200)
s, r = req("POST", f"{BASE}/codes?documentId=abc12345", cf(uid), tok); check("reject invalid code format", s == 403)
s, r = req("POST", f"{BASE}/codes?documentId={code[::-1]}", cf(a2["localId"]), tok); check("reject code for another user", s == 403)
s, r = req("GET", f"{BASE}/codes/{code}?key={KEY}"); check("public resolve code", s == 200 and uid in json.dumps(r))
wtoken = "".join(random.choice(string.ascii_letters) for _ in range(24))
wf = sfields(uid); wf["fields"]["watchers"] = {"arrayValue": {"values": [{"stringValue": a2["localId"]}]}}; wf["fields"]["code"] = {"stringValue": code}
s, r = req("PATCH", f"{BASE}/safetrips/{wtoken}", wf, tok); check("create trip with watchers", s == 200)
wq = {"structuredQuery": {"from": [{"collectionId": "safetrips"}], "where": {"fieldFilter": {"field": {"fieldPath": "watchers"}, "op": "ARRAY_CONTAINS", "value": {"stringValue": a2["localId"]}}}, "limit": 10}}
s, rows = req("POST", f"{BASE}:runQuery", wq, tok2); check("watcher lists followed trips", s == 200 and wtoken in json.dumps(rows))
s, rows = req("POST", f"{BASE}:runQuery", wq, tok); check("reject non-watcher listing", s == 403)
s, r = req("DELETE", f"{BASE}/safetrips/{wtoken}", None, tok); check("owner deletes watched trip", s == 200)
s, r = req("DELETE", f"{BASE}/codes/{code}", None, tok); check("owner deletes code", s == 200)
sys.exit(0 if ok else 1)
