set -x; set +e; pip install -q pillow
O=ci/probe/out; rm -rf $O; mkdir -p $O
B="https://view.eumetsat.int/geoserver"
curl -s -m 60 "$B/msg_iodc/h63/ows?service=WMS&request=GetCapabilities&version=1.3.0" -o $O/caps.xml; ls -la $O/caps.xml
grep -o '<Dimension[^>]*>[^<]*</Dimension>' $O/caps.xml | cut -c1-600 > $O/dims.txt
tr -d "\n" < $O/caps.xml | grep -o "<Style>.\{0,600\}" | head -c 3000 > $O/styles.txt; head -c 7000 $O/caps.xml
grep -o 'EPSG:3857' $O/caps.xml | head -1 > $O/has3857.txt
curl -s -m 60 "$B/wms?service=WMS&request=GetLegendGraphic&format=application/json&layer=msg_iodc:h63" -o $O/legend.json; head -c 4000 $O/legend.json > $O/legend_head.txt
curl -s -m 60 -o $O/saudi.png -w "%{http_code} %{content_type} %{size_download}\n" "$B/wms?service=WMS&version=1.3.0&request=GetMap&layers=msg_iodc:h63&styles=&crs=EPSG:4326&bbox=12,34,33,60&width=520&height=420&format=image/png&transparent=true" > $O/getmap.txt
curl -s -m 60 -o $O/tile3857.png -w "%{http_code} %{content_type} %{size_download}\n" "$B/wms?service=WMS&version=1.1.1&request=GetMap&layers=msg_iodc:h63&styles=&srs=EPSG:3857&bbox=3757032,1252344,6261721,3757032&width=256&height=256&format=image/png&transparent=true" >> $O/getmap.txt
curl -s -m 60 -o $O/mtg.png -w "%{http_code} %{content_type} %{size_download}\n" "$B/wms?service=WMS&version=1.3.0&request=GetMap&layers=mtg_fd:h40b&styles=&crs=EPSG:4326&bbox=12,34,33,60&width=520&height=420&format=image/png&transparent=true" >> $O/getmap.txt
curl -s -m 60 "$B/mtg_fd/h40b/ows?service=WMS&request=GetCapabilities&version=1.3.0" | grep -o '<Dimension[^>]*>[^<]*</Dimension>' | cut -c1-600 > $O/dims_mtg.txt
python3 - <<'PY'
from PIL import Image
import collections
for f in ['ci/probe/out/saudi.png','ci/probe/out/mtg.png']:
    try:
        im=Image.open(f).convert('RGBA'); c=collections.Counter(p for p in im.getdata() if p[3]>0)
        print(f, im.size, 'colored px', sum(c.values()), c.most_common(15))
    except Exception as e: print(f, e)
PY
