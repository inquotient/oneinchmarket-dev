#!/usr/bin/env python3
# ET Open 룰셋을 OPNsense 의 config.xml 에 등록한다.
#
# 실행: OPNsense 위에서 `python3 enable-et-open.py`
#       그 다음 반드시 두 단계를 이어서 한다:
#         configctl template reload OPNsense/IDS   # rule-updater.config 재생성
#         configctl ids update                     # 실제 다운로드
#         configctl ids restart
#
# ★ template reload 를 빼먹으면 `configctl ids update` 가 **OK 를 출력하고
#   아무것도 받지 않는다.** config.xml 을 직접 고치면 OPNsense 의 설정 반영
#   경로를 타지 않기 때문이다. 실측으로 한 번 속았다(§8-50).
#
# ★ 46종 전부가 아니라 23종만 켠다. chat·games·p2p·inappropriate·info 등은
#   랩의 목적(침입 탐지 검증)과 무관한 소음이고, Suricata RSS 가 규칙 수에
#   비례해 늘어난다. 23종 = 36,818 규칙 = 디스크 62 MB · RSS 약 1.2 GB.
#   VM 메모리가 6 GB 이므로 여유가 있으나 전부 켜면 재산정이 필요하다.
#
# ★ 선행 조건: 디스크. nano 이미지는 루트가 2.8 GB 이고 82% 차 있어
#   여유가 482 MB 뿐이었다. README 의 "디스크 확장" 절을 먼저 볼 것.
import xml.etree.ElementTree as ET, uuid, shutil, sys
SETS = """emerging-attack_response emerging-coinminer emerging-current_events
emerging-dns emerging-dos emerging-exploit emerging-exploit_kit emerging-ftp
emerging-malware emerging-mobile_malware emerging-netbios emerging-phishing
emerging-rpc emerging-scan emerging-shellcode emerging-smtp emerging-sql
emerging-telnet emerging-user_agents emerging-web_client emerging-web_server
emerging-web_specific_apps emerging-worm""".split()
p = "/conf/config.xml"
shutil.copy(p, "/conf/config.xml.pre-etopen")
t = ET.parse(p); r = t.getroot()
files = r.find("./OPNsense/IDS/files")
if files is None:
    print("FAIL: <files> not found"); sys.exit(1)
have = {f.findtext("filename") for f in files.findall("file")}
n = 0
for s in SETS:
    fn = s + ".rules"
    if fn in have: continue
    e = ET.SubElement(files, "file"); e.set("uuid", str(uuid.uuid4()))
    ET.SubElement(e, "enabled").text = "1"
    ET.SubElement(e, "filename").text = fn
    ET.SubElement(e, "filter").text = ""
    n += 1
t.write(p, encoding="UTF-8", xml_declaration=True)
print("ADDED", n, "of", len(SETS))