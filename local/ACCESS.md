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
| Knox | `$K port-forward svc/knox-headless 8443:8443` | https://localhost:8443 | — | `pw knox-secret master-secret` |
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

**먼저 port-forward 를 띄운다.** 아래 로컬 포트는 원래 포트와 겹치지 않게
`1`을 앞에 붙였다.

```bash
$K port-forward svc/postgresql-headless  15432:5432
$K port-forward svc/mariadb-headless     13306:3306
$K port-forward svc/mongodb-headless    17017:27017
$K port-forward svc/redis-headless       16379:6379
$K port-forward svc/clickhouse-headless  18123:8123   # HTTP
$K port-forward svc/clickhouse-headless  19000:9000   # native
$K port-forward svc/elasticsearch-es-http 19200:9200
$K port-forward svc/hive-server-headless 10000:10000  # JDBC
$K port-forward svc/trino-headless        8095:8080   # JDBC
```

### PostgreSQL

| | |
|---|---|
| 드라이버 | PostgreSQL |
| Host / Port | `localhost` / `15432` |
| 사용자 | `postgres` (수퍼유저) |
| 비밀번호 | `pw postgresql-secret postgres-password` |
| SSL | 끔 |

**데이터베이스 13개**(실측):

```
apicurio · defectdojo · dependencytrack · gitlab · glitchtip · hive_metastore
keycloak · oneinchmarket · openmeter · openreplay · postgres · ranger · safeline
```

앱별 롤도 있다 — `apicurio` `defectdojo` `dependencytrack` `gitlab`
`glitchtip` `hive` `keycloak` `openmeter` `openreplay` `ranger` `safeline`.
각 비밀번호는 해당 앱의 시크릿에 있다(예: `pw keycloak-secret db-password`).

> **과금 원장이 여기 있다** — `openmeter` DB 에 요금제·구독·인보이스가,
> `oneinchmarket` 이 앱 기본 DB 다.

### MariaDB

| | |
|---|---|
| 드라이버 | MariaDB |
| Host / Port | `localhost` / `13306` |
| 사용자 | `root` |
| 비밀번호 | `pw mariadb-secret root-password` |
| 데이터베이스 | `cmmn` |

사용자는 `root` · `cmmn` · `cmmn-api` 셋이다(실측).

### MongoDB

| | |
|---|---|
| 드라이버 | MongoDB |
| Host / Port | `localhost` / `17017` |
| 사용자 | `root` |
| 비밀번호 | `pw mongodb-secret root-password` |
| **Authentication Database** | **`admin`** ← 빠뜨리면 인증 실패한다 |

### Redis

| | |
|---|---|
| 드라이버 | Redis |
| Host / Port | `localhost` / `16379` |
| 비밀번호 | `pw redis-secret redis-password` |

OpenMeter 의 **중복 제거 키**가 여기 있다 — 지우면 과다 청구가 된다(Gotcha 16).

### ClickHouse — ★ 함정 있음

| | |
|---|---|
| 드라이버 | ClickHouse |
| Host / Port | `localhost` / `18123` (HTTP) 또는 `19000` (native) |
| **사용자** | **`openmeter`** 또는 **`openreplay`** |
| 비밀번호 | `pw clickhouse-secret openmeter-password` / `pw clickhouse-secret password` |

> **★ `default` 사용자가 이 인스턴스에 없다**(Gotcha 27). DBeaver 기본값이
> `default` 라 그대로 붙으면
> `code: 516 ... there is no user with such name` 이 난다.
> `system.users` 에 있는 것은 **`openreplay` · `openmeter` 둘뿐**이다(실측).

데이터베이스: `openmeter`(과금 집계) · `openreplay` · `product_analytics` ·
`experimental` · `system`.

### Elasticsearch

| | |
|---|---|
| 접속 | **https**://localhost:19200 |
| 사용자 | `elastic` |
| 비밀번호 | `pw elasticsearch-es-elastic-user elastic` |
| 인증서 | 자체 서명 — **검증을 꺼야 한다** |

DBeaver 보다 브라우저나 `curl -k` 가 편하다.

```bash
curl -sk -u "elastic:$(pw elasticsearch-es-elastic-user elastic)" \
  https://localhost:19200/_cat/indices?v
```

> **수기 `elasticsearch-secret` 을 쓰지 말 것** — 낡아서 401 이다.
> 권위 있는 소유자는 ECK 의 `elasticsearch-es-elastic-user` 다(§8-64).

### Hive Metastore / HiveServer2

| | |
|---|---|
| 드라이버 | Apache Hive |
| JDBC | `jdbc:hive2://localhost:10000/default` |
| 인증 | 없음(NOSASL) |

메타데이터 자체는 PostgreSQL 의 `hive_metastore` DB 에 있다 — 그쪽을 직접
보는 편이 빠를 때가 많다.

### Trino

| | |
|---|---|
| 드라이버 | Trino |
| JDBC | `jdbc:trino://localhost:8095/` |
| 사용자 | 아무 값(인증 없음) |

---

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
