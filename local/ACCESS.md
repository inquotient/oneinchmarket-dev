# Windows 에서 접근하기 — UI · DB 접속 정보

> 브랜치 `local` · 2026-09-06 실측
>
> **비밀번호는 이 문서에 적지 않는다.** 값 대신 **조회 명령**을 적는다 —
> 문서에 넣는 순간 git 에 들어가고, `CLAUDE.md` 가 금지하는 항목이다.

---

## 0. 접근 경로는 `port-forward` 하나뿐이다

실측 결과 외부로 열린 것은 **Istio Gateway 하나**다.

```
NodePort   ingress-istio   443→30727 · 80→31938 · 15021→32130
HTTPRoute  api             api.oneinchmarket.local   ← JWT 필수(§8-54)
```

즉 **게이트웨이를 통해 볼 수 있는 UI 가 없다.** 나머지는 전부 ClusterIP 라
`kubectl port-forward` 로 뚫어야 한다.

### 되는 것을 확인했다

```
Windows 브라우저  →  localhost:13000  →  WSL 의 port-forward  →  Grafana
                                                          HTTP 200 ✓
```

WSL2 의 `localhostForwarding`(기본 켜짐)이 Windows `localhost` 를 WSL 안으로
넘겨준다. **`--address 0.0.0.0` 은 필요 없다.**

### ★ 두 가지 주의

1. **port-forward 는 터미널이 살아 있어야 한다.** `wsl.exe -- bash -lc "... &"`
   로 띄우면 명령이 끝나는 순간 죽는다(실측). **WSL 터미널을 열어 두고 거기서
   실행할 것.** 여러 개를 쓰려면 터미널을 여러 개 열거나 `tmux` 를 쓴다.
2. **조용히 끊긴다.** 파드가 재생성되면 port-forward 가 죽고 브라우저에는
   연결 거부만 나온다. §8-50 에서 이것 때문에 파이프라인이 14시간 끊겨
   있었다. **안 보이면 먼저 port-forward 부터 확인할 것.**

### 공통 준비

```bash
# WSL 터미널에서
export K="sudo k3s kubectl -n local"

# 비밀번호 조회 헬퍼 (값이 화면에 찍히므로 필요할 때만)
pw() { $K get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; echo; }
# 예: pw grafana-secret admin-password
```

---

## 1. 웹 UI

로컬 포트는 겹치지 않게 임의로 정했다. 바꿔도 된다.

### 관측성

| 컴포넌트 | port-forward | URL | 계정 | 비밀번호 |
|---|---|---|---|---|
| **Grafana** | `$K port-forward deploy/grafana 3000:3000` | http://localhost:3000 | `admin` | `pw grafana-secret admin-password` |
| **Prometheus** | `$K port-forward prometheus-0 9090:9090` | http://localhost:9090 | 없음 | — |
| **Alertmanager** | `$K port-forward deploy/alertmanager 9093:9093` | http://localhost:9093 | 없음 | — |
| **Kibana** | `$K port-forward svc/kibana-kb-http 5601:5601` | **https**://localhost:5601 | `elastic` | `pw elasticsearch-es-elastic-user elastic` |
| Loki (API) | `$K port-forward svc/loki-headless 3100:3100` | http://localhost:3100/ready | 없음 | — |
| Tempo (API) | `$K port-forward svc/tempo-headless 3200:3200` | http://localhost:3200/status | 없음 | — |
| Pyroscope | `$K port-forward svc/pyroscope 4040:4040` | http://localhost:4040 | 없음 | — |
| kube-state-metrics | `$K port-forward deploy/kube-state-metrics 8080:8080` | http://localhost:8080/metrics | 없음 | — |

> Kibana 는 ECK 가 자체 서명 인증서를 쓴다 — 브라우저 경고를 무시해야 한다.

### 메시징 · 계약

| 컴포넌트 | port-forward | URL | 비고 |
|---|---|---|---|
| **AKHQ**(Kafka UI) | `$K port-forward akhq-0 8080:8080` | http://localhost:8080 | 인증 없음 |
| **Apicurio Registry** | `$K port-forward apicurio-registry-0 8081:8080` | http://localhost:8081 | API |
| **Apicurio UI** | `$K port-forward deploy/apicurio-ui 8888:8080` | http://localhost:8888 | **Registry 도 함께 forward 해야 한다**(SPA 가 API 를 부른다) |
| Kafka Bridge | `$K port-forward deploy/kafka-bridge 8082:8080` | http://localhost:8082 | ★ 자체 인증 없음(SEC-206) |

### 보안 · 거버넌스

