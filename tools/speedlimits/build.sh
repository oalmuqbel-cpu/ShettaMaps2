#!/usr/bin/env bash
# حدود السرعة المسجلة في OpenStreetMap لطرق الخليج، مقسمة إلى خلايا 1°×1° للتنزيل حسب المنطقة.
set -euo pipefail
mkdir -p work out && cd work
[ -f gcc.osm.pbf ] || wget -q https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf -O gcc.osm.pbf
osmium tags-filter gcc.osm.pbf w/maxspeed w/maxspeed:forward w/maxspeed:backward -o speed.osm.pbf --overwrite
osmium export speed.osm.pbf -f geojsonseq -o speed.geojsonseq --overwrite --geometry-types=linestring
python3 ../tools/speedlimits/build.py speed.geojsonseq ../out
ls -la ../out | head; du -sh ../out
