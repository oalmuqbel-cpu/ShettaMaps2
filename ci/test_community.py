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
sys.exit(0 if ok else 1)