| 컴포넌트 | port-forward | URL | 계정 | 비밀번호 |
|---|---|---|---|---|
| **Keycloak** | `$K port-forward keycloak-0 8083:8080` | http://localhost:8083 | `admin` | `pw keycloak-secret admin-password` |
| **Vault** | `$K port-forward vault-0 8200:8200` | http://localhost:8200 | 토큰 | `pw vault-init root-token` |
| **Ranger Admin** | `$K port-forward ranger-admin-0 6080:6080` | http://localhost:6080 | `admin` | `pw ranger-secret admin-password` |
| **LAM**(LDAP 관리) | `$K port-forward deploy/lam 8084:80` | http://localhost:8084 | — | `pw lam-secret master-password` |
| **Knox**(게이트웨이) | `$K port-forward svc/knox-headless 8443:8443` | https://localhost:8443/gateway/oim/ | DS389 사용자 | ★ **§1-b 참조** — WEBHDFS·HIVE·WEBHBASE 를 프록시한다 |
| **Wazuh Manager API** | `$K port-forward svc/wazuh-manager 55000:55000` | https://localhost:55000 | `pw wazuh-secret api-username` | `pw wazuh-secret api-password` |
| Wazuh Indexer | `$K port-forward svc/wazuh-indexer 9201:9200` | https://localhost:9201 | `admin` | `pw wazuh-secret indexer-admin-password` |
| **DefectDojo** | `$K port-forward svc/defectdojo 8085:8080` | http://localhost:8085 | `admin` | `pw defectdojo-secret admin-password` |
| **Dependency-Track** | `$K port-forward svc/dependency-track 8086:8080` | http://localhost:8086 | `admin`/`admin` | 최초 로그인 시 변경 요구 |
| SafeLine | `$K port-forward svc/safeline-mgt 1443:1443` | https://localhost:1443 | — | `caldera-secret`·`safeline-secret` 의 키를 먼저 확인할 것 |
| Caldera | `$K port-forward deploy/caldera 8887:8888` | http://localhost:8887 | `red`/`blue` | `$K get secret caldera-secret -o json` 로 키 확인 |

> **★ Ranger 로그인을 반복 실패하지 말 것.** 계정이 영구히 잠기고 파드를
> 재시작해도 안 풀린다(Gotcha 11). 비밀번호를 먼저 조회한 뒤 한 번에 넣을 것.
>
> **★ Vault 는 재시작하면 다시 봉인된다.** `vault-0` 이 `0/1` 이면 대개
> 이것이다 — `bash local/vault-init.sh unseal`.

### 1-b. Knox 게이트웨이 — HDFS·Hive·HBase 를 한 곳에서

§8-65 에서 "아무것도 프록시하지 않는다" 였던 것을 §8-66 에서 뚫었다.
**인증은 DS389 LDAP** 이고 세 서비스가 한 진입점 뒤에 있다.

```bash
$K port-forward svc/knox-headless 8443:8443
PW=$(pw ds389-secret sync-password)   # 예시 계정: ranger-sync
```

| 서비스 | 경로 | 확인 |
|---|---|---|
| **WebHDFS** | `https://localhost:8443/gateway/oim/webhdfs/v1/?op=LISTSTATUS` | 200 + 디렉터리 목록 |
| **HBase REST** | `https://localhost:8443/gateway/oim/hbase/version/cluster` | 200 + `2.6.6` |
| **Hive JDBC** | `jdbc:hive2://knox-headless:8443/default;ssl=true;transportMode=http;httpPath=gateway/oim/hive` | `show databases` 동작 |

```bash
# 예: WebHDFS
curl -k -u "ranger-sync:$PW" \n  'https://localhost:8443/gateway/oim/webhdfs/v1/?op=LISTSTATUS'
```

**인증 없이 부르면 401** 이다(확인함). DS389 에 없는 사용자·틀린 비밀번호도 401.

> **TLS** — cert-manager 가 `gateway-ca` 로 발급한다. SAN 에 `knox-headless` ·
> `knox-headless.local.svc.cluster.local` · `knox` · `localhost` 가 들어 있다.
> `curl -k` 로 넘기거나 `gateway-ca-cert` 의 `ca.crt` 를 신뢰하면 된다.
> JDBC 는 그 인증서를 트러스트스토어에 넣어야 한다.

> **★ Ranger 는 이 경로의 권한을 제어하지 않는다.** 플러그인이 없고 Ranger 에
> 등록된 서비스도 0개다(§8-66). Knox 가 **인증**은 하지만 **인가**는 아직
> POSIX 퍼미션(HDFS)과 무제한(Hive·HBase)이다.

### DevOps · 앱

| 컴포넌트 | port-forward | URL | 계정 | 비밀번호 |
|---|---|---|---|---|
| **GitLab** | `$K port-forward gitlab-0 8090:80` | http://localhost:8090 | `root` | `pw gitlab-secret root-password` |
| **Jenkins** | `$K port-forward jenkins-0 8091:8080` | http://localhost:8091 | `admin` | `pw jenkins-secret admin-password` |
| **GlitchTip** | `$K port-forward svc/glitchtip 8000:8000` | http://localhost:8000 | 가입 필요 | — |
| admin | `$K port-forward admin-0 3001:3000` | http://localhost:3001 | — | — |
| cmmn-api | `$K port-forward cmmn-api-0 8092:8080` | http://localhost:8092 | — | — |
| nginx | `$K port-forward svc/nginx 8093:80` | http://localhost:8093 | — | — |
| OpenMeter API | `$K port-forward svc/openmeter-api 8094:80` | http://localhost:8094 | 없음 | — |

