# 다음 세션 인수인계

> 브랜치 `local` · 최종 갱신 **2026-09-05** (7·8단계 워크로드 전부 기동 · 과금 계량 완성 · 경보 체계 도입 · Falco 복구)

## ★ 브랜치 정책 — 결정됨 (ADR-068)

**환경은 오버레이로 나눈다. 브랜치는 버전 축이다.** `local` 은 환경 브랜치가 아니라
v2 를 실배포로 검증하는 작업 라인이며, **7단계까지 끝난 뒤 `v2` 로 합치고 소멸한다.**
`v3` 로 개명하지 않는다 — 커밋을 옮기지 못하면서 드리프트에 명분만 준다.

**머지 전에 반드시 (순서 그대로):**

1. **prod `targetRevision` 을 태그로 고정** — 지금 dev·prod 가 **둘 다** `v2` 를 보고
   `selfHeal` 이라 CI 의 prod `when: manual` 이 무력하다. 머지하면 dev 만이 아니라
   prod 도 같이 맞는다
2. **dev 의 `automated` 를 일시 해제** — 머지 시 dev 오버레이가 98 → 234 오브젝트,
   **신규 워크로드 26종**이 한 번에 뜬다
3. **wave 순으로 분할 머지** — 오퍼레이터(ECK·Kyverno·cert-manager·Tetragon) →
   관측성 → 거버넌스 → 보안. 오퍼레이터가 로컬에서만 검증된 상태라 첫 단계가 관문이다

**지금 상태** — `local` 은 `v2` 대비 **179 앞** · **0 뒤**(fast-forward 유지).
누가 `v2` 에 커밋하면 이 성질이 깨지므로 그때는 즉시 rebase 할 것.
공유 수정 93건이 아직 dev/prod 에 미도달이다.

## 지금 상태

```
전체 106 파드 · 미준비 0 · 미완 StatefulSet 0        (2026-09-05 실측)

requests  메모리 92% (38.9 GiB)   CPU 75% (17.6 코어)
limits    메모리 210%             CPU 334%   ← 오버커밋. 게이트는 requests 다
```

> ★ **파드 수가 실질 한계에 닿았다.** k3s 노드 기본 상한이 110 이고 지금 106 이다.
> Falco 를 추가할 때 실제로 `0/1 nodes are available: 1 Too many pods` 로
> 스케줄이 막혔다(옛 파드가 빠지기 전까지). 새 워크로드를 넣기 전에 파드 수를
> 먼저 볼 것 — 메모리보다 이쪽이 먼저 걸린다.

> 재시작 횟수가 전반적으로 20~47 이다(마지막 재시작은 대부분 하루 이상 전이다). 대부분 **WSL2 VM 이 내려갔다 올라온** 흔적이다
> (아래 keep-alive 항목). 워크로드 결함이 아니다.

| 계층 | 상태 |
|---|---|
| 플랫폼 | Cilium 1.16.5 · Istio ambient · Gateway API · ECK 3.2.0 · Kyverno · cert-manager |
| core | PostgreSQL·MariaDB·MongoDB·Redis · Kafka · Apicurio · AKHQ · MinIO · Trino · Hive MS · Keycloak · admin · cmmn-api · nginx |
| observability | Elasticsearch·Kibana·Logstash·Filebeat 9.5.2 · Prometheus · Grafana · Loki · Tempo · OTel(agent·gateway) |
| API 계약 | **Apicurio Registry 3.3.2 + Registry UI**(Studio 후계 편집 기능 활성, 전역 규칙 VALIDITY=FULL·COMPATIBILITY=BACKWARD) |
| governance | DS389 3.1 · LAM 8.3 · Solr 10 · Ranger admin·usersync 2.9.0 · Knox 3.0 |
| **security** | **Falco 0.44.1(§8-64 에서 복구 · modern_ebpf) · Tetragon 1.7.1 · Trivy Operator v0.34.0 · Policy Reporter 3.10.0 · Vault 2.1.0 · Wazuh 4.14.7(manager·indexer, OpenSearch security 활성)** |
| **과금** | Istio Gateway(계량 지점) · OTel · Kafka `api-usage` · OpenMeter + ClickHouse·PostgreSQL·Redis · DLQ·격리·재처리 CronJob (§8-58~62). **가격은 없다** |
| **경보** | kube-state-metrics · Prometheus 규칙 5종 · Alertmanager → Logstash(5142) → ES `alerts` (§8-63) |
| data | Spark History · Spark Connect · Livy · ZooKeeper 3.9.5 · HDFS(NameNode·DataNode) · **HBase 2.6.6(master·regionserver) · HiveServer2 4.0.1** |
| devops | GitLab 19.3.1-ee.0 |
| 부트스트랩 | 9종 전부 Complete (hdfs-bootstrap 이 `/user/hive` 추가) |

