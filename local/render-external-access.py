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
JWTSCOPE = os.path.join(ROOT, "kubernetes", "overlays", "local",
                        "external-access", "jwt-scope-envoyfilter.yaml")

# ★★ 게이트웨이 JWT 검증이 **필요한** 호스트(2026-11-03). 나머지 호스트에서는 그 필터를 끈다.
#   RequestAuthentication(api-jwt·api-jwt-external)은 게이트웨이 **전체**에 걸려, Keycloak 이 아닌
#   발급자의 Bearer 토큰을 호스트와 상관없이 `Jwt issuer is not configured` 로 401 한다. 그래서
#   자체 Bearer 토큰을 쓰는 앱 — Dependency-Track(로그인은 성공하는데 다음 요청이 전부 막혀
#   "Could not perform the requested action") · Wazuh API · GitLab 개인 토큰 — 이 깨졌다.
#   게이트웨이 JWT 를 실제로 쓰는 정책은 api(과금 — api-require-jwt·api-only-realm-issuers)와
#   zilla(zilla-require-realm-jwt) 둘뿐이다. api 는 이 CATALOG 밖(base 의 HTTPRoute)이라 목록에
#   없어도 필터가 꺼지지 않는다 — 꺼지는 것은 여기서 생성한 가상 호스트뿐이다.
JWT_GATEWAY_HOSTS = {"zilla"}

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
    ("prometheus", "prometheus-headless", 9090, "http", AUTH,
     "질의·규칙·타깃 · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("alertmanager", "alertmanager", 9093, "http", AUTH,
     "경보 현황. 수신자는 Logstash webhook 이다(Gotcha 33) · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("osd", "opensearch-dashboards", 5601, "http", AUTH,
     "admin / `pw opensearch-secret admin-password` · Dev Tools 가 가장 편하다"),
    # ★ loki 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    ("tempo", "tempo-headless", 3200, "http", TOOL,
     "`/status` · 평소에는 Grafana 가 소비한다"),
    ("pyroscope", "pyroscope", 4040, "http", AUTH,
     "연속 프로파일링 · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("pyrra", "pyrra", 9099, "http", AUTH,
     "SLO·오차예산. ★ 빈 그래프의 뜻은 둘이다(Gotcha 150·190) · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    # -- 오케스트레이션 ----------------------------------------------------
    ("airflow", "airflow-apiserver", 8080, "http", AUTH,
     "admin / `pw airflow-secret admin-password` · 과금 DAG"),
    ("temporal", "temporal-ui-headless", 8080, "http", AUTH,
     "워크플로 이력. 서버는 gRPC 7233 이다 · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("flink", "flink-jobmanager", 8081, "http", AUTH,
     "잡 0건. 판정은 `/overview` 의 slots-total 이다(Gotcha 164) · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    # -- 메시징 · 계약 -----------------------------------------------------
    ("akhq", "akhq-headless", 8080, "http", AUTH,
     "Kafka 브라우저. ★ Keycloak 로그인 — `platform` 그룹은 admin, 그 밖은 "
     "`edge.*` 읽기만, 익명은 아무것도 안 보인다. 연결 `edge-via-kroxylicious` 는 "
     "외부 클라이언트가 보는 그대로(§3-e)"),
    ("apicurio", "apicurio-ui", 8080, "http", AUTH,
     "SPA — 브라우저가 레지스트리를 직접 부른다(§6 의 SPA 항). ★ Keycloak 로그인"
     "(공개 클라이언트 `apicurio-ui`) — `platform` 그룹은 sr-admin, 그 밖은 읽기만"),
    ("apicurio-registry", "apicurio-registry-headless", 8080, "http", TOOL,
     "계약 레지스트리 API. 위 UI 의 전제다. ★ **읽기는 익명 허용 · 쓰기는 토큰 또는 "
     "client_id:secret basic**(2026-11-03) — 스키마 내용은 LAN 에 보인다"),
    # ★ kafka-bridge 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    # ★ kafka-connect 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    ("zilla", "zilla", 7114, "http", TOOL,
     "HTTP·SSE <-> Kafka `edge.events` (`POST`·`GET /events` · `GET /sse/events`). "
     "★ Keycloak realm JWT 필수(게이트웨이 DENY)"),
    # -- 개발자 포털 · API 관리 --------------------------------------------
    ("backstage", "backstage-headless", 7007, "http", AUTH,
     "Keycloak OIDC. `portal` / `pw keycloak-secret portal-user-password`"),
    ("gravitee-console", "gravitee-console-headless", 8080, "http", AUTH,
     "admin / `pw gravitee-secret admin-password` · SPA(§6)"),
    ("gravitee-portal", "gravitee-portal-headless", 8080, "http", AUTH,
     "구독·API 키 발급 · SPA(§6)"),
    ("gravitee-api", "gravitee-management-api-headless", 8083, "http", TOOL,
     "위 둘의 전제. `/management` · `/portal`"),
    # ★ openmeter 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    # -- 보안 · 거버넌스 ---------------------------------------------------
    ("keycloak", "keycloak-headless", 8080, "http", AUTH,
     "admin / `pw keycloak-secret admin-password` · ★ iss 가 이 호스트로 발급된다"),
    ("openbao", "openbao", 8200, "http", AUTH,
     "토큰 `pw openbao-keys root-token`"),
    ("ranger", "ranger-admin", 6080, "http", AUTH,
     "admin / `pw ranger-secret admin-password` · ★★ 로그인 반복 실패 금지(Gotcha 11)"),
    # ★ solr·ranger-solr 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    ("lam", "lam-headless", 80, "http", AUTH,
     "`cn=Directory Manager` / `pw ds389-secret dm-password` · DS389 관리. "
     "★ `lam-secret master-password` 는 로그인이 아니라 **설정 편집기**(LAM configuration) 암호다 — "
     "로그인에 넣으면 `LDAP error, server says: Invalid credentials`"),
    ("knox", "knox-headless", 8443, "https", AUTH,
     "DS389 LDAP basic. ★ **Hadoop 계층의 정식 진입점**(§4). 홈 `/gateway/homepage/home/`(KnoxSSO) · "
     "Solr(Ranger 감사 색인) 는 `/gateway/oim/solr/` — data-admin 만 · 읽기만"),
    ("wazuh", "wazuh-dashboard", 5601, "http", AUTH,
     "Wazuh 웹 UI(2026-11-03 신설 — 전에는 이 호스트가 매니저 API 로 가서 JSON 401 만 보였다). "
     "admin / `pw wazuh-secret indexer-admin-password`"),
    ("wazuh-api", "wazuh-manager", 55000, "https", TOOL,
     "매니저 REST API. `POST /security/user/authenticate`(basic `pw wazuh-secret api-username` / "
     "`api-password`)로 토큰은 받지만, ★ 그 토큰을 **게이트웨이 경유 Bearer 로는 쓸 수 없다** — "
     "게이트웨이 JWT 검증이 Keycloak 이 아닌 발급자를 `Jwt issuer is not configured` 로 거부한다. "
     "API 를 쓰려면 port-forward(`wazuh-manager:55000`)로"),
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
     "`red` / `pw caldera-secret red-password` · `blue` / `pw caldera-secret blue-password` (api-key-* 는 REST API 의 KEY 헤더용 — 로그인이 아니다)"),
    ("midpoint", "midpoint-headless", 8080, "http", AUTH,
     "IGA. administrator / `pw midpoint-secret admin-password` — 저장소를 처음 만들 때의 값이다. UI 에서 바꾸면 Secret 과 갈린다"),
    ("openfga", "openfga-headless", 8080, "http", TOOL,
     "ReBAC 인가 API. preshared key 가 필요하다(`openfga-secret`)"),
    ("opensearch", "opensearch-headless", 9200, "https", AUTH,
     "검색 엔진 REST — ★ **화면이 없다**(브라우저는 로그인 창 뒤 JSON). UI 는 "
     "`https://osd.%s` 다. admin / `pw opensearch-secret admin-password`" % DOMAIN),
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
    ("trino", "trino-headless", 8080, "http", AUTH,
     "LDAP 로그인 `data-admin`(전권)·`analyst`(조회만) / `pw ds389-secret <uid>-password` · 권한은 Ranger `oim-trino` · 웹 UI(`/ui/`) + **JDBC**(§3-b). ★ `http-server.process-forwarded=true` 가 있어야 한다 — 없으면 전부 406 이다"),
    ("spark-history", "oauth2-proxy-spark-history", 4180, "http", AUTH,
     "완료된 Spark 앱. **Keycloak 로그인 · 그룹 `platform` 만**(spark-ui 와 같다) — 앞단 oauth2-proxy"),
    ("spark-ui", "oauth2-proxy-spark-ui", 4180, "http", AUTH,
     "Spark Connect 세션 UI. **Keycloak 로그인 · 그룹 `platform` 만**(`portal` / `pw keycloak-secret portal-user-password`) — 앞단 oauth2-proxy(external-access/oauth2-proxy-spark-ui.yaml). ★ 세션 UI 는 Job 을 **죽일 수 있다**(`spark.ui.killEnabled` 기본 true)"),
    ("livy", "oauth2-proxy-livy", 4180, "http", AUTH,
     "Spark REST 세션. **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy. ★ 브라우저용이다 — 스크립트는 클러스터 안 `livy-headless:8998` 또는 port-forward"),
    ("hdfs", "hadoop-namenode", 9870, "http", AUTH,
     "NameNode UI. ★ 파일 조작은 Knox 의 WebHDFS 를 쓸 것 · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("hbase", "hbase-master", 16010, "http", AUTH,
     "HBase Master · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("hbase-rs", "hbase-regionserver", 16030, "http", AUTH,
     "RegionServer · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P)"),
    ("hive", "hive-server-headless", 10002, "http", AUTH,
     "HiveServer2 웹 UI · **Keycloak 로그인 · 그룹 `platform` 만** — 앞단 oauth2-proxy(O2P). ★ 예전에는 게이트웨이 경유로 500 이었다 — Jetty 가 Host 헤더의 포트로 핸들러를 고른다(§6). oauth2-proxy 가 Host 를 업스트림 이름으로 바꿔 보내 풀린다. JDBC 는 Knox 경유(§4)"),
    # -- 애플리케이션 ------------------------------------------------------
    ("app-admin", "admin-headless", 3000, "http", TOOL,
     "관리 프런트"),
    # ★ app-api 는 외부에 열지 않는다 — 사유와 대안은 CLOSED(아래).
    ("www", "nginx", 80, "http", TOOL,
     "정적 프런트"),
    ("openreplay", "frontend-openreplay", 8080, "http", AUTH,
     "세션 리플레이. 경로별 백엔드(`/api`->chalice 등 14개)는 PATH_ROUTES 가 나눈다 — 차트의 Ingress 대신이다. 첫 접속은 가입 화면(계정 0개). ★ 전제 2건이 미해결이라 데이터가 비어 있다"),
    ("openreplay-api", "api-openreplay", 8080, "http", TOOL,
     "위 프런트가 부르는 API"),
]