### 레이크하우스

| 컴포넌트 | port-forward | URL | 비고 |
|---|---|---|---|
| **MinIO Console** | `$K port-forward svc/minio-headless 9001:9001` | http://localhost:9001 | `pw minio-secret root-user` / `root-password` |
| **Trino** | `$K port-forward svc/trino-headless 8095:8080` | http://localhost:8095 | 인증 없음 |
| Spark History | `$K port-forward spark-history-0 18080:18080` | http://localhost:18080 | |
| Spark Connect UI | `$K port-forward spark-connect-0 4041:4040` | http://localhost:4041 | |
| Livy | `$K port-forward livy-0 8998:8998` | http://localhost:8998 | |
| **HDFS NameNode** | `$K port-forward svc/hadoop-namenode 9870:9870` | http://localhost:9870 | lakehouse-local |
| HBase Master | `$K port-forward svc/hbase-master 16010:16010` | http://localhost:16010 | 〃 |
| HBase RegionServer | `$K port-forward svc/hbase-regionserver 16030:16030` | http://localhost:16030 | 〃 |
| HiveServer2 UI | `$K port-forward svc/hive-server-headless 10002:10002` | http://localhost:10002 | 〃 |
| Solr | `$K port-forward solr-0 8983:8983` | http://localhost:8983 | |

### OpenReplay (17종 — 프런트만)

```bash
$K port-forward deploy/frontend-openreplay 8096:8080   # http://localhost:8096
$K port-forward deploy/api-openreplay      8097:8080   # 프런트가 부르는 API
```

나머지 15종은 내부 서비스라 UI 가 없다.

---

## 2. DBeaver 접속 정보

> 2026-09-06 실측. **Windows 에서 실제로 붙여 확인했다** — ClickHouse `openmeter`
> 로 `SELECT currentUser(), version()` 이 `openmeter / 26.8.2.7` 을 돌려주고,
> PostgreSQL 은 `Test-NetConnection localhost:15432` 가 `True` 다.

### 2-0. ★ DBeaver 에디션부터 확인할 것

**Community Edition 은 관계형 DB 만 지원한다.** MongoDB·Redis·Elasticsearch 는
**Enterprise/Ultimate 전용**이다. CE 에서 그 드라이버를 찾으면 없다.

| DB | DBeaver CE | 대안(CE 사용자) |
|---|:-:|---|
| PostgreSQL · MariaDB · ClickHouse · Trino · Hive | ✅ | — |
| **MongoDB** | ❌ EE 전용 | MongoDB Compass(무료) |
| **Redis** | ❌ EE 전용 | RedisInsight(무료) · `redis-cli` |
| **Elasticsearch** | ❌ EE 전용 | Kibana Dev Tools · `curl` |

### 2-1. 먼저 port-forward

**WSL 터미널을 열어 두고** 거기서 실행한다. 하나당 터미널 하나이거나 `tmux` 다.

```bash
export K="sudo k3s kubectl -n local"
pw() { $K get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; echo; }

$K port-forward svc/postgresql-headless   15432:5432
$K port-forward svc/mariadb-headless      13306:3306
$K port-forward svc/clickhouse-headless   18123:8123
$K port-forward svc/trino-headless         8095:8080
$K port-forward svc/hive-server-headless  10000:10000
$K port-forward svc/mongodb-headless      17017:27017   # Compass 용
$K port-forward svc/redis-headless        16379:6379    # RedisInsight 용
$K port-forward svc/elasticsearch-es-http 19200:9200    # curl/Kibana 용

# 관계형 DB 접근 계층 (§8-75·§8-76) — 아직 소비자가 없다. 프록시가 실제로
# 통하는지 직접 확인할 때만 쓴다. 평소 작업은 위의 직접 접속을 쓸 것.
$K port-forward svc/shardingsphere        13307:3307    # PostgreSQL 와이어
$K port-forward svc/proxysql              16033:6033    # MySQL 와이어
```

---

### 2-2. PostgreSQL 18.6 — ★ 가장 중요한 것

과금 원장·인증·메타데이터가 전부 여기 있다.

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **PostgreSQL** |
| Host | `localhost` |
| Port | `15432` |
| Database | `postgres` (접속 후 다른 DB 로 전환) |
| Username | `postgres` |
| Password | `pw postgresql-secret postgres-password` |
| SSL | **끔** |
| JDBC URL | `jdbc:postgresql://localhost:15432/postgres` |

> **Show all databases** 를 켜야 13개가 다 보인다 —
> PostgreSQL 연결 설정 → *PostgreSQL* 탭 → `Show all databases` 체크.

**데이터베이스 13개**(실측)

