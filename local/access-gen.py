# -*- coding: utf-8 -*-
"""local/ACCESS.md 의 접근 대상 표 생성기.

손으로 적으면 빠진다 — 첫 판이 서비스 90여 개 중 40여 개만 담았다.
살아 있는 클러스터의 **모든 Service x 모든 포트**를 나열하고, 규칙에 없는
것은 `미분류` 로 남긴다. 서비스가 늘면 다시 돌릴 것.

  python3 local/access-gen.py          # 표 형식
  python3 local/access-gen.py --md     # 마크다운 표

종류
  UI   브라우저로 본다
  API  HTTP 이지만 사람이 볼 화면은 아니다(도구·curl 용)
  DB   전용 클라이언트로 붙는다(DBeaver·LDAP·kcat 등)
  INT  내부 전용 — 사람이 붙을 일이 없다
"""
import json
import re
import subprocess
import sys
from collections import Counter


def sh(args):
    return subprocess.run(["sudo", "k3s", "kubectl"] + args,
                          capture_output=True, text=True).stdout


# (서비스 정규식, 포트, 종류, 로컬포트, 비고)
RULES = [
    (r"^grafana", 3000, "UI", 3000, "admin / `pw grafana-secret admin-password`"),
    (r"^prometheus", 9090, "UI", 9090, "인증 없음"),
    (r"^alertmanager$", 9093, "UI", 9093, "인증 없음"),
    (r"^opensearch-dashboards$", 5601, "UI", 5601, "http · admin / `pw opensearch-secret admin-password`"),
    (r"^pyroscope$", 4040, "UI", 4040, "인증 없음"),
    (r"^pyroscope-headless$", 4040, "UI", 4042, "위 pyroscope 와 같은 것"),
    (r"^akhq", 8080, "UI", 8080, "Kafka UI · 인증 없음"),
    (r"^apicurio-registry", 8080, "API", 8081, "Registry API — UI 와 함께 띄울 것"),
    (r"^apicurio-ui$", 8080, "UI", 8888, "★ Registry(8081)도 함께 forward"),
    (r"^keycloak", 8080, "UI", 8083, "admin / `pw keycloak-secret admin-password`"),
    (r"^keycloak", 8443, "UI", 8446, "TLS 쪽"),
    (r"^openbao", 8200, "UI", 8200, "토큰 `pw openbao-keys root-token`"),
    (r"^openbao", 8201, "INT", 0, "raft 클러스터 포트(단일 노드라 실사용 없음)"),
    (r"^ranger-admin$", 6080, "UI", 6080, "admin / `pw ranger-secret admin-password` · ★ 반복 실패 금지(Gotcha 11)"),
    (r"^ranger-solr$", 8983, "UI", 8984, "Ranger 감사 색인"),
    (r"^ranger-db$", 5432, "DB", 15433, "PostgreSQL 별칭 — 같은 인스턴스다"),
    # ── 관계형 DB 접근 계층 (§8-75·§8-76) ──────────────────────────
    # ★ 둘 다 **소비자가 없다.** 기존 postgresql-headless·mariadb-headless 와
    #   나란히 서 있고, 접속 문자열은 아직 아무도 이쪽을 보지 않는다.
    #   여기 적는 것은 "프록시가 실제로 통하는지 직접 확인하는" 용도다.
    # ★ 인스턴스당 프런트엔드 프로토콜이 하나라 둘로 나뉜다.
    (r"^shardingsphere$", 3307, "DB", 13307,
     "**PostgreSQL 와이어** · `proxyadmin` / `pw shardingsphere-secret proxy-password` · DB 이름은 `oim`"),
    (r"^proxysql$", 6033, "DB", 16033,
     "**MySQL 와이어** · `cmmn-api` / `pw cmmn-api-secret db-password` · 관리(6032)는 파드 안에서만"),
    (r"^solr-headless$", 8983, "UI", 8983, "거버넌스 Solr"),
    (r"^lam-headless$", 80, "UI", 8084, "`pw lam-secret master-password`"),
    (r"^knox-headless$", 8443, "UI", 8443, "https · `pw knox-secret master-secret`"),
    (r"^wazuh-manager$", 55000, "API", 55000, "https · `pw wazuh-secret api-username`/`api-password`"),
    (r"^wazuh-manager$", 1514, "INT", 0, "에이전트 수신"),
    (r"^wazuh-manager$", 1515, "INT", 0, "에이전트 등록"),
    (r"^wazuh-indexer$", 9200, "API", 9201, "https · admin / `pw wazuh-secret indexer-admin-password`"),
    (r"^defectdojo$", 8080, "UI", 8085, "admin / `pw defectdojo-secret admin-password`"),
    (r"^defectdojo-django$", 3031, "INT", 0, "nginx 뒤의 uwsgi"),
    (r"^dependency-track$", 8080, "UI", 8086, "admin/admin — 최초 로그인 시 변경 요구"),
    (r"^dependency-track-api$", 8080, "API", 8087, "프런트가 부르는 API"),
    (r"^safeline-mgt$", 1443, "UI", 1443, "https"),
    (r"^safeline-mgt$", 80, "UI", 8100, "http"),
    (r"^safeline$", 1443, "UI", 1444, "https(별칭)"),
    (r"^safeline$", 80, "UI", 8101, "http(별칭)"),
    (r"^safeline-fvm$", 80, "API", 8102, "취약점 관리 모듈"),
    (r"^safeline-fvm$", 9004, "INT", 0, ""),
    (r"^safeline-detector$", 8000, "INT", 0, "탐지 엔진"),
    (r"^safeline-detector$", 8001, "INT", 0, ""),
    (r"^safeline-chaos$", 8080, "INT", 0, ""),
    (r"^safeline-chaos$", 8088, "INT", 0, ""),
    (r"^safeline-chaos$", 9000, "INT", 0, ""),
    (r"^caldera$", 8888, "UI", 8887, "red/blue — `caldera-secret` 키를 먼저 확인"),
    (r"^gitlab", 80, "UI", 8090, "root / `pw gitlab-secret root-password`"),
    (r"^gitlab", 443, "UI", 8443, "https"),
    (r"^gitlab", 22, "DB", 2222, "git+ssh"),
    (r"^jenkins-headless$", 8080, "UI", 8091, "admin / `pw jenkins-secret admin-password`"),
    (r"^jenkins-headless$", 50000, "INT", 0, "에이전트 JNLP"),
    (r"^glitchtip$", 8000, "UI", 8000, "가입 필요"),
    (r"^admin-headless$", 3000, "UI", 3001, ""),
    (r"^cmmn-api-headless$", 8080, "API", 8092, ""),
    (r"^nginx$", 80, "UI", 8093, ""),
    (r"^nginx$", 443, "UI", 8447, "https"),
    (r"^openmeter-api$", 80, "API", 8094, "과금 수집·조회 API"),
    (r"^minio-headless$", 9001, "UI", 9001, "콘솔 · `pw minio-secret root-user`/`root-password`"),
    (r"^minio-headless$", 9000, "DB", 9002, "S3 API — mc·s3cmd 용(DBeaver 아님)"),
    (r"^trino-headless$", 8080, "UI", 8095, "웹 UI + JDBC `jdbc:trino://localhost:8095/`"),
    (r"^spark-history", 18080, "UI", 18080, ""),
    (r"^spark-connect", 4040, "UI", 4041, "Spark UI"),
    (r"^spark-connect", 15002, "DB", 15002, "Spark Connect gRPC — PySpark 클라이언트"),
    (r"^spark-connect", 7078, "INT", 0, ""),
    (r"^spark-connect", 7079, "INT", 0, ""),
    (r"^livy-headless$", 8998, "UI", 8998, ""),
    (r"^hadoop-namenode", 9870, "UI", 9870, "HDFS UI"),
    (r"^hadoop-namenode", 8020, "DB", 8020, "HDFS RPC"),
    (r"^hadoop-datanode", 9864, "UI", 9864, "DataNode UI"),
    (r"^hadoop-datanode", 9866, "INT", 0, ""),
    (r"^hadoop-datanode", 9867, "INT", 0, ""),
    (r"^hbase-master$", 16010, "UI", 16010, ""),
    (r"^hbase-master$", 16000, "INT", 0, "RPC"),
    (r"^hbase-regionserver$", 16030, "UI", 16030, ""),
    (r"^hbase-regionserver$", 16020, "INT", 0, "RPC"),
    (r"^hive-server", 10002, "UI", 10002, "HiveServer2 웹"),
    (r"^hive-server", 10000, "DB", 10000, "JDBC `jdbc:hive2://localhost:10000/default`"),
    (r"^hive-metastore", 9083, "DB", 9083, "Thrift — 메타데이터 원본은 PG `hive_metastore`"),
    (r"^postgresql-headless$", 5432, "DB", 15432, "postgres / `pw postgresql-secret postgres-password` · DB 13개"),
    (r"^mariadb-headless$", 3306, "DB", 13306, "root / `pw mariadb-secret root-password` · DB `cmmn`"),
    (r"^mongodb-headless$", 27017, "DB", 17017, "root / `pw mongodb-secret root-password` · **authSource=admin**"),
    (r"^redis-headless$", 6379, "DB", 16379, "`pw redis-secret redis-password` · 과금 중복제거 키"),
    (r"^redis-headless$", 16379, "INT", 0, "클러스터 버스(미사용)"),
    (r"^clickhouse-headless$", 8123, "DB", 18123, "★ **openmeter**/**openreplay** — `default` 없음(Gotcha 27)"),
    (r"^clickhouse-headless$", 9000, "DB", 19000, "native 프로토콜"),
    (r"^opensearch-headless$", 9200, "DB", 19200, "https · admin / `opensearch-secret`"),
    (r"^opensearch-headless$", 9300, "INT", 0, "노드 간(transport)"),
    (r"^data-prepper$", 4900, "INT", 0, "수집 계층 상태·메트릭"),
    (r"^ds389-headless$", 3389, "DB", 3389, "LDAP · `pw ds389-secret dm-password`"),
    (r"^ds389-headless$", 3636, "DB", 3636, "LDAPS"),
    (r"^zookeeper-headless$", 2181, "DB", 2181, "zkCli"),
    (r"^zookeeper-headless$", 2888, "INT", 0, "앙상블 내부"),
    (r"^zookeeper-headless$", 3888, "INT", 0, "앙상블 선출"),
    (r"^kafka-headless$", 9092, "DB", 9092, "Kafka 클라이언트(kcat) — AKHQ 가 더 편하다"),
    (r"^kafka-headless$", 9093, "INT", 0, "KRaft 컨트롤러"),
    (r"^kafka-bridge$", 8080, "API", 8082, "HTTP→Kafka · ★ 자체 인증 없음(SEC-206)"),
    (r"^kafka-bridge$", 8081, "INT", 0, ""),
    (r"^loki-headless$", 3100, "API", 3100, "`/ready` · Grafana 가 소비"),
    (r"^loki-headless$", 9095, "INT", 0, "gRPC"),
    (r"^tempo-headless$", 3200, "API", 3200, "`/status` · Grafana 가 소비"),
    (r"^tempo-headless$", 4317, "INT", 0, "OTLP gRPC 수신"),
    (r"^tempo-headless$", 4318, "INT", 0, "OTLP HTTP 수신"),
    (r"^pyroscope-headless$", 9095, "INT", 0, ""),
    (r"^pyroscope-headless$", 7946, "INT", 0, "memberlist"),
    (r"^kube-state-metrics$", 8080, "API", 8089, "`/metrics`"),
    (r"^falcosidekick$", 2801, "API", 2801, "Falco 수신 webhook · `/healthz`"),
    (r"^otel-gateway$", 8889, "API", 8889, "`/metrics`(Prometheus exporter)"),
    (r"^otel-gateway$", 4317, "INT", 0, "OTLP gRPC"),
    (r"^otel-gateway$", 4318, "INT", 0, "OTLP HTTP"),
    (r"^otel-gateway$", 4319, "INT", 0, "OTLP 추가"),
    (r"^otel-agent$", 4317, "INT", 0, "OTLP gRPC"),
    (r"^otel-agent$", 4318, "INT", 0, "OTLP HTTP"),
    (r"^logstash-headless$", 9600, "API", 9600, "파이프라인 상태 `/_node/stats`"),
    (r"^logstash-headless$", 5044, "INT", 0, "beats 입력"),
    (r"^logstash-headless$", 5140, "INT", 0, "L0 랩 syslog 입력(§8-34)"),
    (r"^logstash-headless$", 5141, "INT", 0, "syslog 입력"),
    (r"^logstash-headless$", 5142, "INT", 0, "Alertmanager webhook 입력(§8-63)"),
    (r"^ingress-istio$", 443, "UI", 30727, "**NodePort — forward 불필요.** https://localhost:30727"),
    (r"^ingress-istio$", 80, "UI", 31938, "**NodePort** — http://localhost:31938(https 로 리다이렉트)"),
    (r"^ingress-istio$", 15021, "API", 32130, "**NodePort** — Envoy 헬스"),
    (r"^waypoint$", 15021, "INT", 0, "Istio 내부"),
    (r"^waypoint$", 15008, "INT", 0, "HBONE"),
]

