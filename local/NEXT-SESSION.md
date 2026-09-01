# 다음 세션 인수인계

> 브랜치 `local` · 최종 갱신 2026-09-01 (3단계 완료)

## 지금 상태

```
35 Running(전부 1/1 Ready) · 6 Completed · 미해결 0
requests  메모리 56% (26.0/45 GiB)   CPU 71% (13.9/19.5)
limits    메모리 96%  ← 4단계 착수 전에 볼 것
```

WSL2 단일 노드 k3s 에 **`[구현됨]` 매니페스트 전체 + 1~3단계**가 떠 있다.

| 계층 | 상태 |
|---|---|
| 플랫폼 | Cilium 1.16.5(M1·M2 적용) · Istio ambient · Gateway API · ECK 3.2.0 · Kyverno · cert-manager |
| core | PostgreSQL·MariaDB·MongoDB·Redis(공식 이미지) · Kafka · Apicurio · AKHQ · MinIO · Trino · Hive MS · Keycloak · admin · cmmn-api · nginx |
| observability | Elasticsearch·Kibana·Logstash·Filebeat **9.5.2** · Prometheus · Grafana · Loki · Tempo · OTel(agent·gateway) |
| **governance** | **DS389 3.1 · LAM 8.3 · Solr 10 · Ranger admin 2.9.0 · Knox 3.0** |
| data | Spark History · Spark Connect · Livy |
| devops | GitLab 19.3.1-ee.0 |
| 부트스트랩 | 7종 전부 Complete (ds389-bootstrap 추가) |

## 바로 확인하는 법

```bash
wsl -d Ubuntu
cd ~/oim-infra && git fetch origin local && git merge --ff-only FETCH_HEAD
export KUBECONFIG=$HOME/.kube/config
kubectl -n local get pods
```

원본 레포는 `/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev`
(편집은 원본에서, `~/oim-infra` 로 pull 해서 적용. `origin` 이 그 경로를 가리킨다)

```bash
# 관측
kubectl -n local port-forward deploy/grafana 3000:3000    # 데이터소스 4종
kubectl -n local port-forward prometheus-0 9090:9090      # up == 16
# 거버넌스
kubectl -n local port-forward ranger-admin-0 6080:6080    # admin / ranger-secret 의 db-password
kubectl -n local port-forward deploy/lam 8080:80          # /lam/
kubectl -n local port-forward deploy/knox 8443:8443       # /gateway/homepage/home/
kubectl -n local exec ds389-0 -- ldapsearch -x -LLL -H ldap://localhost:3389 \
  -D "cn=Directory Manager" -w "$(kubectl -n local get secret ds389-secret -o jsonpath='{.data.dm-password}' | base64 -d)" \
  -b "dc=oneinchmarket,dc=co,dc=kr" -s sub dn
```

## 다음 작업 — 4단계(security-min)

`docs/LOCAL-DEPLOYMENT.md §8-10` 에 단계 계획이, §8-11 에 3단계 실측 결과가 있다.
4단계는 **Tetragon · Trivy Operator · Policy Reporter · Vault · Wazuh 2종**, 신규 매니페스트 ~20.

### ★ 착수 전에 볼 것

1. **메모리 limits 가 96% 다.** requests(56%)는 여유가 있으나 limits 합이 노드 용량에 닿았다.
   새 워크로드의 limits 를 보수적으로 잡거나 기존 워크로드(특히 GitLab·Trino·Elasticsearch)의
   limits 를 재검토할 것
2. **`C:\Users\darka\.wslconfig` 의 `processors=20` → 24** (`wsl --shutdown` 필요, 클러스터가 내려간다).
   3단계는 CPU 71% 로 넘겼다. 4단계에서 막히면 그때 할 것
3. **Vault 는 ADR-024 와 맞물린다** — 채택하면 로테이션 CronJob 8종·git-sync·`.enc.yaml` 12개가
   제거된다. 4단계에서 Vault 를 올리기 전에 그 결정을 먼저 할 것

### 3단계에서 미룬 것 — ranger-usersync

공식 이미지가 없다. `apache/ranger:2.9.0` 은 admin 배포물만 담고 있고 Docker Hub 에
`apache/ranger-usersync` 저장소가 없다. 남은 길:

1. **로컬 빌드** — `downloads.apache.org/ranger/2.9.0/services/usersync/` tarball 로 이미지 생성(TODO-37 성격)
2. ~~런타임 다운로드~~ — v1 방식. 폐쇄망에서 깨지고 재현성이 없다. 채택하지 않는다

