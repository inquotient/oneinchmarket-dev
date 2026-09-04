import xml.etree.ElementTree as ET, shutil, sys
p = "/conf/config.xml"
shutil.copy(p, "/conf/config.xml.pre-evelog")
t = ET.parse(p); r = t.getroot()
ev = r.find("./OPNsense/IDS/general/eveLog")
if ev is None:
    print("FAIL: eveLog not found"); sys.exit(1)
n = 0
for proto in ("http", "tls"):
    node = ev.find(proto)
    if node is None: continue
    for k, v in (("enable", "1"), ("extended", "1")):
        e = node.find(k)
        if e is None:
            e = ET.SubElement(node, k)
        if e.text != v:
            e.text = v; n += 1
t.write(p, encoding="UTF-8", xml_declaration=True)
print("CHANGED", n, "fields")