# ★★ 인증이 없던 UI 앞의 oauth2-proxy(2026-11-06) — 호스트 -> (백엔드 파드의 name 라벨, 추가 인자).
#   이 목록에 있으면 CATALOG 의 백엔드는 **업스트림**이 되고, 라우트는 `oauth2-proxy-<호스트>:4180` 으로
#   간다. 이 목록에서 셋이 함께 생성된다(oauth2-proxies.yaml):
#     ① oauth2-proxy Service·Deployment — Keycloak 로그인 · 그룹 `platform` 만
#     ② 백엔드에 **게이트웨이 신원만 거부하는 DENY** — 라우트를 되돌려도 로그인 없이 열리지 않는다.
#        ALLOW 로 좁히지 않는 이유: 이 백엔드들은 클러스터 안 호출자가 많다(Grafana->Prometheus·
#        Prometheus->Alertmanager·HBase<->HDFS…). ALLOW 는 그 전부를 나열해야 하고 하나만 빠져도 끊긴다.
#        DENY 는 선택한 워크로드의 다른 트래픽을 바꾸지 않는다.
#   ★ 짝 둘이 이 목록과 같아야 한다 — 다르면 생성이 멈춘다(Gotcha 117):
#     overlays/local/patches/external-urls-local.yaml 의 O2P_HOSTS (Keycloak 클라이언트를 만든다)
#     local/create-secrets.sh 의 `<호스트>-client-secret`·`<호스트>-cookie-secret`
#   ★ spark-ui·livy·spark-history 는 먼저 손으로 만든 파일(oauth2-proxy-*.yaml)이라 여기 없다.
O2P = {
    "prometheus":   ("prometheus", []),
    "alertmanager": ("alertmanager", []),
    "pyroscope":    ("pyroscope", []),
    "pyrra":        ("pyrra", []),
    "temporal":     ("temporal-ui", []),
    "flink":        ("flink-jobmanager", []),
    "hdfs":         ("hadoop-namenode", []),
    "hbase":        ("hbase-master", []),
    "hbase-rs":     ("hbase-regionserver", []),
    # HiveServer2 의 Jetty 는 Host 헤더의 **포트**로 핸들러를 고른다(외부 이름 :443 이면 500).
    #   업스트림 이름(hive-server-headless:10002)을 보내면 맞는다.
    "hive":         ("hive-server", ["--pass-host-header=false"]),
}
O2P_FILE = os.path.join(ROOT, "kubernetes", "overlays", "local",
                        "external-access", "oauth2-proxies.yaml")