| DB | 무엇이 들어 있나 |
|---|---|
| **`openmeter`** | ★ **과금 원장** — 요금제·구독·인보이스·미터 정의 |
| `oneinchmarket` | 앱 기본 DB |
| `keycloak` | 인증·사용자·클라이언트 |
| `gitlab` | GitLab |
| `apicurio` | API 계약 레지스트리 |
| `hive_metastore` | Hive 메타데이터(테이블·파티션) |
| `openreplay` | 세션 리플레이 메타 |
| `glitchtip` | 오류 추적 |
| `defectdojo` · `dependencytrack` | 취약점 관리 |
| `ranger` | 권한 정책 · ★ `x_auth_sess`(Gotcha 11 의 계정 잠금) |
| `safeline` | WAF |
| `postgres` | 관리용 |

앱별 롤도 있다(`keycloak` `gitlab` `openmeter` …). 그 비밀번호는 각 앱
시크릿의 `db-password` 다 — 예: `pw keycloak-secret db-password`.

### 2-3. MariaDB 12.3

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **MariaDB** |
| Host / Port | `localhost` / `13306` |
| Database | `cmmn` |
| Username | `root` |
| Password | `pw mariadb-secret root-password` |
| JDBC URL | `jdbc:mariadb://localhost:13306/cmmn` |

사용자 셋: `root` · `cmmn` · `cmmn-api`(앱용, `pw mariadb-secret app-password`).

### 2-4. ClickHouse 26.8 — ★ 함정

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **ClickHouse** |
| Host / Port | `localhost` / `18123` (HTTP) |
| Database | `openmeter` 또는 `openreplay` |
| Username | **`openmeter`** 또는 **`openreplay`** |
| Password | `pw clickhouse-secret openmeter-password` / `pw clickhouse-secret password` |
| JDBC URL | `jdbc:clickhouse://localhost:18123/openmeter` |

> **★ `default` 사용자가 이 인스턴스에 없다**(Gotcha 27). DBeaver 는 기본으로
> `default` 를 넣으므로 **반드시 지우고 위 둘 중 하나를 쓸 것.** 그대로 두면
> `Code: 194 ... there is no user with such name` 이다(실측).
>
> `system.users` 에 있는 것은 **`openreplay` · `openmeter` 둘뿐**이다.

데이터베이스: `openmeter`(★ 과금 집계) · `openreplay` · `product_analytics` ·
`experimental` · `system`.

### 2-5. Trino 483

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **Trino** |
| Host / Port | `localhost` / `8095` |
| Username | 아무 값(예: `admin`) — 인증 없음 |
| Password | 비움 |
| JDBC URL | `jdbc:trino://localhost:8095/` |

카탈로그는 `hive`(MinIO 의 Iceberg·Parquet)와 `system` 이다. 웹 UI 도 같은
포트다 — http://localhost:8095

### 2-6. HiveServer2

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **Apache Hive** |
| Host / Port | `localhost` / `10000` |
| Database | `default` |
| 인증 | 없음(NOSASL) — 사용자 아무 값 |
| JDBC URL | `jdbc:hive2://localhost:10000/default` |

> 테이블 목록만 보려면 **PostgreSQL 의 `hive_metastore` DB 를 직접 보는 편이
> 훨씬 빠르다** — `TBLS` · `DBS` · `PARTITIONS` 테이블.

---

### 2-7. 관계형 DB 접근 계층 — ShardingSphere · ProxySQL

> **★ 아직 소비자가 없다.** 두 프록시는 기존 `postgresql-headless`·
> `mariadb-headless` 와 **나란히** 서 있고, 어떤 워크로드도 이쪽으로 붙지
> 않는다(§8-75·§8-76). 평소 DB 작업은 위의 §2-2·§2-3 을 쓸 것.
> 여기는 **프록시가 실제로 통하는지 직접 확인할 때** 쓴다.
>
> 인스턴스당 프런트엔드 프로토콜이 하나라 둘로 나뉜다 — ShardingSphere 가
> PostgreSQL 와이어, ProxySQL 이 MySQL 와이어다.

**ShardingSphere-Proxy 5.5.3** — PostgreSQL 와이어

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **PostgreSQL** |
| Host / Port | `localhost` / `13307` |
| Database | `oim` ← ★ 논리 DB 이름이다. 뒤쪽 실제 DB 는 `oneinchmarket` |
| Username | `proxyadmin` |
| Password | `pw shardingsphere-secret proxy-password` |
| JDBC URL | `jdbc:postgresql://localhost:13307/oim` |

확인용 질의 — 스토리지 유닛이 보이면 프록시가 백엔드를 물고 있는 것이다:

```sql
SHOW STORAGE UNITS FROM oim;
SELECT current_database(), version();   -- → oneinchmarket / PostgreSQL 18.6
```

**ProxySQL 4.0.11** — MySQL 와이어

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **MariaDB** |
| Host / Port | `localhost` / `16033` |
| Database | `cmmn` |
| Username | `cmmn-api` |
| Password | `pw cmmn-api-secret db-password` |
| JDBC URL | `jdbc:mariadb://localhost:16033/cmmn` |

