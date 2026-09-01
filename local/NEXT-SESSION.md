# 다음 세션 인수인계

> 브랜치 `local` · 최종 갱신 2026-09-01

## 지금 상태

```
26 Running · 5 Completed · 미해결 0
```

WSL2 단일 노드 k3s 에 **`[구현됨]` 매니페스트 전체 + Prometheus·Grafana** 가 떠 있다.

| 계층 | 상태 |
|---|---|
| 플랫폼 | Cilium 1.16.5(M1·M2 적용) · Istio ambient · Gateway API · ECK 3.2.0 · Kyverno · cert-manager |
| core | PostgreSQL·MariaDB·MongoDB·Redis(공식 이미지) · Kafka · Apicurio · AKHQ · MinIO · Trino · Hive MS · Keycloak · admin · cmmn-api · nginx |
| observability | Elasticsearch·Kibana·Logstash·Filebeat **9.5.2** · **Prometheus · Grafana** |
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
(편집은 원본에서, `~/oim-infra` 로 pull 해서 적용하는 흐름)

## 다음 작업 — 2단계부터

`docs/LOCAL-DEPLOYMENT.md §8-10` 에 단계 계획이 있다. 2단계는 **Loki · Tempo · OTel(agent·gateway)**.

### ★ 착수 전에 반드시 할 것 — CPU 제약 해소

```
현재 requests: 메모리 46% · CPU 66% (12.7/19)
```

**남은 ~130종을 올리면 CPU requests 에서 스케줄이 먼저 실패한다.** 메모리(zram 포함)는 여유가 있으나 CPU 는 아니다.

1. `C:\Users\darka\.wslconfig` 의 `processors=20` → **24**, 그다음 `wsl --shutdown`
2. `local/kubelet-config.yaml` 의 `systemReserved.cpu`·`kubeReserved.cpu` 500m → **250m**
   → k3s 재설치가 아니라 `/etc/rancher/k3s/kubelet-config.yaml` 갱신 후 `sudo systemctl restart k3s`
3. 신규 서비스 `requests.cpu` 를 50~100m 로 억제

### 3단계(governance) 착수 시 반영할 것

`docs/LOCAL-DEPLOYMENT.md §8-10` 의 버전 표 참조. 요점:

- **Knox 는 로컬 빌드 불필요** — `apache/knox:2.1.0` 공식 이미지가 있다. TODO-37 축소
- Ranger `2.7.0 → 2.9.0`, usersync 는 `eclipse-temurin:17-jdk`
- Solr 는 `apache/solr` 가 아니라 **`solr:10.0.0-slim`**(`library/solr`)
- `postgres-bootstrap` 에 **`ranger` DB·롤 추가**가 선행

### 5단계(lakehouse-v1)는 설계 선행

- TODO-33 — Hive warehouse 를 HDFS 로 되돌릴지 S3A 유지할지 미결
- Kerberos 채택 여부 — 현재 `hadoop.security.authentication = simple`
- `hbase:2.6.3` 로컬 빌드 경로(TODO-37)

## 알아둘 함정 (이번 세션에서 실제로 겪은 것)

`docs/LOCAL-DEPLOYMENT.md §8` 전체를 읽을 것. 특히:

- **`envFrom: configMapRef` 는 ConfigMap 을 바꿔도 파드를 재시작하지 않는다.** Reloader 가 미설치라 어노테이션이 작동하지 않는다. GitLab 건에서 두 번 헛돌았다
- **NetworkPolicy 누락은 인증 실패처럼 보인다** — `Connection timed out` 이지 `authentication failed` 가 아니다
- **`kubectl apply --server-side` 가 CR 의 `spec.version` 을 갱신하지 못하는 경우가 있다**(ECK). 직접 patch 하거나 CR 을 재생성해야 한다
- **ECK 는 다운그레이드를 거부한다.** 존재하지 않는 버전을 CR 에 쓰면 되돌리기가 비싸다
- **로컬 빌드 이미지는 핀 태그를 containerd 에 함께 반입**해야 한다(`k3s ctr images tag`)
- 파드 스펙 변경 후 **기존 파드를 지워야** 새 스펙으로 뜬다

## 정리해 두면 좋을 것

```bash
sudo rm /etc/sudoers.d/99-oim-local   # NOPASSWD 되돌리기
passwd                                 # 이 프로젝트 대화에 평문으로 남은 비밀번호 변경
```

- **Reloader 미설치** — 전 워크로드에 `reloader.stakater.com/auto` 어노테이션이 있으나 작동하지 않는다. 설치하면 ConfigMap/Secret 변경이 자동 반영된다
- `v1/cmmn-api/` 에 평문 DB 비밀번호가 커밋되어 있다(git 히스토리에도 남음)
