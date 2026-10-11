# -*- coding: utf-8 -*-
"""외부 노출 카탈로그 -> HTTPRoute 매니페스트 + 접속 문서.

  python3 local/render-external-access.py            # 생성
  python3 local/render-external-access.py --check    # 뒤처졌으면 1 (CI 게이트)

★ 이 파일의 CATALOG 가 **단일 원천**이다. 호스트명·백엔드·포트·인증 유무를
  여기 한 곳에만 적는다. 같은 것을 매니페스트와 문서에 각자 적으면 어긋나도
  아무도 알려주지 않는다 — 요금제와 쿼터에서 이미 겪었다(Gotcha 71·117).

생성물 둘
  kubernetes/overlays/local/external-access/httproutes.yaml   (전체를 덮어쓴다)
  local/EXTERNAL-ACCESS.md                                    (마커 구간만 덮어쓴다)

★ 문서는 **마커 구간만** 고친다 — 산문은 사람이 쓰고 표만 생성한다.
  산문까지 파이썬 문자열에 담으면 고치기 어려워지고, 결국 문서를 직접
  고치게 되어 생성기가 뒤처진다.

★★ 비밀번호 **값은 담지 않는다.** 조회 명령만 적는다 — ACCESS.md 규약이고
  이 레포가 금지하는 항목이다(Gotcha 186).
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROUTES = os.path.join(ROOT, "kubernetes", "overlays", "local",
                      "external-access", "httproutes.yaml")
DOC = os.path.join(ROOT, "local", "EXTERNAL-ACCESS.md")

DOMAIN = "oneinchmarket.local"
NODE = "192.168.0.103"

# 인증 등급 — 문서에서 경고를 가르는 축이고, 어디까지 노출해도 되는지를 정한다.
#   auth  자체 인증이 있다(로그인·토큰·서명)
#   open  ★ 인증이 없다. LAN·VPN 안에서만 의미가 있다
#   tool  사람 UI 가 아니라 도구·API 용(인증 유무는 비고가 말한다)
AUTH, OPEN, TOOL = "auth", "open", "tool"

# (호스트 라벨, 백엔드 Service, 포트, 백엔드 스킴, 등급, 비고)
#   스킴 https 는 **TLS 오리지네이션**이 필요하다 - destinationrules.yaml 과 짝이다.
#   ★ 한쪽만 고치면 게이트웨이가 평문을 보내고 백엔드가 끊어 502 가 된다.
CATALOG = [
    # -- 관측성 ------------------------------------------------------------
    ("grafana", "grafana-headless", 3000, "http", AUTH,
     "admin / `pw grafana-secret admin-password`"),
    ("prometheus", "prometheus-headless", 9090, "http", OPEN,
     "질의·규칙·타깃"),
    ("alertmanager", "alertmanager", 9093, "http", OPEN,
     "경보 현황. 수신자는 Logstash webhook 이다(Gotcha 33)"),
    ("osd", "opensearch-dashboards", 5601, "http", AUTH,
     "admin / `pw opensearch-secret admin-password` · Dev Tools 가 가장 편하다"),
    ("loki", "loki-headless", 3100, "http", TOOL,
     "`/ready` · 평소에는 Grafana 가 소비한다"),
    ("tempo", "tempo-headless", 3200, "http", TOOL,
     "`/status` · 평소에는 Grafana 가 소비한다"),
    ("pyroscope", "pyroscope", 4040, "http", OPEN,
     "연속 프로파일링"),
    ("pyrra", "pyrra", 9099, "http", OPEN,
     "SLO·오차예산. ★ 빈 그래프의 뜻은 둘이다(Gotcha 150·190)"),
    # -- 오케스트레이션 ----------------------------------------------------
    ("airflow", "airflow-apiserver", 8080, "http", AUTH,
     "admin / `pw airflow-secret admin-password` · 과금 DAG"),
    ("temporal", "temporal-ui-headless", 8080, "http", OPEN,
     "워크플로 이력. 서버는 gRPC 7233 이다"),
    ("flink", "flink-jobmanager", 8081, "http", OPEN,
     "잡 0건. 판정은 `/overview` 의 slots-total 이다(Gotcha 164)"),
    # -- 메시징 · 계약 -----------------------------------------------------
    ("akhq", "akhq-headless", 8080, "http", OPEN,
     "Kafka 브라우저. **Kafka 를 보는 가장 좋은 길이다**"),
    ("apicurio", "apicurio-ui", 8080, "http", OPEN,
     "SPA — 브라우저가 레지스트리를 직접 부른다(§6 의 SPA 항)"),
    ("apicurio-registry", "apicurio-registry-headless", 8080, "http", TOOL,
     "계약 레지스트리 API. 위 UI 의 전제다"),
    ("kafka-bridge", "kafka-bridge", 8080, "http", OPEN,
     "HTTP->Kafka. ★ 자체 인증이 없다(SEC-206)"),
    ("kafka-connect", "kafka-connect-headless", 8083, "http", TOOL,
     "커넥터 REST. `GET /connectors`"),
    # -- 개발자 포털 · API 관리 --------------------------------------------
    ("backstage", "backstage-headless", 7007, "http", AUTH,
     "Keycloak OIDC. `portal` / `pw keycloak-secret portal-user-password`"),
    ("gravitee-console", "gravitee-console-headless", 8080, "http", AUTH,
     "admin / `pw gravitee-secret admin-password` · SPA(§6)"),
    ("gravitee-portal", "gravitee-portal-headless", 8080, "http", AUTH,
     "구독·API 키 발급 · SPA(§6)"),
    ("gravitee-api", "gravitee-management-api-headless", 8083, "http", TOOL,
     "위 둘의 전제. `/management` · `/portal`"),
    ("openmeter", "openmeter-api", 80, "http", TOOL,
     "과금 수집·조회 API"),
    # -- 보안 · 거버넌스 ---------------------------------------------------
    ("keycloak", "keycloak-headless", 8080, "http", AUTH,
     "admin / `pw keycloak-secret admin-password` · ★ iss 가 이 호스트로 발급된다"),
    ("openbao", "openbao", 8200, "http", AUTH,
     "토큰 `pw openbao-keys root-token`"),
    ("ranger", "ranger-admin", 6080, "http", AUTH,
     "admin / `pw ranger-secret admin-password` · ★★ 로그인 반복 실패 금지(Gotcha 11)"),
    ("ranger-solr", "ranger-solr", 8983, "http", OPEN,
     "Ranger 감사 색인"),
    ("solr", "solr-headless", 8983, "http", OPEN,
     "거버넌스 Solr"),
    ("lam", "lam-headless", 80, "http", AUTH,
     "`pw lam-secret master-password` · DS389 관리"),
    ("knox", "knox-headless", 8443, "https", AUTH,
     "DS389 LDAP basic. ★ **Hadoop 계층의 정식 진입점**(§4)"),
    ("wazuh", "wazuh-manager", 55000, "https", AUTH,
     "`pw wazuh-secret api-username` / `api-password`"),
    ("wazuh-indexer", "wazuh-indexer", 9200, "https", AUTH,
     "admin / `pw wazuh-secret indexer-admin-password`"),
    ("defectdojo", "defectdojo", 8080, "http", AUTH,
     "admin / `pw defectdojo-secret admin-password`"),
    ("dtrack", "dependency-track", 8080, "http", AUTH,
     "admin/admin — 최초 로그인에 변경을 요구한다 · SPA(§6)"),
    ("dtrack-api", "dependency-track-api", 8080, "http", TOOL,
     "위 UI 가 브라우저에서 부르는 API"),
    ("safeline", "safeline-mgt", 1443, "https", AUTH,
     "admin / `pw safeline-secret admin-password` · WAF 콘솔"),
    ("caldera", "caldera", 8888, "http", AUTH,
     "red/blue — 키는 `caldera-secret` 에 있다"),
    ("midpoint", "midpoint-headless", 8080, "http", AUTH,
     "IGA. administrator / `pw midpoint-secret admin-password`"),
    ("openfga", "openfga-headless", 8080, "http", TOOL,
     "ReBAC 인가 API. preshared key 가 필요하다(`openfga-secret`)"),
    ("opensearch", "opensearch-headless", 9200, "https", AUTH,
     "검색 엔진 REST. admin / `pw opensearch-secret admin-password`"),
    # -- DevOps ------------------------------------------------------------
    ("gitlab", "gitlab-headless", 80, "http", AUTH,
     "root / `pw gitlab-secret root-password`"),
    ("jenkins", "jenkins-headless", 8080, "http", AUTH,
     "admin / `pw jenkins-secret admin-password`"),
    ("glitchtip", "glitchtip", 8000, "http", AUTH,
     "오류 추적. 가입이 필요하다"),
    # -- 레이크하우스 ------------------------------------------------------
    ("minio", "minio-headless", 9001, "http", AUTH,
     "콘솔. `pw minio-secret root-user` / `root-password`"),
    ("s3", "minio-headless", 9000, "http", AUTH,
     "S3 API — `mc`·`s3cmd`·boto3. 서명 인증"),
    ("trino", "trino-headless", 8080, "http", OPEN,
     "웹 UI(`/ui/`) + **JDBC**(§3-b). ★ `http-server.process-forwarded=true` 가 있어야 한다 — 없으면 전부 406 이다"),
    ("spark-history", "spark-history-headless", 18080, "http", OPEN,
     "완료된 Spark 앱"),
    ("spark-ui", "spark-connect-headless", 4040, "http", OPEN,
     "Spark Connect 세션 UI"),
    ("livy", "livy-headless", 8998, "http", OPEN,
     "Spark REST 세션"),
    ("hdfs", "hadoop-namenode", 9870, "http", OPEN,
     "NameNode UI. ★ 파일 조작은 Knox 의 WebHDFS 를 쓸 것"),
    ("hbase", "hbase-master", 16010, "http", OPEN,
     "HBase Master"),
    ("hbase-rs", "hbase-regionserver", 16030, "http", OPEN,
     "RegionServer"),
    ("hive", "hive-server-headless", 10002, "http", OPEN,
     "★★ **게이트웨이 경유로는 500 이다** — Jetty 가 Host 헤더의 포트로 핸들러를 고른다(§6). JDBC 는 Knox 경유(§4)"),
    # -- 애플리케이션 ------------------------------------------------------
    ("app-admin", "admin-headless", 3000, "http", TOOL,
     "관리 프런트"),
    ("app-api", "cmmn-api-headless", 8080, "http", TOOL,
     "★ 과금 경로가 아니다(과금은 `api` 호스트 · JWT 필수). 루트는 404 이고 `/actuator/health` 가 200 이다"),
    ("www", "nginx", 80, "http", TOOL,
     "정적 프런트"),
    ("openreplay", "frontend-openreplay", 8080, "http", AUTH,
     "세션 리플레이. ★ 전제 2건이 미해결이라 데이터가 비어 있다"),
    ("openreplay-api", "api-openreplay", 8080, "http", TOOL,
     "위 프런트가 부르는 API"),
]

# AuthorizationPolicy 가 선택하는 백엔드 — 게이트웨이 신원을 따로 허용해야 한다.
#   실측(2026-10-11)으로 정책이 선택하는 워크로드는 12개뿐이고, 그중 HTTP 로
#   노출하는 것이 아래 넷이다. 여기 빠뜨리면 그 호스트만 **502·리셋**이 된다.
AUTHZ_GUARDED = {
    ("minio-headless", 9000), ("minio-headless", 9001),
    ("opensearch-headless", 9200),
    ("spark-connect-headless", 4040),
}

# DBeaver·전용 클라이언트용 TCP 노출 — db-gateway(nginx stream)가 중계한다.
#   (NodePort, 파드 안 listen, 백엔드 서비스, 백엔드 포트, 라벨, 비고)
#   ★ NodePort 를 **고정**한다 — 자동 할당이면 재생성마다 바뀌어 DBeaver 설정이
#     깨진다. 실측으로 게이트웨이 NodePort 가 재구축에서 30727 -> 32573 로
#     갈렸고 ACCESS.md 가 그대로 뒤처져 있었다.
TCP_CATALOG = [
    (30432, 5432, "postgresql-headless", 5432, "PostgreSQL 18.6",
     "`postgres` / `pw postgresql-secret postgres-password` · DB 13개 · ★ Show all databases 를 켤 것"),
    (30306, 3306, "mariadb-headless", 3306, "MariaDB 12.3",
     "`root` / `pw mariadb-secret root-password` · DB `cmmn`"),
    (30307, 3307, "shardingsphere", 3307, "ShardingSphere 5.5 (PG 와이어)",
     "`proxyadmin` / `pw shardingsphere-secret proxy-password` · 논리 DB `oim`"),
    (30633, 6033, "proxysql", 6033, "ProxySQL 4.0 (MySQL 와이어)",
     "`cmmn-api` / `pw cmmn-api-secret db-password` · DB `cmmn`"),
    (30017, 27017, "mongodb-headless", 27017, "MongoDB 7.0",
     "`root` / `pw mongodb-secret root-password` · ★ `authSource=admin` 필수"),
    (30379, 6379, "redis-headless", 6379, "Redis 8.10",
     "`pw redis-secret redis-password` · ★★ 과금 중복제거 키 — `FLUSHALL` 금지(Gotcha 16)"),
    (30123, 8123, "clickhouse-headless", 8123, "ClickHouse 26.8 (HTTP)",
     "★ `default` 사용자가 없다 — `openmeter` 또는 `openreplay`(Gotcha 27)"),
    (30900, 9000, "clickhouse-headless", 9000, "ClickHouse (native)",
     "같은 인스턴스. 네이티브 프로토콜"),
    (30000, 10000, "hive-server-headless", 10000, "HiveServer2 (Thrift)",
     "★ 인증이 없다. **Knox 경유를 권한다**(§4)"),
    (30083, 9083, "hive-metastore-headless", 9083, "Hive Metastore (Thrift)",
     "테이블 목록만 보려면 PG 의 `hive_metastore` 가 더 빠르다"),
    (30389, 3389, "ds389-headless", 3389, "DS389 LDAP",
     "`pw ds389-secret dm-password` · Apache Directory Studio·`ldapsearch`"),
    (30636, 3636, "ds389-headless", 3636, "DS389 LDAPS",
     "같은 디렉터리. TLS"),
    (30092, 9092, "kafka-headless", 9092, "Kafka 9092",
     "★★ 브로커가 클러스터 안 이름을 광고한다 — §3 의 제약을 볼 것. AKHQ 가 정답이다"),
    (30002, 15002, "spark-connect-headless", 15002, "Spark Connect (gRPC)",
     "PySpark 의 `SparkSession.builder.remote` 로 붙는다"),
    (30181, 2181, "zookeeper-headless", 2181, "ZooKeeper",
     "`zkCli.sh`"),
]

TIER_MARK = {AUTH: "자체 인증", OPEN: "**없음**", TOOL: "도구용"}

HEADER = """# ★ 생성 파일이다 — 손으로 고치지 말 것.
#   원천: local/render-external-access.py 의 CATALOG
#   생성: python3 local/render-external-access.py
#   검사: python3 local/render-external-access.py --check   (뒤처지면 1)
#
# 컴포넌트별 외부 진입 경로. 호스트명 기반이고 경로는 전부 `/` 다.
#
# ★★ 왜 경로(path) 기반이 아니라 호스트 기반인가
#   `https://oim.local/grafana/` 류로 묶으면 앱마다 base-path 설정을 고쳐야
#   하고(Grafana 의 root_url · Prometheus 의 --web.external-url 등), SPA 는
#   절대경로 자산을 잃어 흰 화면이 된다. 호스트 기반이면 **대다수가 설정
#   변경 없이 그대로 동작한다** — 그래서 고친 앱이 다섯뿐이다(SPA 넷 + CORS 하나).
#
# ★ 이 라우트들이 닿는 기전(2026-10-11 실측): 게이트웨이는 ztunnel 에 포획되지
#   않지만(`istio.io/dataplane-mode: none`) **그 자체가 신원을 가진 Istio
#   프록시라** 백엔드로 HBONE(15008)을 쓴다. 그 포트는 `allow-istio-hbone` 이
#   모든 파드에 열어 두므로 **NetworkPolicy 를 백엔드마다 더할 필요가 없다.**
#   근거: Envoy 통계의 destination_principal 이
#   `spiffe://cluster.local/ns/local/sa/grafana` 이고 응답이 200 이었다.
#   ★★ 메시 밖의 **평범한** 파드로 이것을 흉내내면 전부 타임아웃이다 — 평문으로
#     대상 포트를 직접 치므로 Cilium 이 떨군다(`Policy denied ... :3000 tcp SYN`).
#     게이트웨이의 대리로 쓸 수 없다. 그렇게 재서 한 번 틀렸고, 실제 경로를
#     치니 200 이었다. **대리 실험의 조건이 대상과 같은지 먼저 볼 것.**
#
# ★ AuthorizationPolicy 가 선택하는 백엔드는 예외다(minio·opensearch·
#   spark-connect). 게이트웨이 신원을 허용하는 **추가** 정책이 필요하고 그것은
#   authz-external-access.yaml 에 있다. 기존 정책은 손대지 않는다 — Istio 의
#   ALLOW 는 합집합이라 추가 정책으로 더하는 것이 안전하다.
#
# sync-wave 8 — 백엔드가 전부 떠 있어야 의미가 있다. ★ 라우트는 백엔드가 없어도
#   Accepted 가 되므로 순서가 틀려도 조용히 넘어간다. 판정은 실제 응답으로 한다.
"""


def route_yaml(host, svc, port, scheme, tier, note):
    guard = ""
    if (svc, port) in AUTHZ_GUARDED:
        guard = ("  # ★ 이 백엔드는 AuthorizationPolicy 가 선택한다 — 게이트웨이\n"
                 "  #   신원 허용이 authz-external-access.yaml 에 함께 있어야\n"
                 "  #   한다. 없으면 이 호스트만 502·리셋이다.\n")
    tls = ""
    if scheme == "https":
        tls = ("  # ★ 백엔드가 HTTPS 다 — destinationrules.yaml 의 TLS\n"
               "  #   오리지네이션과 짝이다. 한쪽만 있으면 502 다.\n")
    return """---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ext-{host}
  labels:
    app.kubernetes.io/name: ext-{host}
    app.kubernetes.io/component: gateway-routes
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
  annotations:
    argocd.argoproj.io/sync-wave: "8"
    # 인증 등급 — 문서(local/EXTERNAL-ACCESS.md)의 경고 축이다
    oneinchmarket.local/auth-tier: "{tier}"
{guard}{tls}spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress
      sectionName: https
  hostnames:
    - {host}.{domain}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: {svc}
          port: {port}
          weight: 1
