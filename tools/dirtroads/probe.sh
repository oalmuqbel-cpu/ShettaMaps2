#!/usr/bin/env bash
# فحص أولي لحجم بيانات الطرق الترابية من مصدرين: OpenStreetMap و Microsoft Road Detections
set -x
mkdir -p work && cd work
wget -q https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf -O gcc.osm.pbf || true
ls -la
osmium fileinfo gcc.osm.pbf | head -20
osmium tags-filter gcc.osm.pbf w/highway=track w/surface=unpaved,dirt,sand,gravel,ground,earth,compacted,fine_gravel,mud -o dirt.osm.pbf --overwrite
ls -la dirt.osm.pbf
osmium export dirt.osm.pbf -f geojsonseq -o dirt.geojsonseq --overwrite --geometry-types=linestring
wc -l dirt.geojsonseq; ls -la dirt.geojsonseq
python3 - <<'PY'
import json, collections
c = collections.Counter(); named = 0; km = 0.0
import math
def d(a,b):
    R=6371000; la1,lo1,la2,lo2=map(math.radians,[a[1],a[0],b[1],b[0]])
    x=math.sin((la2-la1)/2)**2+math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(math.sqrt(x))
pts=0
for line in open("dirt.geojsonseq"):
    f=json.loads(line.lstrip("\x1e")); p=f["properties"]; g=f["geometry"]["coordinates"]
    if "highway" not in p: continue
    c[(p.get("highway"), p.get("surface"))]+=1
    if p.get("name") or p.get("name:ar"): named+=1
    pts+=len(g); km+=sum(d(g[i],g[i+1]) for i in range(len(g)-1))/1000
print("ways", sum(c.values()), "named", named, "points", pts, "km", round(km))
for k,v in c.most_common(15): print(k, v)
PY
pip install --quiet duckdb
python3 - <<'PY'
import duckdb
con = duckdb.connect()
con.execute("INSTALL httpfs; LOAD httpfs;")
con.execute("SET s3_region='us-west-2'; SET s3_url_style='path'; SET s3_endpoint='s3.us-west-2.amazonaws.com';")
base = "s3://us-west-2.opendata.source.coop/nlebovits/microsoft-ml-road-detections/road-detections/by_country"
try:
    print(con.execute(f"SELECT country, count(*) FROM read_parquet('{base}/*/*.parquet', hive_partitioning=true) WHERE country IN ('SAU','ARE','KWT','QAT','BHR','OMN','SA','AE') GROUP BY 1").fetchall())
except Exception as e:
    print("ERR1", e)
    try:
        print(con.execute(f"SELECT DISTINCT country FROM read_parquet('{base}/*/*.parquet', hive_partitioning=true)").fetchall()[:300])
    except Exception as e2: print("ERR2", e2)
PY