## ★ 작업 시작 전에 — WSL keep-alive 를 먼저 띄울 것

```powershell
powershell -ExecutionPolicy Bypass -File local\keep-alive.ps1
```

WSL2 는 VM 에 붙은 프로세스가 없으면 VM 을 내린다. systemd 로 k3s 가 돌아도 마찬가지다.
매니페스트를 Windows 쪽에서 편집하는 동안 WSL 을 건드리지 않으면 VM 이 poweroff 되고,
다음 `wsl` 명령에 새로 부팅되면서 **40개 파드가 전부 재시작**한다. 노드에는 아무 압박도
남지 않아 원인이 드러나지 않는다 — 재시작 횟수만 쌓인다(§8-14).

`.wslconfig` 의 `vmIdleTimeout` 은 WSL 2.7.12 에서 무시되었다. 이 스크립트가 확실한 방법이다.

## 바로 확인하는 법

> **UI·DB 접속은 [ACCESS.md](./ACCESS.md) 에 전부 정리했다** — port-forward
> 명령·URL·계정·비밀번호 조회법, DBeaver 접속 정보, 자주 걸리는 것.
> 아래는 상태를 훑는 최소 명령만 남긴다.

```bash
wsl -d Ubuntu
cd ~/oim-infra && git fetch origin local && git merge --ff-only FETCH_HEAD
export KUBECONFIG=$HOME/.kube/config
kubectl -n local get pods

# ★ 파드 목록만 보지 말 것 — 존재하지 않는 파드는 거기 안 나온다
kubectl -n local get sts     # READY 열이 n/n 인지
```

원본 레포는 `/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev`
(편집은 원본에서, `~/oim-infra` 로 pull 해서 적용. `origin` 이 그 경로를 가리킨다)

```bash
# API 계약 — 콘솔은 SPA 라 API 도 함께 forward 해야 한다
kubectl -n local port-forward apicurio-registry-0 8080:8080
kubectl -n local port-forward deploy/apicurio-ui  8888:8080   # http://localhost:8888

# 관측
kubectl -n local port-forward deploy/grafana 3000:3000
kubectl -n local port-forward prometheus-0 9090:9090
# 거버넌스
kubectl -n local port-forward ranger-admin-0 6080:6080   # admin / ranger-secret 의 db-password
kubectl -n local port-forward deploy/lam 8080:80
# DevOps — Jenkins 는 JCasC 로 구성된다(마법사 없음). 익명 접근은 403 이다.
kubectl -n local port-forward jenkins-0 8081:8080        # admin / jenkins-secret 의 admin-password
# 오류 추적 (GlitchTip)
kubectl -n local port-forward deploy/glitchtip-web 8000:8000
# Kafka HTTP 게이트웨이 — 자체 인증이 없다(SEC-206). 외부에 열지 말 것
kubectl -n local port-forward deploy/kafka-bridge 8082:8080
# 보안
kubectl -n local port-forward vault-0 8200:8200          # root token 은 Secret vault-init
# indexer 는 TLS + 기본 인증이다. 자격증명은 Secret wazuh-secret
kubectl -n local exec wazuh-indexer-0 -c wazuh-indexer -- curl -sk \n  -u "admin:$(kubectl -n local get secret wazuh-secret -o jsonpath='{.data.indexer-admin-password}' | base64 -d)" \n  https://localhost:9200/_cat/indices?v
kubectl -n local exec wazuh-manager-0 -- /var/ossec/bin/wazuh-control status
kubectl -n trivy-system get vulnerabilityreports,configauditreports -A | head
kubectl get policyreports -A | head
```

