# 다음 세션 인수인계

> 브랜치 `local` · 최종 갱신 2026-09-01 (2단계 완료)

## 지금 상태

```
30 Running(전부 1/1 Ready) · 5 Completed · 미해결 0
requests  메모리 51% (23.6/45 GiB)   CPU 68% (13.35/19.5)
zram      32G 중 81M 사용
```

WSL2 단일 노드 k3s 에 **`[구현됨]` 매니페스트 전체 + 1·2단계 관측 스택**이 떠 있다.

| 계층 | 상태 |
|---|---|
| 플랫폼 | Cilium 1.16.5(M1·M2 적용) · Istio ambient · Gateway API · ECK 3.2.0 · Kyverno · cert-manager |
| core | PostgreSQL·MariaDB·MongoDB·Redis(공식 이미지) · Kafka · Apicurio · AKHQ · MinIO · Trino · Hive MS · Keycloak · admin · cmmn-api · nginx |
| observability | Elasticsearch·Kibana·Logstash·Filebeat **9.5.2** · Prometheus · Grafana · **Loki · Tempo · OTel(agent·gateway)** |
| data | Spark History · Spark Connect · Livy |
| devops | GitLab 19.3.1-ee.0 |
| 부트스트랩 | 6종 전부 Complete |

## 바로 확인하는 법

```bash
wsl -d Ubuntu
cd ~/oim-infra && git fetch origin local && git merge --ff-only FETCH_HEAD
export KUBECONFIG=$HOME/.kube/config
kubectl -n local get pods
```

원본 레포는 `/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev`
(편집은 원본에서, `~/oim-infra` 로 pull 해서 적용하는 흐름. `origin` 이 그 경로를 가리킨다)

관측 스택 확인:

```bash
kubectl -n local port-forward deploy/grafana 3000:3000   # 데이터소스 4종
kubectl -n local port-forward loki-0 3100:3100           # /loki/api/v1/labels
kubectl -n local port-forward tempo-0 3200:3200          # /api/search?q=...
kubectl -n local port-forward prometheus-0 9090:9090     # up == 16
```

## 다음 작업 — 3단계(governance)

`docs/LOCAL-DEPLOYMENT.md §8-10` 에 단계 계획과 1·2단계 실측 결과가 있다.
3단계는 **DS389 · LAM · Solr · Ranger(admin·usersync) · Knox**, 신규 매니페스트 ~25.

### ★ 착수 전에 할 것

1. **`C:\Users\darka\.wslconfig` 의 `processors=20` → 24**, 그다음 `wsl --shutdown`
   (클러스터가 내려간다. 3단계 직전이 적기다. kubelet 예약 250m 인하는 이미 적용 — Allocatable 19.5)
2. **`postgres-bootstrap` 에 `ranger` DB·롤 추가** — Ranger 가 선행 의존한다
3. 신규 서비스 `requests.cpu` 를 50~100m 로 억제 (2단계 4종 합계 350m 로 끝냈다)

### 버전 — v1 기재와 다르다. 반드시 확인할 것

- **Knox 는 로컬 빌드 불필요** — `apache/knox:2.1.0` 공식 이미지가 있다. TODO-37 축소
- Ranger `2.7.0 → 2.9.0`, usersync 는 `eclipse-temurin:17-jdk`
- Solr 는 `apache/solr` 가 아니라 **`solr:10.0.0-slim`**(`library/solr`)
- DS389 3.1 · LAM 8.3

### 5단계(lakehouse-v1)는 설계 선행

- TODO-33 — Hive warehouse 를 HDFS 로 되돌릴지 S3A 유지할지 미결
- Kerberos 채택 여부 — 현재 `hadoop.security.authentication = simple`
- `hbase:2.6.3` 로컬 빌드 경로(TODO-37)

## 알아둘 함정 (실제로 겪은 것)

`docs/LOCAL-DEPLOYMENT.md §8` 전체를 읽을 것. 특히:

- **`envFrom: configMapRef` 는 ConfigMap 을 바꿔도 파드를 재시작하지 않는다.** Reloader 가 미설치라 어노테이션이 작동하지 않는다. **ConfigMap 을 고쳤으면 파드를 직접 지울 것**
- **NetworkPolicy 누락은 인증 실패처럼 보인다** — `Connection timed out` 이지 `authentication failed` 가 아니다
- **base 에 네임스페이스를 박지 말 것.** ClusterRoleBinding subject 는 `default` 로 두어야 kustomize 가 오버레이 값으로 바꾼다. 실제 값을 박으면 다른 오버레이에서 **에러 없이** 바인딩이 빗나간다
- **liveness 에 무거운 CLI 를 쓰지 말 것.** mongodb 가 `mongosh`(Node.js) 로 9회 재시작했다. liveness 는 tcpSocket, 무거운 검사는 readiness 로
- **`:latest` 는 메이저 스키마 변경을 그대로 가져온다.** Tempo 3.0 이 `ingester`·`compactor` 를 없앴다. prod 는 핀되어 있으나 로컬은 아니다
- **`0/1 Running` 은 "느린 것"과 "죽는 중"을 구분하지 않는다.** livy 는 startup probe 가 91회 실패하는 동안 사실 매번 예외로 죽고 있었다. 로그를 볼 것
- **컬렉터가 백엔드보다 먼저 뜨면 `no such host`·`no children to pick from` 이 뜬다.** 재시도로 회복한다. 30초는 기다리고 판단할 것
- **`kubectl apply --server-side` 가 CR 의 `spec.version` 을 갱신하지 못하는 경우가 있다**(ECK). 직접 patch 하거나 CR 을 재생성해야 한다
- **ECK 는 다운그레이드를 거부한다.** 존재하지 않는 버전을 CR 에 쓰면 되돌리기가 비싸다
- **로컬 빌드 이미지는 핀 태그를 containerd 에 함께 반입**해야 한다(`k3s ctr images tag`)

## 정리해 두면 좋을 것

```bash
sudo rm /etc/sudoers.d/99-oim-local   # NOPASSWD 되돌리기
passwd                                 # 이 프로젝트 대화에 평문으로 남은 비밀번호 변경
```

- **Reloader 미설치** — 전 워크로드에 `reloader.stakater.com/auto` 어노테이션이 있으나 작동하지 않는다. 설치하면 ConfigMap/Secret 변경이 자동 반영된다. **단계가 늘수록 수동 재기동 비용이 커진다 — 3단계 전에 설치할 만하다**
- `v1/cmmn-api/` 에 평문 DB 비밀번호가 커밋되어 있다(git 히스토리에도 남음)