O2P_PEERS = [
    os.path.join(ROOT, "kubernetes", "overlays", "local", "patches", "external-urls-local.yaml"),
    os.path.join(ROOT, "local", "create-secrets.sh"),
]

# AuthorizationPolicy 가 선택하는 백엔드 — 게이트웨이 신원을 따로 허용해야 한다.
#   실측(2026-10-11)으로 정책이 선택하는 워크로드는 12개뿐이고, 그중 HTTP 로
#   노출하는 것이 아래 셋이다. 여기 빠뜨리면 그 호스트만 **502·리셋**이 된다.
#   ★ spark-connect 4040 은 2026-11-06 에 빠졌다 — 게이트웨이가 아니라 oauth2-proxy 가
#     닿는다(authz-external-access.yaml 이 그 신원만 허용한다).
AUTHZ_GUARDED = {
    ("minio-headless", 9000), ("minio-headless", 9001),
    ("opensearch-headless", 9200),
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
    # ★ Kafka 9092(30092)는 2026-11-02 에 뺐다 — Kroxylicious(30992)가 대신한다.
    #   "bootstrap 까지만 된다" 로 적어 두었지만 단일 브로커에서는 bootstrap 연결이
    #   곧 그 브로커라, 직접 짠 클라이언트는 그 소켓으로 produce 할 수 있었다 —
    #   인증 없는 Kafka 전체 접근이었다.
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


# 루트(`/`)에 아무것도 없는 앱 — 정확히 `/` 로 온 요청만 사람용 진입점으로 보낸다(302).
#   ★ knox: Knox 는 `/` 에 핸들러가 없어 **404** 다(2026-11-03 실측 — 앱이 죽은 것이 아니라
#     원래 그렇다). 사람용 홈은 /gateway/homepage/home/ 이고 KnoxSSO 로그인으로 이어진다.
#     문서가 호스트만 안내해서 처음 들어온 사람이 404 를 보고 "접속되지 않는다" 로 읽었다.
#   Exact 매치라 /gateway/... 같은 다른 경로는 그대로 백엔드로 간다.
ROOT_REDIRECT = {
    "knox": "/gateway/homepage/home/",
}


# 한 호스트 안에서 경로마다 백엔드가 다른 앱 — (경로 접두, 서비스, 포트, 바꿔 넣을 접두 | None).
#   ★ openreplay: 차트는 이 분배를 nginx Ingress(`nginx.org/location-snippets` 의 rewrite)로 하는데,
#     그 Ingress 는 컨트롤러가 없어 지웠다(Gotcha 7·58). 그래서 프런트만 닿고 `/api/...` 가 SPA 의
#     index.html(200)을 받아 UI 가 "Error while fetching data" 였다(2026-11-06). 값은 v1.27 차트의
#     Ingress 를 렌더해 옮겼다 — rewrite `^/api/(.*)$ /$1` 는 ReplacePrefixMatch "/" 와 같다.
#   Gateway API 는 가장 긴 접두가 이기므로 순서와 무관하다(/ingest/v1/web/images 가 /ingest 를 이긴다).
PATH_ROUTES = {
    "openreplay": [
        ("/api", "chalice-openreplay", 8000, "/"),
        ("/v2/api", "api-openreplay", 8080, "/"),
        ("/ws-assist", "assist-openreplay", 9001, "/"),
        ("/ingest/v1/web/images", "canvases-openreplay", 8080, None),
        ("/ingest/v1/mobile/images", "images-openreplay", 8080, "/v1/mobile/images"),
        ("/ingest", "http-openreplay", 8080, "/"),
        ("/spot", "spot-openreplay", 8080, "/"),
        # 리플레이 파일(mobs 등)은 버킷 경로 그대로 MinIO 로 간다 — 차트의 minio Ingress 와 같다.
        ("/mobs", "minio-headless", 9000, None),
        ("/sessions-assets", "minio-headless", 9000, None),
        ("/static", "minio-headless", 9000, None),
        ("/sourcemaps", "minio-headless", 9000, None),
        ("/records", "minio-headless", 9000, None),
        ("/spots", "minio-headless", 9000, None),
    ],
}


def path_rules(host):
    out = []
    for prefix, svc, port, replace in PATH_ROUTES.get(host, []):
        rw = ""
        if replace is not None:
            rw = ("      filters:\n"
                  "        - type: URLRewrite\n"
                  "          urlRewrite:\n"
                  "            path:\n"
                  "              type: ReplacePrefixMatch\n"
                  "              replacePrefixMatch: %s\n") % replace
        out.append("    - matches:\n"
                   "        - path:\n"
                   "            type: PathPrefix\n"
                   "            value: %s\n"
                   "%s"
                   "      backendRefs:\n"
                   "        - group: \"\"\n"
                   "          kind: Service\n"
                   "          name: %s\n"
                   "          port: %d\n"
                   "          weight: 1\n" % (prefix, rw, svc, port))
    return "".join(out)


def route_yaml(host, svc, port, scheme, tier, note):
    if host in O2P:
        svc, port = "oauth2-proxy-%s" % host, 4180
    guard = ""
    if (svc, port) in AUTHZ_GUARDED:
        guard = ("  # ★ 이 백엔드는 AuthorizationPolicy 가 선택한다 — 게이트웨이\n"
                 "  #   신원 허용이 authz-external-access.yaml 에 함께 있어야\n"
                 "  #   한다. 없으면 이 호스트만 502·리셋이다.\n")
    redirect = ""
    if host in ROOT_REDIRECT:
        redirect = ("    # 루트에 핸들러가 없는 앱 — 정확히 `/` 만 사람용 진입점으로 보낸다(ROOT_REDIRECT).\n"
                    "    - matches:\n"
                    "        - path:\n"
                    "            type: Exact\n"
                    "            value: /\n"
                    "      filters:\n"
                    "        - type: RequestRedirect\n"
                    "          requestRedirect:\n"
                    "            path:\n"
                    "              type: ReplaceFullPath\n"
                    "              replaceFullPath: %s\n"
                    "            statusCode: 302\n") % ROOT_REDIRECT[host]
    tls = ""
    if scheme == "https":
        tls = ("  # ★ 백엔드가 HTTPS 다 — destinationrules.yaml 의 TLS\n"
               "  #   오리지네이션과 짝이다. 한쪽만 있으면 502 다.\n")
    # 경로별 백엔드(PATH_ROUTES) — 기본 `/` 규칙보다 긴 접두라 먼저 매칭된다
    redirect += path_rules(host)
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
{redirect}    - matches:
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
           guard=guard, tls=tls, redirect=redirect)


