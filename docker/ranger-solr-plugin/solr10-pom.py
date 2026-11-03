#!/usr/bin/env python3
# plugin-solr/pom.xml 에서 감사 목적지 모듈(dest-hdfs·dest-solr) 의존을 뺀다 (2026-11-03).
# Solr 플러그인 자신의 감사는 끈다 — 감사를 Solr 에 쓰는 요청이 다시 감사되는 순환이다.
import re, sys
p = "plugin-solr/pom.xml"
s = open(p, encoding="utf-8").read()
n = s
for a in ("ranger-audit-dest-hdfs", "ranger-audit-dest-solr"):
    n = re.sub(r"\s*<dependency>\s*<groupId>[^<]*</groupId>\s*<artifactId>" + a + r"</artifactId>.*?</dependency>", "", n, flags=re.S)
if "ranger-audit-dest" in n:
    sys.exit("[pom] 감사 목적지 의존이 남았다")
open(p, "w", encoding="utf-8").write(n)
print("[pom] 감사 목적지 의존 제거")