```sql
SELECT VERSION(), @@hostname;   -- → 12.3.3-MariaDB-ubu2404 / mariadb-0
```

★ ProxySQL 의 **관리 인터페이스(6032)는 Service 로 노출하지 않는다.** 런타임
설정을 바꾸는 문이라 `mysql_ifaces` 가 `127.0.0.1` 로만 바인딩한다. 필요하면
파드 안에서:

```bash
$K exec -it deploy/proxysql -- mysql -h127.0.0.1 -P6032 -uadmin \
  -p"$(pw proxysql-secret admin-password)" -e "SELECT * FROM mysql_servers;"
```

★ ProxySQL 은 `.cnf` 를 **첫 기동에만** 읽는다(그 뒤에는 datadir 의 SQLite 가
권위를 갖는다). 이 레포는 datadir 이 emptyDir 이라 매 기동이 새것이다 —
설정을 바꾸려면 ConfigMap 을 고치고 파드를 재시작하면 된다.

★★ **둘 다 클러스터 안에서 실제 질의로 확인했다(2026-09-07).** ProxySQL 은
프록시 경유와 직접 접속이 **같은 백엔드**(`mariadb-0` · 12.3.3)를 돌려주고,
ShardingSphere 는 논리 DB `oim` 이 `postgresql-headless:5432` 를 물고 있다.

★ **여기서 접속이 안 되면 프록시를 먼저 의심하지 말 것.** 증상이
`ERROR 2013 ... reading initial communication packet`(MySQL) 이나
`EOFException`(PostgreSQL) 이면 **앰비언트 메시가 그 파드를 놓친 것**일 수
있다 — ztunnel 을 재시작하면 기존 파드가 메시에서 빠지고 아무도 다시 넣어
주지 않는다(Gotcha 50 · §8-78). 판정은 **대조군**이다:

```bash
# 프록시를 거치지 않는 직접 접속. 같이 실패하면 프록시 문제가 아니다.
$K run t --rm -it --image=mariadb:12.3.3 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"cmmn-api"}}' -- \
  mariadb -h mariadb-headless -u cmmn-api -p"$(pw cmmn-api-secret db-password)" -e "SELECT 1;"

# 메시가 절반만 서 있는지 — 두 수가 크게 다르면 그렇다
$K logs -n istio-system ds/ztunnel | grep -c "pod received, starting proxy"
$K get pods -A --no-headers | wc -l
# 처방
$K rollout restart -n istio-system ds/istio-cni-node
```

### 2-8. DBeaver CE 로는 안 되는 것 — 대안

#### MongoDB 8.0 — MongoDB Compass

```
mongodb://root:<비밀번호>@localhost:17017/?authSource=admin
```

`pw mongodb-secret root-password` 로 비밀번호를 얻는다.
**★ `authSource=admin` 을 빠뜨리면 인증 실패한다.**

#### Redis 8.10 — RedisInsight 또는 redis-cli

| 항목 | 값 |
|---|---|
| Host / Port | `localhost` / `16379` |
| Username | 비움(ACL 미사용) |
| Password | `pw redis-secret redis-password` |

```bash
# WSL 안에서
redis-cli -h 127.0.0.1 -p 16379 -a "$(pw redis-secret redis-password)" --no-auth-warning INFO keyspace
```

> ★ OpenMeter 의 **중복 제거 키**가 여기 있다. `FLUSHALL` 을 치지 말 것 —
> 지우면 이미 처리한 과금 이벤트가 다시 들어와 **과다 청구**가 된다(Gotcha 16).

#### Elasticsearch 9.5.2 — curl 또는 Kibana Dev Tools

```bash
curl -sk -u "elastic:$(pw elasticsearch-es-elastic-user elastic)"   https://localhost:19200/_cat/indices?v
```

| 항목 | 값 |
|---|---|
| URL | **https**://localhost:19200 |
| Username | `elastic` |
| Password | `pw elasticsearch-es-elastic-user elastic` |
| 인증서 | 자체 서명 — 검증을 꺼야 한다(`-k`) |

> **수기 `elasticsearch-secret` 을 쓰지 말 것 — 낡아서 401 이다.** 권위 있는
> 소유자는 ECK 의 `elasticsearch-es-elastic-user` 다(§8-64 에서 이것 때문에
> Falco 경보가 전부 버려지고 있었다).