""".format(host=host, svc=svc, port=port, tier=tier, domain=DOMAIN,
           guard=guard, tls=tls)


def gen_routes():
    seen = set()
    out = [HEADER]
    for row in CATALOG:
        if row[0] in seen:
            raise SystemExit("중복 호스트: %s" % row[0])
        seen.add(row[0])
        out.append(route_yaml(*row))
    return "".join(out)


def md_hosts():
    lines = ["```text",
             "# oneinchmarket 외부 접속 — Windows 는 "
             "C:\\Windows\\System32\\drivers\\etc\\hosts (관리자 권한)",
             "# %s = control-plane. 104 로 바꿔도 같다 — "
             "양 노드가 같은 라우팅을 받는다." % NODE]
    for host, _s, _p, _sc, _t, _n in CATALOG:
        lines.append("%s %s.%s" % (NODE, host, DOMAIN))
    lines.append("%s api.%s" % (NODE, DOMAIN))
    lines.append("```")
    return "\n".join(lines)


def md_ui_table():
    rows = ["| 호스트 | 인증 | 백엔드 | 비고 |", "|---|:-:|---|---|"]
    for host, svc, port, scheme, tier, note in CATALOG:
        rows.append("| https://%s.%s | %s | `%s:%d`%s | %s |" % (
            host, DOMAIN, TIER_MARK[tier], svc, port,
            " **(https)**" if scheme == "https" else "", note))
    return "\n".join(rows)


def md_open_list():
    names = ["`%s.%s`" % (h, DOMAIN) for h, _s, _p, _sc, t, _n in CATALOG
             if t == OPEN]
    return "**%d 종** — %s" % (len(names), " · ".join(names))


def md_tcp_table():
    rows = ["| 접속 주소 | 대상 | 접속 정보 |", "|---|---|---|"]
    for np, _lp, svc, bp, label, note in TCP_CATALOG:
        rows.append("| `%s:%d` | **%s** -> `%s:%d` | %s |" % (
            NODE, np, label, svc, bp, note))
    return "\n".join(rows)


def md_counts():
    n_auth = sum(1 for r in CATALOG if r[4] == AUTH)
    n_open = sum(1 for r in CATALOG if r[4] == OPEN)
    n_tool = sum(1 for r in CATALOG if r[4] == TOOL)
    n_tls = sum(1 for r in CATALOG if r[3] == "https")
    return ("웹 호스트 **%d**(자체 인증 %d · 인증 없음 %d · 도구용 %d, "
            "그중 백엔드가 HTTPS 인 것 %d) · TCP 대상 **%d**"
            % (len(CATALOG), n_auth, n_open, n_tool, n_tls, len(TCP_CATALOG)))


REGIONS = [
    ("counts", md_counts),
    ("hosts", md_hosts),
    ("ui-table", md_ui_table),
    ("open-list", md_open_list),
    ("tcp-table", md_tcp_table),
]


def fill_doc(text):
    for name, fn in REGIONS:
        start = "<!-- GENERATED:%s START -->" % name
        end = "<!-- GENERATED:%s END -->" % name
        pat = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
        if not pat.search(text):
            raise SystemExit("문서에 마커가 없다: %s" % name)
        body = fn()
        text = pat.sub(lambda _m: "%s\n%s\n%s" % (start, body, end), text)
    return text


def read(path):
    if not os.path.exists(path):
        return None
    return io.open(path, encoding="utf-8", newline="").read()


def write(path, data):
    d = os.path.dirname(path)
    if not os.path.isdir(d):
        os.makedirs(d)
    io.open(path, "w", encoding="utf-8", newline="\n").write(data)


def main():
    check = "--check" in sys.argv
    routes = gen_routes()
    doc_src = read(DOC)
    if doc_src is None:
        raise SystemExit("없다: %s — 마커를 담은 문서 뼈대를 먼저 만들 것" % DOC)
    doc = fill_doc(doc_src)

    stale = []
    if read(ROUTES) != routes:
        stale.append(ROUTES)
    if doc_src != doc:
        stale.append(DOC)

    if check:
        # ★ "뒤처졌다" 와 "돌리지 못했다" 를 구분해 보고한다 — 둘 다 0 이 아니면
        #   사람은 전자로 읽는다(Gotcha 189).
        if stale:
            for p in stale:
                print("STALE %s" % os.path.relpath(p, ROOT))
            print("생성기를 다시 돌리고 결과를 함께 커밋할 것.")
            return 1
        print("최신 — %s" % md_counts())
        return 0

    write(ROUTES, routes)
    write(DOC, doc)
    print("생성 완료 — %s" % md_counts())
    print("  %s" % os.path.relpath(ROUTES, ROOT))
    print("  %s" % os.path.relpath(DOC, ROOT))
    n_open = sum(1 for r in CATALOG if r[4] == OPEN)
    print("★ 인증 없는 호스트 %d 종 — LAN·VPN 안에서만 의미가 있다" % n_open)
    return 0


if __name__ == "__main__":
    sys.exit(main())