def gen_routes():
    seen = set()
    out = [HEADER]
    for row in CATALOG:
        if row[0] in seen:
            raise SystemExit("중복 호스트: %s" % row[0])
        seen.add(row[0])
        out.append(route_yaml(*row))
    return "".join(out)


O2P_HEADER = """# ★ 생성 파일이다 — 손으로 고치지 말 것. 원천은 local/render-external-access.py 의 O2P
#   (사유는 그 상수의 주석). `--check` 가 뒤처짐을 1 로 알린다.
#
# 인증이 없던 UI 앞의 Keycloak 로그인(2026-11-06). 호스트마다 oauth2-proxy 하나 —
#   oauth2-proxy 는 호스트별 업스트림을 고르지 못한다(livy·spark-history 와 같은 이유).
#   설정의 사연(scope · CA · hostAliases · 그룹)은 oauth2-proxy-spark-ui.yaml 머리말에 있다.
# ★ 백엔드마다 게이트웨이 신원(*/sa/ingress-istio)만 거부하는 DENY 가 함께 있다.
#   판정: 쿠키 없이 그 호스트를 치면 Keycloak 으로 302, 게이트웨이를 거치지 않는 클러스터 안
#   호출(예: Grafana->Prometheus)은 그대로 200.
"""


def o2p_yaml(host, upstream_svc, upstream_port, podname, extra):
    lbl = ("    app.kubernetes.io/name: oauth2-proxy\n"
           "    app.kubernetes.io/instance: %s\n" % host)
    args = "".join("            - %s\n" % a for a in extra)
    return """---
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy-{host}
  labels:
{lbl}    app.kubernetes.io/component: external-access
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  selector:
    app.kubernetes.io/name: oauth2-proxy
    app.kubernetes.io/instance: {host}
  ports:
    - name: http
      port: 4180
      targetPort: 4180
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy-{host}
  labels:
{lbl}    app.kubernetes.io/component: external-access
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
  annotations:
    argocd.argoproj.io/sync-wave: "8"
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  strategy:
    rollingUpdate: {{maxSurge: 0, maxUnavailable: 1}}
  selector:
    matchLabels:
      app.kubernetes.io/name: oauth2-proxy
      app.kubernetes.io/instance: {host}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oauth2-proxy
        app.kubernetes.io/instance: {host}
        app.kubernetes.io/component: external-access
        app.kubernetes.io/part-of: oneinchmarket
    spec:
      serviceAccountName: oauth2-proxy
      automountServiceAccountToken: false
      hostAliases:
        - ip: "{node}"
          hostnames: ["keycloak.{domain}"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.12.0
          args:
            - --http-address=0.0.0.0:4180
            - --provider=keycloak-oidc
            - --oidc-issuer-url=https://keycloak.{domain}/realms/oneinchmarket
            - --provider-ca-file=/certs/ca.crt
            - --client-id=oauth2-proxy-{host}
            - --redirect-url=https://{host}.{domain}/oauth2/callback
            - --code-challenge-method=S256
            - --scope=openid email profile
            - --allowed-group=platform
            - --email-domain=*
            - --upstream=http://{usvc}:{uport}/
            - --reverse-proxy=true
            - --cookie-secure=true
            - --cookie-name=_oim_{cookie}
            - --skip-provider-button=true
            - --silence-ping-logging=true
            # 앱 로그아웃(/oauth2/sign_out)이 Keycloak 세션까지 끝낸다 — 세션의 ID 토큰으로 서버 쪽에서
            #   end_session 을 부른다. 없으면 앱 쿠키만 지워지고 SSO 세션이 남아 비밀번호 없이 다시 들어온다.
            - --backend-logout-url=https://keycloak.{domain}/realms/oneinchmarket/protocol/openid-connect/logout?id_token_hint={{id_token}}
            # 2분마다 refresh 토큰으로 Keycloak 세션을 다시 확인한다 — 다른 앱에서 로그아웃해 세션이 끝났으면
            #   갱신이 거절되어 이 앱도 로그인을 다시 요구한다(없으면 쿠키 만료 168시간까지 열린다).
            #   realm 의 access token 수명(300초)보다 짧게 둔다.
            - --cookie-refresh=2m
{args}          env:
            - name: OAUTH2_PROXY_CLIENT_SECRET
              valueFrom: {{secretKeyRef: {{name: oauth2-proxy-secret, key: {host}-client-secret}}}}
            - name: OAUTH2_PROXY_COOKIE_SECRET
              valueFrom: {{secretKeyRef: {{name: oauth2-proxy-secret, key: {host}-cookie-secret}}}}
          ports:
            - {{name: http, containerPort: 4180}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {{cpu: 10m, memory: 32Mi}}
            limits:   {{cpu: 200m, memory: 128Mi}}
          readinessProbe:
            httpGet: {{path: /ping, port: 4180}}
            periodSeconds: 10
          livenessProbe:
            httpGet: {{path: /ping, port: 4180}}
            periodSeconds: 20
          volumeMounts:
            - name: gateway-ca
              mountPath: /certs
              readOnly: true
      volumes:
        - name: gateway-ca
          secret:
            secretName: gateway-ca-cert
            items:
              - key: ca.crt
                path: ca.crt
---
# 게이트웨이가 이 백엔드에 **직접** 닿지 못하게 한다 — 라우트가 oauth2-proxy 를 건너뛰는 날의 방어선.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-gateway-direct-{host}
  labels:
    app.kubernetes.io/name: deny-gateway-direct-{host}
    app.kubernetes.io/component: external-access
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {podname}
  action: DENY
  rules:
    - from:
        - source:
            principals: ["*/sa/ingress-istio"]
""".format(host=host, lbl=lbl, node=NODE, domain=DOMAIN, usvc=upstream_svc,
           uport=upstream_port, cookie=host.replace("-", "_"), args=args,
           podname=podname)