OPENREPLAY_UI = {"frontend": 8096, "api": 8097, "chalice": 8098}


def classify(name, port):
    for pat, p, kind, lp, note in RULES:
        if re.search(pat, name) and port == p:
            return kind, lp, note
    if name.endswith("-openreplay"):
        head = name[:-len("-openreplay")]
        if head in OPENREPLAY_UI and port in (8080, 8000):
            label = "UI" if head == "frontend" else "API"
            return label, OPENREPLAY_UI[head], "OpenReplay " + head
        if port == 8888:
            return "INT", 0, "내부 메트릭·헬스"
        return "INT", 0, "OpenReplay 내부"
    return "미분류", 0, ""


def main():
    items = json.loads(sh(["get", "svc", "-n", "local", "-o", "json"]) or "{}").get("items", [])
    rows = []
    for it in items:
        name = it["metadata"]["name"]
        if it["spec"].get("type") == "ExternalName":
            rows.append(("INT", name, "-", 0, "ExternalName 별칭"))
            continue
        for p in it["spec"].get("ports", []):
            kind, lp, note = classify(name, p["port"])
            rows.append((kind, name, p["port"], lp, note))

    order = {"UI": 0, "API": 1, "DB": 2, "INT": 3, "미분류": 4}
    rows.sort(key=lambda r: (order.get(r[0], 9), r[1], r[2] if isinstance(r[2], int) else 0))

    if "--md" in sys.argv:
        print("| 종류 | 서비스 | 포트 | 로컬 | 접속 / 비고 |")
        print("|:-:|---|--:|--:|---|")
        for kind, name, port, lp, note in rows:
            print("| %s | `%s` | %s | %s | %s |" % (kind, name, port, lp if lp else "—", note))
    else:
        for kind, name, port, lp, note in rows:
            print("%-6s %-34s %-6s %-6s %s" % (kind, name, port, lp or "-", note))

    counts = Counter(r[0] for r in rows)
    print()
    print("서비스 %d 개 · 포트 %d 개 — " % (len(items), len(rows))
          + " · ".join("%s %d" % (k, counts[k]) for k in ["UI", "API", "DB", "INT", "미분류"] if counts[k]))
    if counts["미분류"]:
        print("★ 미분류 %d 건 — RULES 에 추가할 것" % counts["미분류"])


main()
