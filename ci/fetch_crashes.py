# يجلب سجلات الأعطال المرسلة من TestFlight عبر App Store Connect API ويطبع أهم أسطرها
import json, os, sys, time, urllib.request, urllib.error
import jwt
key_id = os.environ["ASC_KEY_ID"]; issuer = os.environ["ASC_ISSUER_ID"]; key_path = os.environ["ASC_KEY_PATH"]
app_id = sys.argv[1]
token = jwt.encode({"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
                   open(key_path).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, path, e.read().decode()[:500]); return None
subs = get(f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions?limit=8&sort=-createdDate") or {}
os.makedirs("crashlogs", exist_ok=True)
for s in subs.get("data", []):
    sid = s["id"]; a = s.get("attributes", {})
    print("=" * 80); print(sid, a.get("createdDate"), a.get("comment"), a.get("buildBundleId"))
    log = get(f"/v1/betaFeedbackCrashSubmissions/{sid}/crashLog")
    text = (log or {}).get("data", {}).get("attributes", {}).get("logText", "")
    open(f"crashlogs/{sid}.txt", "w").write(text)
    lines = text.splitlines()
    for l in lines[:40]:
        if l.startswith(("Version:", "OS Version:", "Hardware Model:", "Date/Time:")): print(l)
    if "Last Exception Backtrace:" in text:
        i0 = next(i for i, l in enumerate(lines) if l.startswith("Last Exception Backtrace:"))
        print("\n".join(lines[i0:i0 + 60]))
    for i, l in enumerate(lines):
        if any(k in l for k in ("Exception Type", "Exception Reason", "Termination Reason", "Crashed Thread", "Triggered by Thread", "Application Specific", "Last Exception")):
            print(l)
    import re
    m = re.search(r"Triggered by Thread:\s+(\d+)", text)
    if m:
        t = m.group(1)
        idx = next((i for i, l in enumerate(lines) if l.startswith(f"Thread {t}:") or l.startswith(f"Thread {t} Crashed")), None)
        if idx is not None:
            print("\n".join(lines[idx:idx + 45]))

# ملاحظات الصور المرسلة من TestFlight
print("#" * 80); print("SCREENSHOT FEEDBACK")
shots = get(f"/v1/apps/{app_id}/betaFeedbackScreenshotSubmissions?limit=20&sort=-createdDate") or {}
os.makedirs("feedback", exist_ok=True)
for s in shots.get("data", []):
    sid = s["id"]; a = s.get("attributes", {})
    print("=" * 80)
    print(sid, a.get("createdDate"), "device:", a.get("deviceModel"), a.get("osVersion"), "build:", a.get("buildBundleId"))
    print("COMMENT:", a.get("comment"))
    for i, sc in enumerate(a.get("screenshots") or []):
        url = sc.get("url")
        if not url: continue
        try:
            with urllib.request.urlopen(url) as r: open(f"feedback/{sid}-{i}.png", "wb").write(r.read())
            print("  saved", f"feedback/{sid}-{i}.png")
        except Exception as e:
            print("  shot fail", e)