현재 Ranger admin 은 `authentication_method=UNIX`(이미지 기본값)다. DS389 연동은 usersync
또는 Ranger admin 의 LDAP 인증 전환으로 별도 진행한다.

## 알아둘 함정 (실제로 겪은 것)

`docs/LOCAL-DEPLOYMENT.md §8` 전체를 읽을 것. 특히:

- **`drop:["ALL"]` 전에 그 이미지 바이너리의 파일 capability 를 확인할 것.**
  `ns-slapd` 는 `cap_net_bind_service` 를 파일 capability 로 갖는다. 파일의 permitted 집합이
  프로세스 bounding 집합의 부분집합이 아니면 커널이 `execve` 를 EPERM 으로 거부한다 —
  기능상 그 권한이 필요 없어도 그렇다. 이것 하나로 오진을 두 번 했다
- **root 인데 `Permission denied` 면 `CAP_DAC_OVERRIDE` 를 버린 것이다.**
  root 가 파일 권한을 무시하는 것은 그 capability 가 하는 일이다
- **`0/1 Running` 은 "느린 것"과 "죽는 중"을 구분하지 않는다.** 로그를 볼 것.
  그리고 **재시작 후의 에러 메시지는 1차 실패와 다를 수 있다** — ds389 는 1차에 EPERM 으로
  죽으면서 파일을 남겨 2차부터 "instance already exists" 로 바뀌었다
- **부트스트랩 Job 은 끝에 검증을 넣고 검증 실패를 종료 코드로 드러낼 것.**
  `set -e` 없이 마지막이 `echo` 면, 아무것도 못 한 Job 이 `Complete` 로 남는다
- **배포 후 기본 자격증명을 직접 찔러볼 것.** Ranger 는 비밀번호 정책에 걸린 값을 조용히
  무시하고 `admin/admin` 을 남겼다. 실패도 경고도 없었다
- **emptyDir 는 이미지의 내용물을 가린다.** LAM 설정 디렉터리에 걸었다가 템플릿이 사라졌다
- **`envFrom: configMapRef` 는 ConfigMap 을 바꿔도 파드를 재시작하지 않는다.**
  Reloader 미설치라 어노테이션이 작동하지 않는다. **ConfigMap 을 고쳤으면 파드를 직접 지울 것**
- **NetworkPolicy 누락은 인증 실패처럼 보인다** — `Connection timed out` 이지
  `authentication failed` 가 아니다
- **base 에 네임스페이스를 박지 말 것.** ClusterRoleBinding subject 는 `default` 로 두어야
  kustomize 가 오버레이 값으로 바꾼다
- **liveness 에 무거운 CLI 를 쓰지 말 것.** mongodb 가 `mongosh`(Node.js)로 9회 재시작했다
- **`:latest` 는 메이저 스키마 변경을 그대로 가져온다.** Tempo 3.0 이 `ingester`·`compactor` 를 없앴다
- **LDIF 는 공백으로 시작하는 줄을 앞줄의 이어붙임으로 해석한다.** YAML 안에서 쓸 때 들여쓰기를 벗길 것
- **`kubectl apply --server-side` 가 CR 의 `spec.version` 을 갱신하지 못하는 경우가 있다**(ECK)
- **ECK 는 다운그레이드를 거부한다**
- **Job 의 `spec.template` 은 불변이다.** 부트스트랩 Job 을 고쳤으면 `delete` 후 `apply`

## 정리해 두면 좋을 것

```bash
sudo rm /etc/sudoers.d/99-oim-local   # NOPASSWD 되돌리기
passwd                                 # 이 프로젝트 대화에 평문으로 남은 비밀번호 변경
```

- **Reloader 미설치** — 전 워크로드에 `reloader.stakater.com/auto` 어노테이션이 있으나 작동하지
  않는다. 단계가 늘수록 수동 재기동 비용이 커진다 — **4단계 전에 설치할 만하다**
- **Ranger admin 은 재시작마다 setup 을 다시 돈다.** `.setupDone` 이 `RANGER_HOME=/opt/ranger`
  (이미지 본체)에 있어 PVC 로 덮을 수 없다. 안전하지만 재시작이 2~3분 걸린다
- **Knox 는 매 기동 자체 서명 인증서를 새로 만든다.** 앞단에 Gateway/Ingress 를 둘 때
  `KNOX_CERT`·`KNOX_KEY` 로 실 인증서를 주입할 것
- `v1/cmmn-api/` 에 평문 DB 비밀번호가 커밋되어 있다(git 히스토리에도 남음)