def gen_o2p():
    rows = dict((r[0], r) for r in CATALOG)
    missing = [h for h in O2P if h not in rows]
    if missing:
        raise SystemExit("O2P 에 있고 CATALOG 에 없다: %s" % ", ".join(missing))
    hosts = " ".join(O2P)
    urls, secrets = [read(p) or "" for p in O2P_PEERS]
    if 'value: "%s"' % hosts not in urls:
        raise SystemExit("external-urls-local.yaml 의 O2P_HOSTS 가 O2P 와 다르다 — "
                         'value: "%s" 여야 한다' % hosts)
    gone = [k for h in O2P for k in ("%s-client-secret=" % h, "%s-cookie-secret=" % h)
            if k not in secrets]
    if gone:
        raise SystemExit("create-secrets.sh 에 없다: %s" % " ".join(gone))
    out = [O2P_HEADER]
    for h, (podname, extra) in O2P.items():
        _h, svc, port, scheme, _t, _n = rows[h]
        if scheme != "http":
            raise SystemExit("O2P 업스트림은 http 만 — %s" % h)
        out.append(o2p_yaml(h, svc, port, podname, extra))
    return "".join(out)


def gen_jwt_scope():
    """게이트웨이 JWT 필터를 JWT_GATEWAY_HOSTS 밖의 가상 호스트에서 끄는 EnvoyFilter."""
    out = ['''# 생성 파일 — 손으로 고치지 말 것. 원천은 local/render-external-access.py 의 CATALOG ·
#   JWT_GATEWAY_HOSTS(사유는 그 상수의 주석). `--check` 가 뒤처짐을 1 로 알린다.
#
# 게이트웨이 JWT 필터(envoy.filters.http.jwt_authn)를 **가상 호스트 단위로** 끈다(JwtPerRoute disabled).
#   RequestAuthentication 은 게이트웨이 전체에 걸려 자체 Bearer 토큰을 쓰는 앱을 막았다.
#   과금 경로(api)와 zilla 는 여기 없으므로 그대로 검증된다.
# ★ 판정: 그 호스트에 Keycloak 이 아닌 JWT 를 Bearer 로 보내 401 `Jwt issuer is not configured` 가
#   **사라지는지**, 그리고 api 호스트에서는 **그대로인지**(양방향 — Gotcha 200 ③ 과 같은 방식).
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: gateway-jwt-scope
  labels:
    app.kubernetes.io/name: gateway-jwt-scope
    app.kubernetes.io/component: gateway-routes
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: ingress
  configPatches:
''']
    for row in CATALOG:
        host = row[0]
        if host in JWT_GATEWAY_HOSTS:
            continue
        out.append('''    - applyTo: VIRTUAL_HOST
      match:
        context: GATEWAY
        routeConfiguration:
          vhost:
            name: "{host}.{domain}:443"
      patch:
        operation: MERGE
        value:
          typed_per_filter_config:
            envoy.filters.http.jwt_authn:
              "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.PerRouteConfig
              disabled: true
'''.format(host=host, domain=DOMAIN))
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
        front = "`oauth2-proxy-%s` -> " % host if host in O2P else ""
        rows.append("| https://%s.%s | %s | %s`%s:%d`%s | %s |" % (
            host, DOMAIN, TIER_MARK[tier], front, svc, port,
            " **(https)**" if scheme == "https" else "", note))
    return "\n".join(rows)


