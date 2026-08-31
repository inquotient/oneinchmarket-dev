# PRD — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> 표기 규칙은 [ARCHITECTURE.md](./ARCHITECTURE.md) 서두와 동일하다.
>
> **이 문서는 인프라 플랫폼 자체를 제품으로 본다.** 사용자는 이 플랫폼 위에서 개발·운영하는 팀이다.

---

## 목차

1. [배경](#1-배경)
2. [제품 정의](#2-제품-정의)
3. [목표 · 비목표](#3-목표--비목표)
4. [이해관계자](#4-이해관계자)
5. [요구사항](#5-요구사항)
6. [서비스 카탈로그](#6-서비스-카탈로그)
7. [비기능 요구사항](#7-비기능-요구사항)
8. [Phase 달성도](#8-phase-달성도)
9. [미결정 사항](#9-미결정-사항)
10. [성공 기준](#10-성공-기준)

---

## 1. 배경

### 1-1. v1의 상태

v1은 **`kind` 기반 로컬 개발 환경**이었다 (`v1/cluster/cluster-config.yaml`). 계획서(`v2-architecture-plan.md` §2) 진단:

| 심각도 | 문제 | 영향 범위 |
|---|---|---|
| Critical | ConfigMap에 평문 비밀번호 | 13개 서비스 |
| Critical | root로 실행되는 컨테이너 | 20+ 컨테이너 |
| Critical | 특권 컨테이너 | 3개 |
| Critical | NetworkPolicy 없음 | 전체 클러스터 |
| High | 리소스 제한 없음 | 35+ 컨테이너 |
| High | Health Probe 없음 | 35/38 서비스 |
| High | `:latest` 이미지 태그 | 24개 |
| High | 단일 레플리카 SPOF | 26개 서비스 |
| High | NodePort 남용 | 30개 서비스 |

이 분석에서 **문제 2건을 추가로 확인**했다.

- `v1/cluster/tls.key` — **RSA 개인키가 git에 커밋되어 있다** (SEC-401)
- `v1/ranger/admin/ranger-admin-configmap.yaml:6` — 평문 DB 비밀번호 (SEC-402)

### 1-2. v2의 방향

계획서 §1 전환표 기준.

| 영역 | v1 | v2 |
|---|---|---|
| 데이터 플랫폼 | Hadoop HDFS + HBase + Hive | MinIO + Trino + Iceberg |
| 메시지 코디네이션 | ZooKeeper | Kafka KRaft |
| K8s 매니페스트 | Raw YAML | Kustomize (base + overlay) |
| 배포 | 수동 | ArgoCD GitOps |
| Service Mesh | 없음 | Istio Ambient |
| Secret 관리 | ConfigMap 평문 | SOPS + age |
| 컨테이너 보안 | 없음 | Trivy + Cosign + Kyverno + Falco |
| IaC | 없음 | OpenTofu |
| 실행 환경 | kind (로컬) | k3s (클라우드) |

### 1-3. 이후 확장 결정

| 결정 | 내용 | ADR |
|---|---|---|
| **v1 스택 복원** | `schema-reg`·`kafka-ui`를 제외한 v1 전용 구성요소 전부 복원 (37 파드) | ADR-022 |
| **프로바이더 단일화** | Vultr 단독, Hetzner 제거, IaC 평탄화 | ADR-019 |
| **로컬 타깃 추가** | Hyper-V + k3s (v1 kind 대체) | ADR-051 |
| **보안 스택 확장** | OPNsense·Suricata·Zeek·SafeLine·Cilium·Tetragon·Kubescape·Vault·Wazuh·Caldera | ADR-023~030 |
| **관측성 재편** | OpenTelemetry 중심 + Prometheus·Grafana·Loki·Tempo·Jaeger·Sentry | ADR-039~042 |
| **공급망 완결** | Trivy Operator·Dependency-Track·DefectDojo·Policy Reporter·Gitleaks·Checkov·Syft | ADR-046~050 |
| **메시징 라이선스 정합** | Confluent REST Proxy → Strimzi Kafka Bridge | ADR-032 |

---

## 2. 제품 정의

**보안 관제가 내장된 데이터 레이크하우스 플랫폼.**

세 계층을 하나의 GitOps 파이프라인으로 제공한다.

1. **데이터 플랫폼** — 오브젝트 스토리지(MinIO) 위의 Iceberg 테이블을 Trino로 질의하고, Kafka로 이벤트를 수집한다
2. **애플리케이션 런타임** — 데이터베이스 4종, 인증(Keycloak), 애플리케이션 3종
3. **보안·관측 관제** — 어드미션·네트워크·런타임·공급망 통제와 관측 도메인 6종

**핵심 설계 원칙**: 오픈소스만으로 구성하고, 상용 제품 대비 격차는 명시적으로 기록한다 (SECURITY.md §7).

---

## 3. 목표 · 비목표

### 3-1. 목표

| # | 목표 | 측정 |
|---|---|---|
| G-1 | 신규 클러스터를 코드만으로 재구성할 수 있다 | `tofu apply` → `bootstrap` → ArgoCD sync 로 전체 복구 |
| G-2 | 로컬 워크스테이션에서 플랫폼을 검증할 수 있다 | Hyper-V 128 GB 호스트에서 전 구성요소 기동 |
| G-3 | 보안 통제가 코드로 강제된다 | SEC-xxx 68건 중 미충족 0 |
| G-4 | 배포가 Git 상태와 일치한다 | ArgoCD drift 0 |
| G-5 | 자격증명이 코드베이스에 평문으로 존재하지 않는다 | Gitleaks 게이트 통과 |
| G-6 | 취약점·정책 위반을 단일 지점에서 조회한다 | DefectDojo + Policy Reporter |
| G-7 | 애플리케이션 계측이 백엔드에 종속되지 않는다 | OTLP 단일 계측 |
| G-8 | 운영 비용을 예측·통제할 수 있다 | 노드 수·단가 산정 근거 문서화 |

### 3-2. 비목표

| # | 비목표 | 사유 |
|---|---|---|
| N-1 | 멀티 클라우드 이식성 | 추상화가 이동을 쉽게 만들지 않는다는 것이 이 레포의 실증 사례다 (ADR-011 Superseded) |
| N-2 | 멀티 리전 · 지리적 이중화 | 현재 범위 밖 |
| N-3 | 상용 CNAPP 기능 완전 대체 | DTA·드리프트 방지·CSPM은 OSS 동등물이 없다 (SECURITY.md §7) |
| N-4 | 로컬 환경에서의 성능 측정 | Hyper-V 합성 NIC에서 Cilium XDP 미지원 (H5) |
| N-5 | 애플리케이션 소스 코드 관리 | 이 레포는 인프라 전용. 단 CI가 `v1/`의 Dockerfile을 참조하는 모순이 있다 (G9 · TODO-23) |

---

## 4. 이해관계자

| 역할 | 관심사 | 주 사용 문서 |
|---|---|---|
| 플랫폼 엔지니어 | 클러스터 부트스트랩, IaC, 용량·비용 | DEPLOYMENT.md |
| 보안 엔지니어 | 통제 커버리지, 취약점 트리아지, 컴플라이언스 | SECURITY.md |
| 데이터 엔지니어 | 레이크하우스 질의 경로, Kafka 토픽, 거버넌스 | ARCHITECTURE.md §5, COMPONENTS.md |
| 애플리케이션 개발자 | 계측, 오류 추적, 로컬 환경 | COMPONENTS.md §8, DEPLOYMENT.md §4 |
| 운영/SRE | 관측 도메인, 알림, 장애 대응 | ARCHITECTURE.md §4 |

---

## 5. 요구사항

### 5-1. 기능 요구사항 — 현재 구현됨

| # | 요구사항 | 근거 |
|---|---|---|
| FR-01 | Kustomize base + 환경별 오버레이로 매니페스트를 관리한다 | `kubectl kustomize` 빌드 성공 (dev 5,427줄 / prod 5,569줄) |
| FR-02 | ArgoCD가 Git 상태를 클러스터에 동기화한다 | `argocd/applications/` 2건, sync-wave 0→8 |
| FR-03 | 오브젝트 스토리지 위의 Iceberg 테이블을 SQL로 질의한다 | Trino `iceberg`·`hive` 카탈로그 → Hive MS → MinIO |
| FR-04 | Kafka KRaft로 이벤트를 수집한다 | ZooKeeper 의존 없음 |
| FR-05 | Keycloak으로 인증을 중앙화한다 | PostgreSQL + Redis 백엔드 |
| FR-06 | Kyverno로 배포 시 정책을 강제한다 | 6정책, prod에서 4종 Enforce |
| FR-07 | 기본 거부 네트워크 정책을 적용한다 | `default-deny-ingress` + allow 13종 |
| FR-08 | 런타임 위협을 탐지하고 알림을 라우팅한다 | Falco → Falcosidekick → ES·Kafka·Slack |
| FR-09 | CI에서 이미지·매니페스트 취약점을 차단한다 | Trivy 3잡, `allow_failure: false` |
| FR-10 | 자체 빌드 이미지를 서명한다 | Cosign, Trivy 통과 후 |
| FR-11 | OpenTofu로 인프라를 프로비저닝한다 | Vultr bastion/master/worker 3-tier + VPC + 방화벽 |
| FR-12 | VPN을 경유해서만 클러스터에 접근한다 | WireGuard bastion, 공인 IP deny-all |
| FR-13 | 보안 상태를 스크립트로 검증한다 | 9종 + `run-all.sh` |

### 5-2. 기능 요구사항 — 목표 (미구현)

| # | 요구사항 | 연결 |
|---|---|---|
| FR-21 | 외부에서 서비스에 HTTPS로 접근한다 | TODO-01·02 |
| FR-22 | 시크릿이 배포되고 자동 로테이션된다 — **현재 Secret 0개 렌더** | G2 · ADR-024 |
| FR-23 | 데이터베이스·버킷·토픽이 자동 초기화된다 | G22 |
| FR-24 | 브로커 노출 없이 HTTP로 Kafka에 접근한다 | ADR-032·035 |
| FR-25 | 워크로드 간 통신이 mTLS로 암호화된다 — 현재 PERMISSIVE, dev 비활성 | G6 |
| FR-26 | 메시 미가입 워크로드까지 정책이 적용된다 | ADR-023 |
| FR-27 | 남-북 트래픽에 IPS·WAF를 적용한다 | ADR-028·029 |
| FR-28 | 런타임 위협을 탐지하고 **차단**한다 | ADR-025 |
| FR-29 | 메트릭을 수집하고 대시보드로 조회한다 | INFRA-601 |
| FR-30 | 애플리케이션 트레이스를 수집·상관 조회한다 | ADR-039~041 |
| FR-31 | 애플리케이션 오류를 이슈 단위로 추적한다 | ADR-036 |
| FR-32 | 보안 이벤트를 SIEM에서 상관분석한다 | ADR-026 |
| FR-33 | SBOM을 생성·보관하고 신규 CVE를 소급 알림한다 | ADR-050 |
| FR-34 | 취약점을 단일 지점에서 트리아지한다 | ADR-048 |
| FR-35 | 서명되지 않은 이미지의 배포를 차단한다 | G10 |
| FR-36 | 데이터 접근을 테이블·컬럼 수준으로 통제한다 | ADR-022 (Ranger) |
| FR-37 | 로컬 워크스테이션에서 플랫폼을 검증한다 | ADR-051 |
| FR-38 | 검증 대상별로 스택 일부만 배포한다 | ADR-054 |
| FR-39 | 적대적 시뮬레이션으로 탐지 유효성을 검증한다 | ADR-030 |
| FR-40 | 백업에서 데이터를 복원한다 — **DR 전무** | INFRA-504 |

---

## 6. 서비스 카탈로그

각 서비스의 존재 이유. 상세는 [COMPONENTS.md](./COMPONENTS.md).

| 서비스 | 존재 이유 |
|---|---|
| **MinIO** | 레이크하우스 오브젝트 스토리지. HDFS 대체. Tempo·Loki 백엔드 겸용 |
| **Trino** | 분산 SQL 질의 엔진. Hive Server 대체 |
| **Hive Metastore** | Iceberg 카탈로그. v1에서 승계하되 warehouse를 S3A로 전환 |
| **Kafka** | 이벤트 백본. KRaft로 ZooKeeper 제거 |
| **Kafka Bridge** | **브로커를 직접 노출하지 않고** HTTP 단일 지점으로 외부 접근 수용 |
| **Apicurio Registry** | 스키마 레지스트리. Confluent 대체 |
| **AKHQ** | Kafka 운영 UI |
| **PostgreSQL** | Keycloak·GitLab·Apicurio·Hive MS·Ranger 메타데이터 |
| **MariaDB** | cmmn-api 업무 데이터 |
| **MongoDB** | **현재 소비자가 확인되지 않음** — 존치 여부 재검토 필요 |
| **Redis** | 세션·캐시. GitLab·cmmn-api |
| **Keycloak** | 중앙 인증. OIDC 제공자 |
| **GitLab EE** | 소스·CI·레지스트리 |
| **admin / cmmn-api / nginx** | 애플리케이션 계층 |
| **Elasticsearch + Kibana** | 운영 로그 장기 보존·전문 검색 |
| **Logstash** | **보안 이벤트 정규화·라우팅** (역할 재정의) |
| **Filebeat** | 호스트·인프라 로그 수집 |
| **Falco / Tetragon** | 런타임 위협 탐지 (Tetragon은 차단도) |
| **Wazuh** | SIEM·HIDS·컴플라이언스 |
| **Prometheus + Grafana** | 메트릭·통합 대시보드 |
| **Loki / Tempo / Jaeger** | 단기 로그 / 장기 트레이스 / 단기 트레이스 |
| **OTel Collector** | 계측과 백엔드의 분리 지점 |
| **Cilium + Hubble** | CNI·정책·플로우 관측. 클러스터 전체 |
| **Istio Ambient** | 워크로드 ID 기반 mTLS·L7 인가. 메시 가입 NS |
| **Kyverno / Kubescape** | 어드미션 강제 / 포스처 점검 |
| **Trivy + Cosign + Syft** | CVE 스캔 / 서명 / SBOM |
| **Dependency-Track / DefectDojo / Policy Reporter** | SBOM 추적 / 취약점 트리아지 / 정책 리포트 |
| **Vault** | 동적 자격증명. SOPS+age 대체 |
| **OPNsense + Suricata + Zeek** | 경계 방화벽 · IPS · 프로토콜 분석 |
| **SafeLine WAF** | L7 애플리케이션 방어 |
| **Caldera** | 탐지 스택 유효성 검증 (dev/local 전용) |
| **Hadoop · HBase · Hive Server** `[복원]` | v1 데이터 플랫폼 |
| **Ranger + Solr + Knox** `[복원]` | 데이터 접근 통제·감사·게이트웨이. **Ranger는 Trino 접근제어에도 적용 가능** |
| **DS389 · Kerberos · LAM** `[복원]` | LDAP 디렉터리·Kerberos 인증. **FreeIPA 제외 (ADR-066)** |
| **Jenkins** `[복원]` | GitLab CI와 역할 분담 필요 (TODO-40) |
| **Sentry / GlitchTip** | 애플리케이션 오류 추적 |

---

## 7. 비기능 요구사항

### 7-1. 가용성

| 항목 | 목표 | 현재 |
|---|---|---|
| prod 상태 저장 서비스 HA | 실제 복제 토폴로지 | ❌ **replicas만 증가, 복제 없음** |
| 컨트롤플레인 | 결정 필요 | 단일 k3s 서버 + SQLite (TODO-04) |
| 노드 장애 내성 | N+1 | 4노드 하한 (anti-affinity 제약) |
| PDB | replicas와 정합 | ❌ `redis-pdb minAvailable: 4` vs 축소 시 1 |

### 7-2. 용량 (추정)

> **모든 수치는 추정이다.** v1 매니페스트에 리소스 정의가 없고 신규 스택은 프로젝트 기본값을 사용했다. 실측 재산정이 선행되어야 한다 (ADR-058).

| 구성 | 파드 | MEM limits | 노드 |
|---|--:|--:|--:|
| 초기 산정 | ~255 | 329 Gi | 7 |
| DaemonSet 정정 후 | ~255 | 303 Gi | 6 |
| + JVM 힙 설정 + GlitchTip | ~233 | 255 Gi | 5 |
| + 실측 right-sizing | ~233 | 217 Gi | **4 (하한)** |

### 7-3. 비용 (추정, Vultr 기준)

| 항목 | 월 |
|---|--:|
| prod 6노드 + master + bastion + OPNsense | ~$2,526 |
| dev 3노드 | ~$1,400 |
| 블록 스토리지 2.25 TB (로컬 NVMe 사용 시 $0) | $225 |
| **최적화 후 (dev 로컬 대체 + 노드 축소 + 로컬 NVMe)** | **~$2,142** |
| 절감액 | −$2,009/월 (−$24,100/년) |

**dev를 로컬 Hyper-V(128 GB)로 대체하면 메모리 증설 비용이 1개월분 미만으로 회수된다.**

### 7-4. 로컬 환경

| 목표 | RAM | 판정 |
|---|---|---|
| 프로파일 전환 (core + 블록 1개) | 64 GB | ✅ |
| **전 구성요소 동시 배포** | **128 GB** | ✅ 권장 |
| HA 검증 (레플리카 3) | 256 GB | ✅ |
| — | 96 GB | ⚠️ 여유 2.8 GB로 비권장 |

### 7-5. 보안

SEC-001~SEC-712 총 68건. 현재 **충족 18 · 부분 12 · 미충족 20 · 목표 18.** 상세는 [SECURITY.md](./SECURITY.md).

---

## 8. Phase 달성도

계획서 §10의 7-Phase 계획 대비, 커밋 이력 98건 기준 실제 달성도.

| Phase | 계획 | 달성 | 근거 |
|:-:|---|:-:|---|
| **1** | 프로젝트 구조, `.sops.yaml`, v2 브랜치 | 🔶 | 구조·`.gitignore` 완료. **`.sops.yaml`은 플레이스홀더 키** (커밋 `9f42bf8`) |
| **2** | OpenTofu 멀티 프로바이더 + bootstrap 스크립트 | 🔶 | Vultr 완전, **Hetzner 미완**. k3s·Istio·ArgoCD·Reloader 스크립트 완료. **오퍼레이터 설치 스크립트 없음** (커밋 `e6868ca`·`157c1bd`) |
| **3** | Kustomize Base + 보안 수정 + SOPS + Kyverno + PSS | 🔶 | **securityContext·리소스·프로브 전수 완료**(3-2/3-3/3-4). **SOPS 암호화 미수행**(3-1). Kyverno 6정책 완료(3-7). PSS는 dev에서 `privileged`로 완화(3-8) (커밋 `df8ec4a`) |
| **4** | Overlay + NetworkPolicy + PDB | ✅ | dev/prod 오버레이, NetPol 14, PDB 8 (커밋 `22ea10e`) |
| **5** | ArgoCD GitOps + 로테이션 + Trivy CI + Cosign + 미러링 | 🔶 | 전부 작성되었으나 **로테이션은 키 이름 불일치로 동작 불가**, Argo Events는 목적 상실, **Cosign 검증 정책 없음** (커밋 `e91814f`) |
| **6** | Istio Ambient + ELK SIEM + Falco + Falcosidekick | 🔶 | 매니페스트 완료. **ambient는 dev 비활성, mTLS PERMISSIVE, Filebeat가 Logstash 우회** (커밋 `94ba41d`·`33e1c94`) |
| **7** | 보안 검증 스위트 | 🔶 | 9종 작성 완료. **2종이 자기 레포에서 오탐/실패** (커밋 `724a3c5`) |

**요약: 매니페스트 작성은 전 Phase 완료되었으나 실제 동작하는 상태는 아니다.** 커밋 이력 후반 40여 건이 실배포 디버깅(GitLab OOM, Keycloak health 포트, Istio ambient 비활성, PSS 완화, SOPS 비활성화)인 것이 이를 보여준다.

### 8-1. `README.md`는 v2를 반영하지 않는다

`README.md:24-32`의 서비스 표는 Hadoop·HBase·Solr·Kerberos·Ranger·Knox·Jenkins를 나열하는 **v1 내용 그대로**다. **FreeIPA 항목만 ADR-066에 따라 제거했고 나머지는 수정하지 않았다** — 별도 결정 사항으로 남긴다.

---

## 9. 미결정 사항

### 9-1. 즉시 결정이 필요한 4건

| # | 항목 | 미지정 시 가정 |
|---|---|---|
| 1 | 런타임 보안: **Tetragon vs Falco** | Tetragon (차단 기능 + Cilium 정합) |
| 2 | 시크릿 관리: **Vault vs SOPS+age** | Vault (G19·G20·G21·G30 일괄 해소) |
| 3 | APM 배포: **Sentry(Helm) vs GlitchTip** | Sentry Helm — **단 GlitchTip 재검토 권고** (−$384/월, −20 GB) |
| 4 | **Spark ETL 잡 선정** (TODO-42) | **가정하지 않는다.** Spark·Livy·Connect는 `[작업 수단]`으로만 배치하고 잡은 만들지 않는다 |

### 9-2. 아키텍처 TODO 47건

[ARCHITECTURE.md §10](./ARCHITECTURE.md#10-아키텍처-결정-필요-항목-todo) 참조. 영역별: 외부 접근 4 · 컨트롤플레인/HA 3 · 스토리지/DR 3 · 레이크하우스 4 · 보안 8 · GitOps 5 · 환경 정합성 6 · 신규 스택 8 · **Spark 계층 6**(TODO-42~47).

### 9-3. 검증 불가 항목 `[UNVERIFIED]`

| 항목 | 사유 |
|---|---|
| kubeconform 스키마 검증 결과 | 바이너리 미설치 |
| `tofu plan` 결과 | 바이너리 미설치 |
| OPNsense의 Vultr 배치 실현성 | 커스텀 ISO 지원·VPC 라우팅 제어 확인 필요 |
| `taliesins/hyperv` 프로바이더 유지보수 상태 | 확인 필요 |
| Apicurio Studio 이미지 pull 가능 여부 | 확인 필요 |
| Sentry의 OTLP 직접 수집 지원 범위 | 버전·구성 의존 |
| Wazuh Indexer의 Logstash `opensearch` 플러그인 호환 | 버전 의존 |
| Hyper-V에서 Cilium eBPF 동작 범위 | 커널·드라이버 버전 의존 |
| 클라우드 단가 (2026-08 기준 추정) | OVH는 2026-10-01 개편 예정 |

---

## 10. 성공 기준

| # | 기준 | 검증 방법 |
|---|---|---|
| S-1 | 빈 클라우드 계정에서 코드만으로 전체 스택이 기동한다 | Phase A~G 무중단 실행 |
| S-2 | 배포 블로커 P0·P1 15건이 전부 해소된다 | DEPLOYMENT.md §1 |
| S-3 | SEC 요구사항 미충족 20건이 0이 된다 | `run-all.sh` 전 항목 PASS |
| S-4 | INFRA 요구사항 미충족 24건이 0이 된다 | DEPLOYMENT.md §8 |
| S-5 | 128 GB 로컬 호스트에서 전 구성요소가 기동한다 | `local-*` 프로파일 + 전체 배포 |
| S-6 | ambient 우회 검증(SEC-108)을 통과하고 mTLS STRICT로 전환된다 | ztunnel HBONE 연결 수 확인 |
| S-7 | Gitleaks 이력 스캔에서 시크릿 0건 | CI 게이트 |
| S-8 | 백업에서 데이터를 복원할 수 있다 | 복원 리허설 |
| S-9 | 실측 기반으로 노드 수가 재산정된다 | KRR 2주 관측 후 |
| S-10 | ADR 미결정(Open) 항목이 전부 결정된다 | ADR-CANDIDATES.md |

---

## 관련 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 데이터 흐름, 갭 목록, TODO
- [SECURITY.md](./SECURITY.md) — SEC-xxx 보안 요구사항
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소 카탈로그, v1↔v2 대조
- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 용량·비용
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — 결정 기록 후보