### ★ Vault 는 재시작하면 다시 봉인된다

```bash
bash local/vault-init.sh unseal    # 최초 1회는 init
```

auto-unseal 은 KMS 를 요구하는데 로컬에 없다. `vault-0` 이 0/1 이면 대개 이것이다.

## 다음 작업

**5단계로 목표 아키텍처의 구성요소는 전부 올라갔다.** 남은 것은 결정과 마감이다.

### 0. 머지 관문 (ADR-068) — **워크로드는 끝났고 선행 조건이 남았다**

7·8단계 워크로드는 **전부 떠 있다**(2026-09-05 실측). Dependency-Track ·
DefectDojo · SafeLine · Kubescape · Caldera · 관측성 전체 · Falco 까지 기동한다.
용량 우려도 실측으로 지나갔다 — requests 92%, 파드 106.

**그러나 머지 선행 조건이 매니페스트에 반영돼 있지 않다.** 자세한 내용은
[LOCAL-DEPLOYMENT.md §9-4](../docs/LOCAL-DEPLOYMENT.md).

| 선행 조건 | 현재 |
|---|---|
| prod `targetRevision` 을 태그로 고정 | ❌ dev·prod 둘 다 `v2` |
| dev `automated` 일시 해제 | ❌ 둘 다 `prune: true`·`selfHeal: true` |
| wave 순 분할 머지 | 미착수 |

**그리고 과금 줄기가 남아 있다** — 계량은 끝났고 **가격이 없다**(§9-2).
요금제·구독·가격 없이 인보이스를 낼 수 없다. 머지 시점은 그 뒤가 맞다.

> 미뤄 둔 일 전체는 [LOCAL-DEPLOYMENT.md §9](../docs/LOCAL-DEPLOYMENT.md) 에
> 모아 두었다. **잊어서 미룬 것과 순서를 정해 미룬 것을 구분해 적었다** —
> 새 작업을 시작하기 전에 그것부터 볼 것.


### 0-2. 관측성 — 정해진 것과 남은 것 (2026-09-03)