Kibana(https://localhost:5601) 의 **Dev Tools** 가 가장 편하다.

#### 그 밖 — DBeaver 대상이 아닌 것

| 대상 | 도구 |
|---|---|
| `ds389` LDAP 3389 / LDAPS 3636 | Apache Directory Studio · `ldapsearch` · LAM UI(8084). `pw ds389-secret dm-password` |
| `kafka` 9092 | **AKHQ UI(8080)가 가장 편하다** · `kcat` |
| `zookeeper` 2181 | `zkCli.sh` |
| `minio` S3 9002 | `mc` · `s3cmd` · 콘솔 UI(9001) |
| `spark-connect` 15002 | PySpark `SparkSession.builder.remote("sc://localhost:15002")` |
| `hadoop-namenode` 8020 | `hdfs dfs` · UI(9870) |
| `vault` 8200 | `vault` CLI · UI |

---

## 2-b. 전체 표 — 서비스 88개 · 포트 152개

> **§1·§2 는 자주 쓰는 것만 골라 손으로 적은 것이라 빠진 것이 있었다**
> (첫 판이 40여 개). 아래는 살아 있는 클러스터에서 생성한 **전부**다.
>
> ```
> python3 local/access-gen.py --md
> ```
>
> 규칙에 없는 서비스는 `미분류` 로 나온다 — 서비스가 늘면 다시 돌릴 것.

```
서비스 88 개 · 포트 152 개 — UI 44 · API 17 · DB 19 · INT 72
```

| 종류 | 뜻 |
|:-:|---|
| **UI** | 브라우저로 본다 |
| **API** | HTTP 이지만 사람이 볼 화면은 아니다 — `curl`·도구용 |
| **DB** | 전용 클라이언트로 붙는다 — DBeaver·LDAP 툴·kcat·mc 등 |
| INT | 내부 전용. 사람이 붙을 일이 없다(메시·수신 포트·앙상블) |

`로컬` 열은 권장 port-forward 포트다. `—` 는 forward 할 이유가 없다는 뜻이다.

| 종류 | 서비스 | 포트 | 로컬 | 접속 / 비고 |
|:-:|---|--:|--:|---|
| UI | `admin-headless` | 3000 | 3001 |  |
| UI | `akhq-headless` | 8080 | 8080 | Kafka UI · 인증 없음 |
| UI | `alertmanager` | 9093 | 9093 | 인증 없음 |
| UI | `apicurio-ui` | 8080 | 8888 | ★ Registry(8081)도 함께 forward |
| UI | `caldera` | 8888 | 8887 | red/blue — `caldera-secret` 키를 먼저 확인 |
| UI | `defectdojo` | 8080 | 8085 | admin / `pw defectdojo-secret admin-password` |
| UI | `dependency-track` | 8080 | 8086 | admin/admin — 최초 로그인 시 변경 요구 |
| UI | `frontend-openreplay` | 8080 | 8096 | OpenReplay frontend |
| UI | `gitlab-headless` | 80 | 8090 | root / `pw gitlab-secret root-password` |
| UI | `gitlab-headless` | 443 | 8443 | https |
| UI | `glitchtip` | 8000 | 8000 | 가입 필요 |
| UI | `grafana-headless` | 3000 | 3000 | admin / `pw grafana-secret admin-password` |
| UI | `hadoop-datanode-headless` | 9864 | 9864 | DataNode UI |
| UI | `hadoop-namenode` | 9870 | 9870 | HDFS UI |
| UI | `hadoop-namenode-headless` | 9870 | 9870 | HDFS UI |
| UI | `hbase-master` | 16010 | 16010 |  |
| UI | `hbase-regionserver` | 16030 | 16030 |  |
| UI | `hive-server-headless` | 10002 | 10002 | HiveServer2 웹 |
| UI | `ingress-istio` | 80 | 31938 | **NodePort** — http://localhost:31938(https 로 리다이렉트) |
| UI | `ingress-istio` | 443 | 30727 | **NodePort — forward 불필요.** https://localhost:30727 |
| UI | `jenkins-headless` | 8080 | 8091 | admin / `pw jenkins-secret admin-password` |
| UI | `keycloak-headless` | 8080 | 8083 | admin / `pw keycloak-secret admin-password` |
| UI | `keycloak-headless` | 8443 | 8446 | TLS 쪽 |
| UI | `kibana-kb-http` | 5601 | 5601 | **https** · elastic / `pw elasticsearch-es-elastic-user elastic` |
| UI | `knox-headless` | 8443 | 8443 | https · `pw knox-secret master-secret` |
| UI | `lam-headless` | 80 | 8084 | `pw lam-secret master-password` |
| UI | `livy-headless` | 8998 | 8998 |  |
| UI | `minio-headless` | 9001 | 9001 | 콘솔 · `pw minio-secret root-user`/`root-password` |
| UI | `nginx` | 80 | 8093 |  |
| UI | `nginx` | 443 | 8447 | https |
| UI | `prometheus-headless` | 9090 | 9090 | 인증 없음 |
| UI | `pyroscope` | 4040 | 4040 | 인증 없음 |
| UI | `pyroscope-headless` | 4040 | 4042 | 위 pyroscope 와 같은 것 |
| UI | `ranger-admin` | 6080 | 6080 | admin / `pw ranger-secret admin-password` · ★ 반복 실패 금지(Gotcha 11) |
| UI | `ranger-solr` | 8983 | 8984 | Ranger 감사 색인 |
| UI | `safeline` | 80 | 8101 | http(별칭) |
| UI | `safeline` | 1443 | 1444 | https(별칭) |
| UI | `safeline-mgt` | 80 | 8100 | http |
| UI | `safeline-mgt` | 1443 | 1443 | https |
| UI | `solr-headless` | 8983 | 8983 | 거버넌스 Solr |
| UI | `spark-connect-headless` | 4040 | 4041 | Spark UI |
| UI | `spark-history-headless` | 18080 | 18080 |  |
| UI | `trino-headless` | 8080 | 8095 | 웹 UI + JDBC `jdbc:trino://localhost:8095/` |
| UI | `vault-headless` | 8200 | 8200 | 토큰 `pw vault-init root-token` |
| API | `api-openreplay` | 8080 | 8097 | OpenReplay api |
| API | `apicurio-registry-headless` | 8080 | 8081 | Registry API — UI 와 함께 띄울 것 |
| API | `chalice-openreplay` | 8000 | 8098 | OpenReplay chalice |
| API | `cmmn-api-headless` | 8080 | 8092 |  |
| API | `dependency-track-api` | 8080 | 8087 | 프런트가 부르는 API |
| API | `falcosidekick` | 2801 | 2801 | Falco 수신 webhook · `/healthz` |
| API | `ingress-istio` | 15021 | 32130 | **NodePort** — Envoy 헬스 |
| API | `kafka-bridge` | 8080 | 8082 | HTTP→Kafka · ★ 자체 인증 없음(SEC-206) |
| API | `kube-state-metrics` | 8080 | 8089 | `/metrics` |
| API | `logstash-headless` | 9600 | 9600 | 파이프라인 상태 `/_node/stats` |
| API | `loki-headless` | 3100 | 3100 | `/ready` · Grafana 가 소비 |
| API | `openmeter-api` | 80 | 8094 | 과금 수집·조회 API |
| API | `otel-gateway` | 8889 | 8889 | `/metrics`(Prometheus exporter) |
| API | `safeline-fvm` | 80 | 8102 | 취약점 관리 모듈 |
| API | `tempo-headless` | 3200 | 3200 | `/status` · Grafana 가 소비 |
| API | `wazuh-indexer` | 9200 | 9201 | https · admin / `pw wazuh-secret indexer-admin-password` |
| API | `wazuh-manager` | 55000 | 55000 | https · `pw wazuh-secret api-username`/`api-password` |
| DB | `clickhouse-headless` | 8123 | 18123 | ★ **openmeter**/**openreplay** — `default` 없음(Gotcha 27) |
| DB | `clickhouse-headless` | 9000 | 19000 | native 프로토콜 |
| DB | `ds389-headless` | 3389 | 3389 | LDAP · `pw ds389-secret dm-password` |
| DB | `ds389-headless` | 3636 | 3636 | LDAPS |
| DB | `elasticsearch-es-http` | 9200 | 19200 | https · elastic / **ECK 시크릿**(수기 것은 401) |
| DB | `gitlab-headless` | 22 | 2222 | git+ssh |
| DB | `hadoop-namenode` | 8020 | 8020 | HDFS RPC |
| DB | `hadoop-namenode-headless` | 8020 | 8020 | HDFS RPC |
| DB | `hive-metastore-headless` | 9083 | 9083 | Thrift — 메타데이터 원본은 PG `hive_metastore` |
| DB | `hive-server-headless` | 10000 | 10000 | JDBC `jdbc:hive2://localhost:10000/default` |
| DB | `kafka-headless` | 9092 | 9092 | Kafka 클라이언트(kcat) — AKHQ 가 더 편하다 |
| DB | `mariadb-headless` | 3306 | 13306 | root / `pw mariadb-secret root-password` · DB `cmmn` |
| DB | `minio-headless` | 9000 | 9002 | S3 API — mc·s3cmd 용(DBeaver 아님) |
| DB | `mongodb-headless` | 27017 | 17017 | root / `pw mongodb-secret root-password` · **authSource=admin** |
| DB | `postgresql-headless` | 5432 | 15432 | postgres / `pw postgresql-secret postgres-password` · DB 13개 |
| DB | `ranger-db` | 5432 | 15433 | PostgreSQL 별칭 — 같은 인스턴스다 |
| DB | `redis-headless` | 6379 | 16379 | `pw redis-secret redis-password` · 과금 중복제거 키 |
| DB | `spark-connect-headless` | 15002 | 15002 | Spark Connect gRPC — PySpark 클라이언트 |
| DB | `zookeeper-headless` | 2181 | 2181 | zkCli |
| INT | `alerts-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `alerts-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `api-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `assets-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `assets-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `assist-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `assist-openreplay` | 9001 | — | OpenReplay 내부 |
| INT | `canvases-openreplay` | 8080 | — | OpenReplay 내부 |
| INT | `canvases-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `chalice-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `db-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `db-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `defectdojo-django` | 3031 | — | nginx 뒤의 uwsgi |
| INT | `elasticsearch-es-default` | 9200 | — | 파드 직접 |
| INT | `elasticsearch-es-internal-http` | 9200 | — | ECK 내부 |
| INT | `elasticsearch-es-transport` | 9300 | — | 노드 간 |
| INT | `ender-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `ender-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `hadoop-datanode-headless` | 9866 | — |  |
| INT | `hadoop-datanode-headless` | 9867 | — |  |
| INT | `hbase-master` | 16000 | — | RPC |
| INT | `hbase-regionserver` | 16020 | — | RPC |
| INT | `heuristics-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `heuristics-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `http-openreplay` | 8080 | — | OpenReplay 내부 |
| INT | `http-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `images-openreplay` | 8080 | — | OpenReplay 내부 |
| INT | `images-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `integrations-openreplay` | 8080 | — | OpenReplay 내부 |
| INT | `integrations-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `jenkins-headless` | 50000 | — | 에이전트 JNLP |
| INT | `kafka-bridge` | 8081 | — |  |
| INT | `kafka-headless` | 9093 | — | KRaft 컨트롤러 |
| INT | `logstash-headless` | 5044 | — | beats 입력 |
| INT | `logstash-headless` | 5140 | — | L0 랩 syslog 입력(§8-34) |
| INT | `logstash-headless` | 5141 | — | syslog 입력 |
| INT | `logstash-headless` | 5142 | — | Alertmanager webhook 입력(§8-63) |
| INT | `loki-headless` | 9095 | — | gRPC |
| INT | `openreplay-tracker` | - | — | ExternalName 별칭 |
| INT | `otel-agent` | 4317 | — | OTLP gRPC |
| INT | `otel-agent` | 4318 | — | OTLP HTTP |
| INT | `otel-gateway` | 4317 | — | OTLP gRPC |
| INT | `otel-gateway` | 4318 | — | OTLP HTTP |
| INT | `otel-gateway` | 4319 | — | OTLP 추가 |
| INT | `pyroscope-headless` | 7946 | — | memberlist |
| INT | `pyroscope-headless` | 9095 | — |  |
| INT | `redis-headless` | 16379 | — | 클러스터 버스(미사용) |
| INT | `safeline-chaos` | 8080 | — |  |
| INT | `safeline-chaos` | 8088 | — |  |
| INT | `safeline-chaos` | 9000 | — |  |
| INT | `safeline-detector` | 8000 | — | 탐지 엔진 |
| INT | `safeline-detector` | 8001 | — |  |
| INT | `safeline-fvm` | 9004 | — |  |
| INT | `sink-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `sink-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `sourcemapreader-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `sourcemapreader-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `spark-connect-headless` | 7078 | — |  |
| INT | `spark-connect-headless` | 7079 | — |  |
| INT | `spot-openreplay` | 8080 | — | OpenReplay 내부 |
| INT | `spot-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `storage-openreplay` | 8888 | — | 내부 메트릭·헬스 |
| INT | `storage-openreplay` | 9000 | — | OpenReplay 내부 |
| INT | `tempo-headless` | 4317 | — | OTLP gRPC 수신 |
| INT | `tempo-headless` | 4318 | — | OTLP HTTP 수신 |
| INT | `vault-headless` | 8201 | — | Raft 클러스터 포트(미사용) |
| INT | `waypoint` | 15008 | — | HBONE |
| INT | `waypoint` | 15021 | — | Istio 내부 |
| INT | `wazuh-manager` | 1514 | — | 에이전트 수신 |
| INT | `wazuh-manager` | 1515 | — | 에이전트 등록 |
| INT | `zookeeper-headless` | 2888 | — | 앙상블 내부 |
| INT | `zookeeper-headless` | 3888 | — | 앙상블 선출 |

## 3. 자주 걸리는 것

| 증상 | 원인 |
|---|---|
| 브라우저가 연결 거부 | port-forward 가 죽었다. 터미널을 확인할 것 |
| ClickHouse `code: 516` | `default` 사용자로 붙었다 — `openmeter`/`openreplay` 를 쓸 것 |
| ES 401 | 수기 `elasticsearch-secret` 을 썼다 — ECK 시크릿을 쓸 것 |
| MongoDB 인증 실패 | `authSource=admin` 을 안 넣었다 |
| Ranger 401 이 계속 | **계정이 잠겼다**(Gotcha 11). DB 에서 `auth_status` 를 지워야 한다 |
| Vault 가 `0/1` | 봉인 상태다 — `local/vault-init.sh unseal` |
| Apicurio UI 가 빈 화면 | Registry API 를 함께 forward 하지 않았다 |

---

## 관련 문서

- [NEXT-SESSION.md](./NEXT-SESSION.md) — 인수인계. 짧은 확인 명령 모음
- [../docs/LOCAL-DEPLOYMENT.md](../docs/LOCAL-DEPLOYMENT.md) — §8 실배포 기록, Gotcha 의 출처
- [../CLAUDE.md](../CLAUDE.md) — Gotchas 전체