def md_open_list():
    names = ["`%s.%s`" % (h, DOMAIN) for h, _s, _p, _sc, t, _n in CATALOG
             if t == OPEN]
    if not names:
        return ("**0 종** — 2026-11-06 부터 없다. 남아 있던 열 곳은 oauth2-proxy + Keycloak 로그인"
                "(그룹 `platform`)으로 덮었다(O2P · Gotcha 213)")
    return "**%d 종** — %s" % (len(names), " · ".join(names))


# ★★ 외부에 **일부러 열지 않는** 호스트 (호스트, 닫은 날, 사유, 대신 쓰는 것).
#   예전에 열었다가 닫은 것이라 "왜 안 열리나" 가 반복해서 물어진다 — 문서의
#   GENERATED:closed-table 이 이것에서 나온다. 되살리기 전에 사유를 먼저 볼 것.
#   ★ CATALOG 와 겹치면 생성이 멈춘다(열면서 닫힌 목록에도 남는 모순).
CLOSED = [
    ("kafka-bridge", "2026-11-02",
     "자체 인증이 없어(SEC-206) LAN 의 누구나 과금 토픽에 쓸 수 있었다. JWT 만 요구하는 것으로도 "
     "부족하다 — 고객 테넌트의 client_credentials 토큰도 같은 realm 이라 남에게 청구를 떠넘길 수 있다(ADR-035)",
     "외부 HTTP->Kafka 는 `zilla.%s`(`edge.events` 하나에 갇힌다, §3-e)"),
    ("openmeter", "2026-11-03",
     "OSS 판은 자체 인증이 없어 `POST /api/v1/events` 로 어떤 테넌트 명의로든 사용량을 위조할 수 "
     "있었고, 고객·구독·인보이스 변경 API 도 열려 있었다. UI 가 없어(루트 404) 브라우저로 얻는 것도 없다",
     "조회는 Grafana(ClickHouse `openmeter` DB) 또는 port-forward(ACCESS.md)"),
    ("solr", "2026-11-03",
     "Ranger 감사 색인이다. Solr 에는 자체 인증이 없고 `solr-authz.yaml`(AuthorizationPolicy)이 "
     "메시 신원으로 지키는데, 게이트웨이 신원은 그 목록에 없다 — 경로를 되살려도 **503** 이다",
     "**Knox** — `https://knox.%s/gateway/oim/solr/`(DS389 로그인 · data-admin 만 · Solr 의 Ranger `oim-solr` 가 **읽기만** 준다, §4)"),
    ("kafka-connect", "2026-11-06",
     "커넥터를 만들고·지우고·설정을 바꾸는 관리 REST 인데 자체 인증이 없어 LAN 의 누구나 `POST /connectors` 를 "
     "할 수 있었다. 화면이 없는 JSON API 라 브라우저 로그인(oauth2-proxy)으로 덮어도 얻는 것이 없다. "
     "8083 은 `kafka-connect-rest-authz` 가 부트스트랩·AKHQ·워커 신원에만 연다 — 라우트를 되살려도 거부된다",
     "**AKHQ** — `https://akhq.%s` 의 Connect 메뉴(Keycloak 로그인 · `platform` 그룹만 connector-admin). 스크립트는 port-forward"),
    ("app-api", "2026-11-07",
     "`cmmn-api` 에 게이트웨이 뒤에서 바로 닿는 길이었다. 정식 입구 `api` 호스트가 거치는 JWT 검사 · SafeLine WAF · "
     "과금 계량 · 레이트 리밋을 **전부 건너뛰어**, LAN 의 누구나 계량되지 않고 WAF 없이 업무 API 를 부를 수 있었다",
     "`https://api.%s`(JWT 필수 · WAF · 계량) · 관리형은 `/managed`(Gravitee). 진단은 port-forward(ACCESS.md)"),
    ("loki", "2026-11-07",
     "3100 하나가 조회와 쓰기(`/loki/api/v1/push`)를 함께 받고 자체 인증이 없어, LAN 의 누구나 모든 파드의 로그를 "
     "읽고 **가짜 로그를 넣을** 수 있었다(사고 조사 증거를 흐린다). 소비자(Grafana·otel-gateway)는 `loki-headless` 로 "
     "클러스터 안에서 붙으므로 외부 경로가 필요 없다",
     "**Grafana** — `https://grafana.%s` 의 Explore(데이터 소스 Loki)"),
    ("ranger-solr", "2026-11-03",
     "`solr` 와 같은 백엔드의 다른 이름(Ranger Admin 설정이 이 이름을 쓴다). 사유도 같다",
     "위 `solr` 행과 같다 — Knox"),
]