| 역량 | 상태 |
|---|---|
| 트레이스·메트릭·로그 | ✅ OTel → Tempo·Prometheus·Loki. **앱 수신 지점은 `otel-agent:4318`** (§8-23 에서 도달 경로 복구) |
| 오류 추적 | ✅ GlitchTip. Sentry SDK 그대로 쓴다 |
| 프로파일링 | △ Pyroscope 는 섰으나 **앱 계측 수단 미결**(TODO-51) |
| 세션 리플레이 | △ **스택은 배포됨**(§8-24) — OpenReplay 17/17 · ClickHouse · 전용 PostgreSQL 17. 그러나 **데이터는 들어오지 않는다**: 외부 HTTPS 진입점 없음(블로커 #6)·프런트엔드 계측 불가(G9). ADR-069 순서 1·2 가 남았다 |

**Sentry 는 기각했다** — ADR-036 에 A안/B안 비교와 재검토 조건 3가지를 명문화했다.
요약: 이 호스트(물리 63.4 GiB)에 +22 GiB 가 들어가지 않고, 이미 채택한 OTel 경로와
중복된다. **"틀린 선택"이 아니라 "이 호스트에서 못 쓰는 선택"이다.**

**다음 한 걸음은 Ingress + TLS 다.** 세션 리플레이의 전제이면서, 그 자체로 배포
블로커 #6(외부 진입점 0개) 해소다 — GlitchTip·Grafana·Jenkins 접근이 `port-forward`
를 벗어난다. cert-manager 는 이미 설치돼 있다(Wazuh 인증서에 사용 중).
### 1. API 계약 파일 작성 (기구는 다 섰다)

`contracts/{openapi,asyncapi,schemas}/` 가 비어 있다. Spectral 린트·`publish-contracts` CI 잡·
Apicurio 전역 규칙(VALIDITY=FULL·COMPATIBILITY=BACKWARD)은 이미 동작한다. 계약 우선으로
결정했으므로(ADR-067) `cmmn-api`·`admin` 의 실제 스키마를 계약으로 옮기는 일이 남았다.

### 2. ADR-024 — Vault 를 시크릿 원천으로

Vault 는 올라가 있으나 시크릿 원천은 아직 `local/create-secrets.sh` 다. 전환하면 로테이션
CronJob 8종·git-sync·`.enc.yaml` 12개가 제거된다. **unseal 키가 같은 클러스터의 Secret 에
있다는 점을 이 결정에서 반드시 다룰 것.**

### 3. ~~dev/prod 로의 반영~~ — 완료 (§8-17·§8-18). 머지는 7단계 이후 (ADR-068)

수정 대부분이 `kubernetes/base/` 에 있어 dev·prod 가 자동 상속한다. 로컬 전용 값
(메타스토어 힙)은 `$(HIVE_HEAP)` 로 분리해 오버레이가 한 줄만 덮게 했고, `proxyuser` 는
`groups=*` → `users=hive` 로 좁혔다(SEC-211). prod 는 이미지 핀·PSS·Kyverno·PDB 모두
따로 할 일이 없었다.

**그리고 §8-18 에서 아예 분리했다.** ZooKeeper·HDFS·HBase·HiveServer2 는 매니페스트가
단일 노드를 전제하므로 base 가 아니라 `overlays/local/lakehouse-local/` 에 있다.
**dev/prod 는 이 4종을 렌더하지 않는다** — 렌더 결과로 확인했다.

base 로 승격하려면 세 가지가 필요하다:
1. TODO-49 — 실행 엔진. Tez 로컬 모드로 둘지, YARN 을 올릴지
2. TODO-48 — proxyuser 위임 범위. Knox·Ranger 경유로 대체할지
3. `hdfs-site`·`tez` 설정을 환경별로 나누는 방식 확정
   (지금은 ConfigMap 키 하나가 XML 전문이라 오버레이가 일부만 덮을 수 없다)

### 4. 남은 운영 결정

- **Reloader 미설치** — ConfigMap 을 고칠 때마다 수동 재기동한다. 구성요소가 늘어 비용이 커졌다
- **Trivy CronJob(주간)과 Trivy Operator 공존** — 제거는 dev/prod 영향이 있어 별도 결정
- **Wazuh indexer 의 `filebeat` 사용자가 `all_access`**

### 이미 정한 것 (되묻지 말 것)

- **Kerberos 미채택** — `hadoop.security.authentication=simple`
- **HA 없음** — NameNode 1 · DataNode 1 · `dfs.replication=1` · ZooKeeper 1
- **YARN 미배치** — HiveServer2 는 Tez 로컬 모드. 분산 실행은 Spark·Trino 가 맡는다 (TODO-49)
- **TODO-33 해소** — Hive warehouse 는 양자택일이 아니었다. 기본값만 정하고
  (`fs.defaultFS`=HDFS, `warehouse.dir`=S3A) 나머지는 `LOCATION` 으로 지정한다

### Hive 다중 파일시스템 재현 (§8-16)

```sql
CREATE DATABASE oim_hdfs
  LOCATION        'hdfs://hadoop-namenode:8020/warehouse/oim_hdfs.db'
  MANAGEDLOCATION 'hdfs://hadoop-namenode:8020/warehouse/oim_hdfs_managed.db';
CREATE EXTERNAL TABLE oim_hdfs.t (id INT, v STRING) STORED AS TEXTFILE;
INSERT INTO oim_hdfs.t VALUES (1, 'from-hdfs');

CREATE DATABASE oim_s3
  LOCATION        's3a://warehouse/tables/oim_s3.db'
  MANAGEDLOCATION 's3a://warehouse/tables/oim_s3_managed.db';
CREATE EXTERNAL TABLE oim_s3.t (id INT, v STRING) STORED AS TEXTFILE;
INSERT INTO oim_s3.t VALUES (1, 'from-s3a');

SELECT h.v, s.v FROM oim_hdfs.t h JOIN oim_s3.t s ON h.id = s.id;   -- from-hdfs  from-s3a
```

`beeline -u jdbc:hive2://hive-server-headless:10000/default -n hive` 로 접속한다.
**프로브 파드에는 `environment: local` 과 `app.kubernetes.io/component: data-lakehouse`
라벨이 있어야 한다** — 없으면 NetworkPolicy 가 막고 증상은 `UnknownHostException` 이다.

## 로컬 빌드 이미지 5종

```
oneinch/spark-iceberg    docker/spark-iceberg
oneinch/livy             docker/livy
oneinch/ranger-usersync  docker/ranger-usersync   # upstream Dockerfile 이식
oneinch/hbase            docker/hbase             # apache/hbase 가 Docker Hub 에 없다(404)
oneinch/jenkins          docker/jenkins           # 공식 이미지에 플러그인이 없다 (JCasC)
```

## OpenReplay 매니페스트 재생성

```bash
# 차트를 받고(최초 1회)
D=/tmp/or-tar; mkdir -p $D && cd $D
curl -fsSL -o or.tar.gz https://codeload.github.com/openreplay/openreplay/tar.gz/refs/heads/main
tar -xzf or.tar.gz --wildcards openreplay-main/scripts/helmcharts/*

# 렌더 (자원·라벨·자격증명 배선을 주입한다)
bash local/render-openreplay.sh
```

`local/build-images.sh` 가 podman 으로 빌드해 k3s containerd 로 반입한다.
**클러스터를 다시 만들면 이 스크립트를 먼저 돌려야 한다** — 레지스트리에 없어 `ImagePullBackOff` 가 난다.

## 알아둘 함정 (실제로 겪은 것)

`docs/LOCAL-DEPLOYMENT.md §8` 전체를 읽을 것. 특히:

**환경**

- **★ WSL2 는 붙은 프로세스가 없으면 VM 을 내린다.** systemd 로 k3s 가 돌아도 마찬가지다.
  40개 파드가 전부 재시작하는데 노드에는 아무 압박도 남지 않는다. `local/keep-alive.ps1`
- **컨테이너가 마운트 지점 자체에 `chmod`·`chown` 을 걸면 PVC 를 한 단계 위에 걸 것.**
  마운트 루트는 root 소유라 비특권 uid 가 바꾸지 못한다(HDFS DataNode · Wazuh)

**자원**

- **★ `limits` 를 `requests` 아래로 내리면 워크로드가 조용히 사라진다.**
  `kustomize build` 도 `kubectl apply` 도 통과한다 — StatefulSet 자체는 유효하기 때문이다.
  실패하는 것은 파드 생성이라 `get pods` 에 아무것도 안 나온다. CrashLoop 도 Pending 도 아니고 그냥 없다.
  minio 로 97분을 잃었고, 그동안 엉뚱한 것(spark-connect startup 예산)을 고치고 있었다.
  → limits 를 만지면 requests 를 먼저 보고, 적용 후 `kubectl get sts` READY 를 볼 것
- **`kubectl top` 은 '지금'이지 기동 피크가 아니다.** JVM 을 유휴 사용량 기준으로 잡으면 기동 중 OOM 이다

**capability — 이 레포에서 지금까지 5번 물렸다**

- **root 인데 `Permission denied` 면 `CAP_DAC_OVERRIDE` 를 버린 것이다**(LAM·wazuh-manager)
- **바이너리에 파일 capability 가 있으면 bounding 집합에 그것이 있어야 `execve` 가 된다**
  — 기능상 필요 없어도 그렇다(DS389 의 `ns-slapd` / `NET_BIND_SERVICE`)
- **chroot 하는 데몬은 `CAP_SYS_CHROOT` 가 필요하다**(wazuh 의 ossec 데몬 12종)
- → `drop:["ALL"]` 을 쓰기 전에 그 이미지가 root 로 무엇을 하는지 볼 것

**진단**

- **파드 로그가 조용하면 애플리케이션 자체 로그를 볼 것.** wazuh 는 `ossec.log` 에만 치명 오류를 남긴다
- **`0/1 Running` 은 "느린 것"과 "죽는 중"을 구분하지 않는다.**
  그리고 **재시작 후의 에러 메시지는 1차 실패와 다를 수 있다**(ds389)
- **되돌릴 수 없는 값을 만드는 명령은 저장을 먼저, 파싱을 나중에.** Vault unseal 키를 그렇게 잃었다

**배포**

- **`envFrom: configMapRef` 는 ConfigMap 을 바꿔도 파드를 재시작하지 않는다.** Reloader 미설치.
  ConfigMap 을 고쳤으면 파드를 직접 지울 것
- **NetworkPolicy 누락은 인증 실패처럼 보인다** — `Connection timed out` 이지 `authentication failed` 가 아니다
- **base 에 네임스페이스를 박지 말 것.** ClusterRoleBinding subject 는 `default` 로 두어야 kustomize 가 바꾼다
- **Job 의 `spec.template` 은 불변이다.** 부트스트랩 Job 을 고쳤으면 `delete` 후 `apply`
- **부트스트랩 Job 은 끝에 검증을 넣고 실패를 종료 코드로 드러낼 것.** 아니면 아무것도 안 한 Job 이 `Complete` 로 남는다
- **배포 후 기본 자격증명을 직접 찔러볼 것.** Ranger 가 비밀번호 정책에 걸린 값을 조용히 무시하고 `admin/admin` 을 남겼다
- **upstream Dockerfile 을 이식할 때 "안 쓸 것 같은 줄"을 지우지 말 것**(ranger-usersync 의 `/etc/init.d`)
- **이미지마다 uid 가 다르다.** `apache/ranger-base` 1000 / `apache/ranger` 1001
- **컨테이너 이미지의 엔트리포인트가 이미 인자를 붙이는지 볼 것**(Vault 의 `-config`)
- **`:latest` 는 메이저 스키마 변경을 그대로 가져온다**(Tempo 3.0 이 `ingester`·`compactor` 를 없앴다)
- **podman 은 short-name 을 해석하지 않는다.** `docker.io/` 를 명시할 것
- **kustomize 의 원격 git fetch 는 27초 하드 타임아웃이 있다.** 큰 저장소는 얕은 클론 후 로컬에서 읽을 것
- **★ 워크로드를 대량 추가할 때 Loki·otel-agent 한계를 먼저 올릴 것.**
  로그 파이프라인 용량은 **파드 수에 비례**한다. OpenReplay 17종을 올리자
  파드가 80 → 103 이 되며 loki(OOM 12회)·otel-agent(OOM 7회)가 먼저 죽었다.
  노드 압박이 아니라 각자의 컨테이너 한계에서 죽는다 — 그리고 그 시점에
  **진단 수단을 잃는다**
- **CrashLoop 중인 StatefulSet 은 롤링이 진행되지 않는다.** limits 를 올려도
  파드에 반영되지 않으므로 파드를 직접 지울 것
- **저장소를 재사용하려면 버전 호환성을 먼저 볼 것.** OpenReplay 는 PostgreSQL
  16.4~17 만 지원하는데 공용은 18.6 이라 쓸 수 없었다(initContainer 가 검사하고
  exit 101). 공용을 낮출 수 없으면 전용 인스턴스가 유일한 길이다
- **Helm 차트의 `global:` 아래를 덮을 것.** vars.yaml 이 YAML 앵커로 최상위를
  정의하고 global 이 별칭으로 참조하면, 최상위만 덮어도 **서브차트는 그대로**다.
  특히 initContainer 는 호스트명을 셸 스크립트에 갖고 있어 파드 env 후처리로
  고쳐지지 않는다
- **ConfigMap 안의 XML·JSON·properties 는 `kustomize build` 도 `kubeconform` 도 검사하지
  않는다.** 스키마상 그냥 문자열이라 `</property>` 하나가 남아도 apply 까지 통과하고
  워크로드가 기동할 때 파싱에서 터진다. 렌더 결과를 실제 파서에 넣어 확인할 것
  (`kustomize build | python3 -c "...ET.fromstring..."`)
- **오버레이가 못 덮는 값은 base 에 두지 말 것.** ConfigMap 은 키 하나가 파일 전문이라
  일부만 덮을 수 없다 — 덮으려면 전문을 복제해야 하고 그 순간 드리프트다.
  환경 의존 값이 XML 안에 있으면 그 워크로드는 오버레이에 두는 편이 낫다
  (`overlays/local/lakehouse-local/`)
- **`kubectl apply` 의 `configured` 는 실제 변경을 뜻하지 않는다.** 어드미션 웹훅이 매
  쓰기마다 객체를 변형하면 `last-applied` 가 어긋나 매번 `configured` 가 찍힌다.
  실제 차이는 `kubectl diff -f -` 로 볼 것(종료 코드 0 이면 차이 없음)
- **`kubectl rollout status` 는 `rollout restart` 직후 이전 리비전 기준으로 통과한다.**
  파드가 아직 Terminating 인데 "complete" 가 나온다. 확실히 기다리려면 파드의
  `controller-revision-hash` 가 STS 의 `updateRevision` 과 같은지까지 볼 것
- **`hive-site.xml` 의 `${env:...}` 는 HiveServer2 에서만 치환된다.** 독립 메타스토어는
  치환하지 않아 리터럴이 그대로 자격증명이 되고 **403 으로 돌아온다**(권한 오류처럼 보인다).
  → 값이 아니라 공급자로 넘길 것(`fs.s3a.aws.credentials.provider`)
- **`fs.s3a.impl` 을 적어 두어도 클래스가 클래스패스에 없으면 무의미하다.**
  `hadoop-aws` 는 `share/hadoop/tools/lib` 에 있고 이 경로는 기본 클래스패스가 아니다
- **컨테이너 `limit` 을 줄일 때 그 안 JVM 의 `-Xmx` 를 같이 볼 것.**
  hive-metastore 가 limit 512Mi / 힙 1G 로 재시작 39회를 쌓고 있었다.
  Guaranteed QoS 는 스왑도 못 쓰므로 여유가 없다
- **엔트리포인트가 인자를 덧붙이는 방식이면 "뒤에 온 값이 이긴다"를 이용할 것**
  (`HADOOP_CLIENT_OPTS="-Xmx1G $SERVICE_OPTS"` → `SERVICE_OPTS` 에 `-Xmx768m`).
  같은 이미지에서 `java -Xmx1G -Xmx768m -XX:+PrintFlagsFinal -version` 으로 확인 가능하다
- **오버레이가 덮을 값은 처음부터 별도 env 키로 뺄 것.** 한 문자열에 접속 정보와 튜닝이
  섞여 있으면 오버레이가 전체를 복제하게 되고 그때부터 드리프트다. `$(KEY)` 는 k8s 가
  파드 생성 시 펼쳐 주고, `env` 는 `name` 키 병합이라 패치가 그 항목만 덮는다

## 정리해 두면 좋을 것

```bash
sudo rm /etc/sudoers.d/99-oim-local   # NOPASSWD 되돌리기
passwd                                 # 이 프로젝트 대화에 평문으로 남은 비밀번호 변경
```

- **Reloader 미설치** — 단계가 늘수록 수동 재기동 비용이 커진다. 설치할 만하다
- **Wazuh indexer 의 `filebeat` 사용자가 `all_access` 다.** `wazuh-alerts-*` 쓰기만 허용하는
  역할로 좁히는 것은 별도 작업이다(indexer security 자체는 켜져 있다)
- **Vault unseal 키가 같은 클러스터의 Secret 에 있다.** ADR-024 때 반드시 재논의할 것
- **Trivy CronJob(주간)과 Trivy Operator 가 공존한다.** 제거는 dev/prod 영향이 있어 별도 결정
- **Ranger admin 은 재시작마다 setup 을 다시 돈다**(`.setupDone` 이 이미지 본체에 있다). 2~3분 걸린다
- `v1/cmmn-api/` 에 평문 DB 비밀번호가 커밋되어 있다(git 히스토리에도 남음)
