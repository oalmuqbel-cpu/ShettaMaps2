#!/usr/bin/env bash
# يبني بيانات الردميات والطرق الترابية لدول الخليج من مصدرين ويقسمها إلى خلايا 2°×2° للتنزيل حسب المنطقة.
# 1) OpenStreetMap (ODbL) عبر Geofabrik  2) Microsoft Road Detections (ODbL) لما لا يوجد في OSM.
set -euo pipefail
mkdir -p work out && cd work
[ -f gcc.osm.pbf ] || wget -q https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf -O gcc.osm.pbf
osmium tags-filter gcc.osm.pbf w/highway -o roads.osm.pbf --overwrite
osmium export roads.osm.pbf -f geojsonseq -o roads.geojsonseq --overwrite --geometry-types=linestring
pip install --quiet duckdb numpy
python3 ../tools/dirtroads/build.py roads.geojsonseq ../out
ls -la ../out | head; du -sh ../out