def md_closed_table():
    open_hosts = set(r[0] for r in CATALOG)
    clash = [h for h, _d, _w, _i in CLOSED if h in open_hosts]
    if clash:
        raise SystemExit("CLOSED 와 CATALOG 에 함께 있다: %s" % ", ".join(clash))
    rows = ["| 호스트 | 닫은 날 | 왜 닫았나 | 대신 |", "|---|---|---|---|"]
    for host, day, why, instead in CLOSED:
        inst = instead % DOMAIN if "%s" in instead else instead
        rows.append("| ~~`%s.%s`~~ | %s | %s | %s |" % (host, DOMAIN, day, why, inst))
    return "\n".join(rows)


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
    ("closed-table", md_closed_table),
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

    jwtscope = gen_jwt_scope()
    o2p = gen_o2p()
    stale = []
    if read(O2P_FILE) != o2p:
        stale.append(O2P_FILE)
    if read(ROUTES) != routes:
        stale.append(ROUTES)
    if read(JWTSCOPE) != jwtscope:
        stale.append(JWTSCOPE)
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
    write(JWTSCOPE, jwtscope)
    write(O2P_FILE, o2p)
    write(DOC, doc)
    print("생성 완료 — %s" % md_counts())
    print("  %s" % os.path.relpath(ROUTES, ROOT))
    print("  %s" % os.path.relpath(DOC, ROOT))
    n_open = sum(1 for r in CATALOG if r[4] == OPEN)
    print("★ 인증 없는 호스트 %d 종 — LAN·VPN 안에서만 의미가 있다" % n_open)
    return 0


if __name__ == "__main__":
    sys.exit(main())
