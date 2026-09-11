# SECURITY — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> 표기 규칙은 [ARCHITECTURE.md](./ARCHITECTURE.md) 서두와 동일하다: `[구현됨]` `[목표]` `[미구현]` `[UNVERIFIED]`
>
> **요구사항 ID 체계**
>
> | 대역 | 계층 |
> |---|---|
> | `SEC-0xx` | Admission · 정책 강제 |
> | `SEC-1xx` | 네트워크 분리 |
> | `SEC-2xx` | 인증 · 인가 |
> | `SEC-3xx` | 런타임 보안 |
> | `SEC-4xx` | 시크릿 관리 |
> | `SEC-5xx` | 공급망 |
> | `SEC-6xx` | 호스트 · IaC |
> | `SEC-7xx` | 감사 · 검증 |

---

## 목차

1. [현황 요약](#1-현황-요약)
2. [즉시 조치 필요](#2-즉시-조치-필요)
3. [통제 인벤토리](#3-통제-인벤토리)
4. [워크로드 보안 커버리지](#4-워크로드-보안-커버리지)
5. [의도된 예외](#5-의도된-예외)
6. [시크릿 관리 모델](#6-시크릿-관리-모델)
7. [Aqua Platform 기능의 OSS 대응](#7-aqua-platform-기능의-oss-대응)
8. [보안 요구사항 (SEC-xxx)](#8-보안-요구사항-sec-xxx)
9. [검증 스위트 매핑](#9-검증-스위트-매핑)

---

## 1. 현황 요약

| 계층 | 현재 | 목표 |
|---|---|---|
| Admission | Kyverno 6정책 (base Audit, prod 4종 Enforce) `[구현됨]` | + Kubescape, `verifyImages`, 시스템 NS 예외 |
| 네트워크 | default-deny-ingress + allow 13종, Istio AuthzPolicy 4종 `[구현됨]` | + Cilium CNP, egress 차단, 커버리지 완성 |
| 인증 | Keycloak `[구현됨]` | + DS389/Kerberos, oauth2-proxy, SA 12개 |
| 런타임 | Falco + Falcosidekick `[구현됨]` | Tetragon(차단 가능)으로 전환 |
| 시크릿 | **SOPS+age 설계만 존재, 실제 미작동** `[미구현]` | Vault |
| 공급망 | Trivy CI 3잡 + Cosign 서명 `[구현됨]` | + Trivy Operator, verifyImages, SBOM, DefectDojo |
| 호스트 | Vultr bastion + VPC + deny-all 방화벽 `[구현됨]` | + OPNsense, Suricata, Zeek |
| 감사 | 검증 스크립트 9종 `[구현됨]` | + Wazuh SIEM, Caldera |

**가장 중요한 사실: 렌더링된 매니페스트에 Secret이 0개다.** 8개 이상 워크로드가 `secretKeyRef`를 참조하므로 **현재 상태로는 클러스터가 기동하지 않는다.**

---

## 2. 즉시 조치 필요

### SEC-401 — 커밋된 개인키 폐기 **[CRITICAL]**

`v1/cluster/tls.key`에 RSA 개인키가 평문으로 git에 커밋되어 있다.

```
v1/cluster/tls.key    1,736 bytes   PKCS8 개인키 헤더로 시작   (git 추적 중)
v1/cluster/tls.crt    1,166 bytes
v1/tls/ca_bundle.crt  2,470 bytes
```

> ★ 위에서 헤더 문자열을 그대로 적지 않는다. 시크릿 스캐너는 그 **마커 자체**를
> 키로 읽어서, 문서가 사실을 설명하는 것만으로 Critical 탐지가 하나 생긴다
> (실측: 이 줄이 §8-91 의 9건 중 하나였다). 뜻은 그대로 두고 마커만 뺀다 —
> 스캐너를 피하려는 것이 아니라 **기계가 읽는 표식을 산문에 심지 않는 것**이다.

`v1/tls/tls.sh:1`에 따르면 `*.oneinchmarket.co.kr` 와일드카드 자체서명 인증서의 키다. `.gitignore`에 `*.key`·`*.crt`가 있으나 **이미 추적 중인 파일에는 적용되지 않는다.**

**조치**: ① 사용처 확인 → ② `git rm --cached` + `git filter-repo`로 이력 제거 → ③ 리모트 강제 갱신 → ④ 재발급 → ⑤ Gitleaks를 CI 게이트로 추가.

#### 알려진 오탐 — 예외를 두지 않는다 (2026-09-08)

§8-91 의 이력 스캔 9건 중 셋은 오탐이었다. **억제 장치를 두지 않고 여기 적는다.**

| 탐지 | 왜 오탐인가 |
|---|---|
| `kubernetes/overlays/local/openmeter/openmeter.yaml` · `local/openmeter-values.yaml` 의 "Password in URL" | 토큰이 `__OPENMETER_DB_PASSWORD__` 형태의 **자리표시자**다. OpenMeter 는 환경변수 오버라이드가 먹지 않아(Gotcha 26) 평문을 두지 않으려고 initContainer 치환을 쓴다. 실측으로 토큰 패턴이 `__xxxxxxxx_xxxxxxxx__` 임을 확인했다 |
| 이 문서의 PKCS8 탐지 | SEC-401 을 설명하는 문장이었다. 위에서 마커를 뺐다 |

★★ **`.gitlab/secret-detection-ruleset.toml` 을 쓰지 않는다.** 만들어 봤으나
분석기가 `ruleset customization not enabled` 를 남기고 무시했다 — 이 기능은
**Ultimate 전용**이고 이 인스턴스는 Free 다(Secret Push Protection 과 같다).
그 파일은 아무 일도 하지 않으면서 **자기 주석의 마커 때문에 탐지를 하나 더
만들었다.** 지웠다.

★ `SECRET_DETECTION_EXCLUDED_PATHS` 로 경로를 빼는 길도 있으나 **쓰지 않는다** —
그 파일들에 진짜 시크릿이 들어와도 함께 놓치게 된다. 오탐 두 건을 감수하는
편이 낫다고 판단했다. 그 파일을 고치는 커밋에서 증분 잡이 걸리면 이 표를 볼 것.

#### 진행 상황 (2026-09-08, §8-92)

| 단계 | 상태 |
|---|---|
| ① 사용처 확인 | **완료** — `v1/admin/admin-configmap.yaml` 의 런타임 마운트 경로만 참조하며, `v1/` 은 배포 금지 트리다. **활성 인증서 6종은 전부 cert-manager 발급**(`gateway-*`·`wazuh-*` Issuer)이라 이 키는 TLS 경로에 없다 |
| ② 트리에서 제거 | **완료** — `v1/cluster/tls.key` 삭제. ★ `tls.crt` 는 공개값이라 남겼다 |
| ②-b 이력 제거 | **하지 않았다.** `git filter-repo` 는 모든 커밋 SHA 를 바꾸고 강제 push 가 필요하며 ArgoCD 가 추적하는 리비전도 함께 깨진다. 되돌리기 어려운 선택이라 **결정을 남겨 둔다** |
| ③ 리모트 갱신 | ②-b 에 달려 있다 |
| ④ 재발급 | **불필요로 판단** — 이 키로 발급된 인증서가 현재 쓰이는 곳이 없다. 다만 **키 자체는 손상된 것으로 취급**하고 재사용하지 않는다 |
| ⑤ CI 게이트 | **완료** — GitLab Secret Detection 을 켰다(§8-91). 매 push 의 증분 잡은 `allow_failure: false` 로 **새 유출을 막고**, 이력 잡은 schedule/manual 로 빚을 센다 |

★★ **①~⑤ 를 하는 과정에서 같은 종류가 더 나왔다.** 이력 전체 스캔이 **9건**을
찾았고 알고 있던 것은 SEC-401 하나뿐이었다 — 상세와 분류는 §8-92 다.
그중 진짜였던 또 하나가 `openreplay` 의 ConfigMap 안에 있던 개인키다
(Secret 도 아니었다). 그것도 제거했다.

### SEC-402 — 평문 자격증명 제거 **[HIGH]**

`v1/ranger/admin/ranger-admin-configmap.yaml:6`에 DB 비밀번호가 평문으로 커밋되어 있다. 계획서 §2가 이미 "ConfigMap에 평문 비밀번호 — 13개 서비스"로 지적한 사안이다.

v1 매니페스트를 v2로 복원할 때 **모든 ConfigMap 평문 자격증명을 Secret으로 전환**해야 한다.

### SEC-403 — 시크릿 배선 복구 **[CRITICAL]**

12개 `*.enc.yaml`이 전부 kustomization에서 주석 처리되어 Secret이 하나도 배포되지 않는다. Vault 전환(ADR-024)이든 임시 조치든 **배포 전 반드시 해소해야 한다.**

---

## 3. 통제 인벤토리

### (a) Admission · 정책 강제

| 통제 | 동작 | 파일 | 모드 |
|---|---|---|---|
| `disallow-root-user` | `runAsNonRoot: true` 요구 | `kyverno-disallow-root.yaml` | Audit → prod **Enforce**. 예외: 이름 8종(gitlab·falco·filebeat·otel-agent·ds389·lam·wazuh-manager·safeline) + 시스템 NS 8개. **OpenReplay 18건은 미해결**(LOCAL-DEPLOYMENT §8-29) |
| `disallow-privilege-escalation` | `allowPrivilegeEscalation: false` 요구 | `kyverno-disallow-privilege-escalation.yaml:19` | Audit → prod **Enforce** |
| `require-resource-limits` | requests+limits 요구 | `kyverno-require-resources.yaml:18` | Audit → prod **Enforce** |
| `disallow-latest-tag` | `:latest` 차단 | `kyverno-disallow-latest.yaml:21` | Audit → prod **Enforce** |
| `require-standard-labels` | `app.kubernetes.io/*` 요구 | `kyverno-require-labels.yaml:19` | **Audit만 — prod 패치 없음 (G35)** |
| `require-health-probes` | liveness+readiness 요구 | `kyverno-require-probes.yaml:18` | **Audit만 — prod 패치 없음 (G35)** |
| Pod Security Admission | namespace 레이블 | `overlays/{dev,prod}/namespace.yaml:11` | prod `restricted` / **dev `privileged` (G7)** |
| kubeconform 스키마 검증 | CI | `.gitlab-ci.yml` | **`allow_failure: true` — 게이트 무력 (TODO-24)** |

`[목표]` Kubescape, Kyverno `verifyImages`, 시스템 네임스페이스 예외.

### (b) 네트워크 분리

| 통제 | 동작 | 파일 | 모드 |
|---|---|---|---|
| default-deny-ingress | `podSelector: {}`, 규칙 없음 | `default-deny.yaml` | 강제. **Ingress만 — egress 차단 없음 (G27)** |
| allow-* NetworkPolicy 13종 | admin·cmmn-api·nginx·postgresql·mariadb·mongodb·redis·kafka·akhq·kibana·logstash·elasticsearch·falcosidekick | `network-policies/*-netpol.yaml` | 강제 |
| Istio PeerAuthentication | mTLS | `peer-authentication.yaml:13` | **PERMISSIVE (G6)** |
| Istio AuthorizationPolicy 5종 | database·kafka·**opensearch**·**data-prepper**·minio 대상 | `authorization-policies.yaml` | ambient 활성 시에만. **dev 비활성** |
| waypoint Gateway | L7 정책 지점 (HBONE 15008) | `waypoint-proxy.yaml` | ambient 활성 시 |
| Vultr bastion 방화벽 | 22/tcp + 51820/udp만 공개 | `network/vultr/main.tf:18-42` | 강제 |
| Vultr k3s 방화벽 | **빈 방화벽 그룹 = 공인 IP deny-all** | `network/vultr/main.tf:44-46` | 강제 |
| WireGuard VPN | bastion 터널 | `bootstrap-k3s.sh:45-108` | 강제 |
| ~~Hetzner 방화벽~~ | 22/80/443을 `0.0.0.0/0`에 개방 | `network/hetzner/main.tf:22-52` | **어떤 서버에도 미부착 (G28)** — ADR-019로 제거 |

`[목표]` Cilium CNP(L3/L4/L7·FQDN egress), OPNsense, Suricata 인라인 IPS, Zeek, SafeLine WAF.

### (c) 인증 · 인가

| 통제 | 동작 | 파일 | 비고 |
|---|---|---|---|
| Keycloak | 중앙 IdP, PostgreSQL+Redis 백엔드 | `security/keycloak/` | **대상 NetworkPolicy 없음 (G13)** |
| RBAC `secret-rotator` | secrets `get`/`patch` | `secret-rotator-rbac.yaml:20-23` | **`resourceNames` 없음 (G30)** |
| RBAC `falco` ClusterRole | 코어+apps `get/list/watch`, 쓰기 동사 없음 | `falco-rbac.yaml:19-27` | 최소권한 양호 |
| RBAC `trivy-scanner` | `pods` `get/list`만 | `trivy-rbac.yaml:19-22` | 최소 |
| ArgoCD AppProject | 소스 레포·목적지·Kind 제한 | `projects/oneinchmarket.yaml` | **`security.istio.io`·`gateway.networking.k8s.io` 누락 (G17)** |

`[목표]` DS389 LDAP, Kerberos, LAM, Ranger(Trino 접근제어 포함), Knox, oauth2-proxy.

### (d) 런타임 보안

| 통제 | 동작 | 파일 | 비고 |
|---|---|---|---|
| Falco DaemonSet | eBPF syscall 탐지 (`engine.kind=modern_ebpf`) | `falco-daemonset.yaml` | `privileged: true`, `hostNetwork: true` |
| Falcosidekick | 알림 라우팅 → ES · Kafka · Slack | `falcosidekick-deployment.yaml` | `readOnlyRootFilesystem: true`, 비루트, drop ALL — 양호 |
| Falco 커스텀 룰 | ConfigMap 마운트 | `falco-configmap.yaml` | |
| Trivy 주간 CronJob | 실행 중 이미지 스캔 → ES | `trivy-cronjob.yaml` | **이미지에 kubectl 없음, cert 볼륨 미마운트 → 동작 불가** |

`[목표]` Tetragon(탐지+차단), 드리프트 방지.

### (e) 시크릿 관리

| 통제 | 상태 |
|---|---|
| SOPS + age | **미작동** — 플레이스홀더 키, 전 파일 평문/가짜 암호문 (G1) |
| `kustomize-sops` CMP | **플러그인 이름 불일치**(`ksops`), repo-server 사이드카 없음 (G3) |
| 로테이션 CronJob 8종 | **키 이름 4종 불일치, 대상 시크릿 오류, 출력 경로 부재** (G19·G20·G21) |
| `.gitignore` | `*.dec.yaml`·`keys.txt`·`*.age`·`*.key`·`*.crt`·`*.pem`·`.env`·`*.tfstate*` `[구현됨]` — 단 **기추적 파일에는 무효 (SEC-401)** |

`[목표]` HashiCorp Vault — 동적 자격증명·Transit·PKI. 채택 시 CronJob 8종·git-sync·`.enc.yaml` 12개 제거.

### (f) 공급망

| 통제 | 모드 |
|---|---|
| `trivy-image-scan` | `allow_failure: false` `[구현됨]` |
| `trivy-config-scan` | `allow_failure: false` `[구현됨]` |
| `trivy-filesystem-scan` | schedule 전용, `allow_failure: true` |
| `cosign-sign` | Trivy 통과 후 서명 `[구현됨]` — **검증 정책 없음 (G10)** |
| `mirror-images` | schedule, `allow_failure: true`, **`:latest` 미러링** |
| prod 태그 핀닝 | 17개 — **로테이션·스캔 이미지 6종 미포함 (G31)** |

`[목표]` Trivy Operator, `verifyImages`, Syft→Dependency-Track, DefectDojo, Gitleaks, Checkov, Policy Reporter.

### (g) 호스트 · IaC

| 통제 | 상태 |
|---|---|
| Vultr 공인 IP deny-all + VPC 전용 | `[구현됨]` |
| bastion 22/51820만 노출 | `[구현됨]` |
| WireGuard 터널 | `[구현됨]` — **단일 하드코딩 피어**(`bootstrap-k3s.sh:78-80`) |
| tfstate | **`backend "local"`, 잠금 없음** (TODO-08) |

`[목표]` OPNsense 경계 방화벽, Wazuh HIDS/FIM, OpenSCAP/Lynis.

### (h) 감사 · 검증

| 스크립트 | 검증 대상 | 문제 |
|---|---|---|
| `01-kube-bench.yaml` | CIS Benchmark | — |
| `02-kubesec-scan.sh` | 매니페스트 보안 점수 | 로컬 |
| `03-trivy-scan.sh` | 이미지 CVE + 매니페스트 | 로컬 |
| `04-rotation-dryrun.sh` | 로테이션 CronJob/Secret/RBAC | — |
| `05-kyverno-audit.sh` | 6정책 존재 + dry-run | — |
| `06-falco-test.yaml` | 탐지 규칙 트리거 | — |
| `07-netpol-test.sh` | 허용/차단 트래픽 | **`default-deny-all`을 찾음 — 실제는 `default-deny-ingress`. 항상 MISS (G33)** |
| `08-age-key-backup.sh` | age 키 보관 상태 | **오늘 실행 시 `.sops.yaml` + `.enc.yaml` 12건 전부 FAIL (G33)** |
| `09-rbac-audit.sh` | 와일드카드 RBAC, default SA | `nginx`·`falcosidekick`·`logstash` 탐지 예상 (G34) |

---

## 4. 워크로드 보안 커버리지

범례: ✅ 적용 · ⚠️ 의도된 예외 · ❌ 없음 · — 오퍼레이터 관리

| 워크로드 | runAsNonRoot | drop ALL | privEsc false | seccomp | 리소스 | 프로브 | NetPol(대상) | AuthzPolicy(대상) |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| admin | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| cmmn-api | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| nginx | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ · **default SA** |
| hive-metastore | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **hive-server** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| minio | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| trino | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **❌** | ❌ |
| mariadb | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| mongodb | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| postgresql | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| redis | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **gitlab** | ⚠️ `runAsUser: 0` | ⚠️ **drop 없이 capability 8종 추가** | ⚠️ `true` | ✅(pod) | ✅ | ✅ | ✅ | ❌ |
| **kafka-bridge** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **jenkins** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **glitchtip** (web·worker) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **pyroscope** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| akhq | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| apicurio | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| kafka | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (9092만, **9093 없음**) | ✅ |
| **falco** | ⚠️ 미설정 | ⚠️ 미설정 | ⚠️ 미설정 | ⚠️ 미설정 | ✅ | ✅ | N/A(hostNetwork) | N/A |
| falcosidekick | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ · **default SA** |
| **filebeat** | ⚠️ `runAsUser: 0` | ⚠️ drop ALL + `DAC_READ_SEARCH` | ✅ | ✅ | ✅ | ✅ | **❌** | ✅(소스) |
| logstash | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅(소스) · **default SA** |
| keycloak | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **❌** | ❌ |
| opensearch | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| opensearch-dashboards | ✅ | ✅ | ✅ | — | ✅ | — | ✅ | ❌ |
| data-prepper | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |

**요약**

- securityContext 위생은 **GitLab·Falco·Filebeat 3건을 제외하고 전 워크로드에 적용**되어 있다. 계획서 Phase 3의 실질적 성과다.
- **NetworkPolicy 커버리지 공백 2건** — Keycloak·Trino. default-deny 하에서 정당한 인바운드 경로가 없다.
  (MinIO·Hive Metastore·Apicurio 는 이후 배포 과정에서, GitLab 은 6단계에서 `devops-netpol.yaml`
  을 신설하며 해소되었다 — `kustomize build | grep podSelector` 로 확인할 것)
- **AuthorizationPolicy 대상은 4개뿐**이고, SA 부재(G18)로 principal 매칭이 되지 않아 사실상 무효다.

---

## 5. 의도된 예외

| 워크로드 | 예외 | 명시 여부 | 정당성 | prod 충돌 |
|---|---|---|---|---|
| **Falco** | `privileged: true`, `hostNetwork: true` | 매니페스트 명시(`falco-daemonset.yaml:28,50`) | eBPF syscall 추적 | **PSS `restricted`에서 admit 불가** |
| **Filebeat** | `runAsUser: 0`, capability `DAC_READ_SEARCH` | 명시(`filebeat-daemonset.yaml:23-24,49-51`) | 호스트 로그 읽기. **blanket privileged보다 좁은 범위 — 모범 사례** | 동일 |
| **GitLab EE** | `runAsUser: 0`, `allowPrivilegeEscalation: true`, capability 8종 | 주석 명시(`gitlab-statefulset.yaml:28`) | Omnibus chef/reconfigure가 root 요구 | 동일. **세 예외 중 가장 넓다 — `drop: ALL`조차 없다** |

`[목표]` 추가 예외 — Tetragon(`privileged`, `hostPID`), Cilium agent(`privileged`, `SYS_MODULE`, bpf 마운트), Suricata/Zeek(`NET_ADMIN`, `NET_RAW`), Wazuh agent(호스트 FS, `hostPID`), Kubescape node-agent(eBPF), node-exporter(`hostPID`, `/proc`·`/sys`).

> ~~Hadoop/HBase/Knox(root 실행)~~ — **예측이 빗나갔다.** 실제로 배포해 보니 셋 다
> 비특권으로 돈다: hadoop uid 1000 · hbase uid 1001 · knox uid 8000, 전부
> `drop: ["ALL"]` 이다. v1 매니페스트가 root 로 돌던 것이지 이미지의 제약이 아니었다.
> `[목표]` 예외 목록은 실배포로 확인하기 전까지 추정이라는 점에 주의할 것.

**어느 예외도 네임스페이스 범위 Kyverno `exclude`나 per-NS PSA 오버라이드와 짝지어져 있지 않다.** 현재는 Kyverno가 Audit이고 dev PSA가 `privileged`로 낮춰진 덕에 동작한다.

→ **TODO-13의 실질적 해답: 보안·플랫폼 전용 네임스페이스를 `privileged`로 분리하고 워크로드 네임스페이스만 `restricted`를 유지한다.**

---

## 6. 시크릿 관리 모델

### 6-1. 의도된 설계 (현재 미작동)

```
개발자 PC                      Git (GitLab)              ArgoCD + k3s
  1. 평문 secret 작성
  2. sops --encrypt --age
  3. git push ─────────────→ 암호화 YAML
                                   └──────→ 4. ArgoCD 감지
                                            5. CMP가 age 키로 복호화
                                            6. K8s Secret 생성
```

### 6-2. 신뢰 경계 · 단일 장애점

- **age 개인키가 최소 두 파드에 디스크로 존재**한다 — ArgoCD repo-server CMP(`/sops/age/keys.txt`)와 `rotation-git-sync` CronJob(`/age/keys.txt`).
- 두 파드에 `kubectl exec` 하거나 `kubectl get secret sops-age`가 가능한 주체는 **git 이력 전체의 모든 시크릿을 복호화할 수 있다.** age에는 키 로테이션/버저닝이 없어 **감싸인 시크릿만 로테이션되고 마스터 키는 그대로다.**
- `sops-age` Secret의 최초 주입 경로는 이 레포에 없다 `[UNVERIFIED]`.
- `rotation-git-sync`가 **리뷰 게이트 없이 `v2`에 직접 push**하고 prod Application이 `selfHeal: true`이므로(G26), `secret-rotator` SA 또는 `gitlab-deploy-token` 탈취 시 **사람의 승인 없이 prod 매니페스트를 변경하는 경로**가 생긴다.

### 6-3. 현재 실태

**이 파이프라인은 작동하지 않는다.** 모든 `*.enc.yaml`이 플레이스홀더이므로 **git에 실제 시크릿 자료는 없다.** 유출이 없다는 점에서는 다행이나, 배포가 불가능하다는 뜻이기도 하다.

### 6-4. 목표 — Vault (ADR-024)

Vault 채택 시 **G19·G20·G21·G30·SEC-403이 전부 소멸**한다. CronJob 8종·git-sync·`.enc.yaml` 12개가 제거되고 시크릿이 git을 경유하지 않는다.

---

## 7. Aqua Platform 기능의 OSS 대응

| Aqua 기능 | OSS 대응 | 상태 |
|---|---|---|
| 이미지 취약점 스캔 (CI) | Trivy | ✅ `[구현됨]` |
| 클러스터 내 지속 스캔 | **Trivy Operator** | 🆕 `[목표]` |
| KSPM · 컴플라이언스 | Kubescape + Wazuh SCA | `[목표]` |
| IaC 스캔 | Trivy config + **Checkov** | 🔶 Trivy만 |
| Assurance Policy (배포 차단) | Kyverno + Trivy Operator CR 연동 | 🔶 연동 없음 |
| 이미지 서명·검증 | Cosign + **Kyverno `verifyImages`** | 🔶 서명만 (G10) |
| SBOM 생성·관리 | **Syft + Dependency-Track** | 🆕 `[목표]` |
| 취약점 통합 트리아지 | **DefectDojo** | 🆕 `[목표]` |
| 정책 리포트 대시보드 | **Policy Reporter** | 🆕 `[목표]` |
| 시크릿 탐지 (이미지) | Trivy secret | ✅ |
| **시크릿 탐지 (Git 이력)** | **Gitleaks** | 🆕 — SEC-401·402를 잡았을 도구 |
| 런타임 보호·차단 | Tetragon | `[목표]` |
| 드리프트 방지 | Tetragon exec 정책 + `readOnlyRootFilesystem` | 🔶 **부분 커버** |
| 마이크로세그멘테이션 | Cilium | `[목표]` |
| 호스트 보안 (HIDS/FIM) | Wazuh | `[목표]` |
| 공격 시뮬레이션 | MITRE Caldera | `[목표]` |
| 레지스트리 스캔 게이트 | Harbor | ⬜ **미도입** (ADR-049) |
| **CSPM** | Prowler/ScoutSuite | ❌ **Vultr 미지원** — Checkov IaC 사전검사로 부분 대체 |
| **Dynamic Threat Analysis** | — | ❌ **OSS 동등물 없음** |

**대체 불가 3영역을 명시한다** — DTA(샌드박스 폭파), 드리프트 방지(빌드 시점 바이너리 목록 기반 강제), CSPM(런타임 클라우드 포스처). 상용 제품 대비 남는 격차이며 상용 재검토 시 판단 근거가 된다.

### 통합 흐름

```
[CI]  Gitleaks ─┐
      Checkov ──┤
      Trivy ────┼─→ DefectDojo (중복 제거·트리아지·SLA)
      Syft ─────┴─→ Dependency-Track (SBOM 지속 추적 → 신규 CVE 소급 알림)

[클러스터]  Trivy Operator ─┐
            Kubescape ──────┼─→ PolicyReport CR ─→ Policy Reporter ─→ Grafana
            Kyverno ────────┘                          └─→ DefectDojo

[런타임]  Tetragon · Suricata · Zeek · Wazuh Agent ─→ Logstash ─→ Wazuh Indexer
```

---

## 8. 보안 요구사항 (SEC-xxx)

`상태`: ✅ 충족 · 🔶 부분 · ❌ 미충족 · 🎯 목표(미구현)

### SEC-0xx — Admission · 정책 강제

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-001 | 모든 Pod는 `runAsNonRoot: true`를 설정한다 | 🔶 | GitLab·Falco 예외 |
| SEC-002 | 모든 컨테이너는 `allowPrivilegeEscalation: false`를 설정한다 | 🔶 | GitLab 예외 |
| SEC-003 | 모든 컨테이너는 `capabilities.drop: [ALL]`을 설정한다 | 🔶 | GitLab 예외 (G32) |
| SEC-004 | 모든 워크로드는 `seccompProfile: RuntimeDefault`를 설정한다 | ✅ | Falco 제외 전 워크로드 |
| SEC-005 | 모든 컨테이너는 cpu/memory requests+limits를 설정한다 | ✅ | 18개 워크로드 전수 |
| SEC-006 | 모든 장기 실행 워크로드는 liveness+readiness 프로브를 설정한다 | ✅ | 전수 |
| SEC-007 | 모든 리소스는 `app.kubernetes.io/{name,part-of}` 레이블을 갖는다 | 🔶 | 정책이 **영구 Audit** (G35) |
| SEC-008 | prod에서 `:latest` 태그를 차단한다 | 🔶 | 로테이션·스캔 이미지 6종 미포함 (G31) |
| SEC-009 | Kyverno 정책은 `kube-system`·`istio-system`·`argocd`·`elastic-system`을 제외한다 | ❌ | G24 · TODO-15 |
| SEC-010 | ClusterPolicy는 단일 Application이 소유한다 | ❌ | G25 |
| SEC-011 | 워크로드 네임스페이스는 PSA `enforce: restricted`를 적용한다 | ❌ | dev는 `privileged` (G7) |
| SEC-012 | 특권이 필요한 워크로드는 전용 네임스페이스로 분리한다 | 🎯 | TODO-13 |
| SEC-013 | CRITICAL CVE가 있는 이미지는 Pod 생성을 거부한다 | 🎯 | Trivy Operator + Kyverno |
| SEC-014 | Cosign 서명이 없는 이미지는 admission에서 거부한다 | ❌ | G10 |
| SEC-015 | 모든 컨테이너는 `readOnlyRootFilesystem: true`를 설정한다 | ❌ | 드리프트 방지 전제 |
| SEC-016 | kubeconform 스키마 검증을 머지 게이트로 강제한다 | ❌ | TODO-24 |

### SEC-1xx — 네트워크 분리

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-101 | 모든 워크로드 네임스페이스에 default-deny **ingress**를 적용한다 | ✅ | `default-deny.yaml` |
| SEC-102 | 모든 워크로드 네임스페이스에 default-deny **egress**를 적용한다 | ❌ | G27 — 데이터 유출·C2 경로 |
| SEC-103 | 인바운드 경로가 있는 모든 워크로드에 allow 정책을 정의한다 | ❌ | 6건 누락 (G13) |
| SEC-104 | Kafka 컨트롤러 포트(9093) 브로커 간 통신을 허용한다 | ❌ | G23 — prod quorum 형성 불가 |
| SEC-105 | 죽은 NetworkPolicy 셀렉터를 제거한다 | ❌ | `schema-reg` |
| SEC-106 | 메시 트래픽은 mTLS `STRICT`를 강제한다 | ❌ | PERMISSIVE (G6) |
| SEC-107 | 모든 워크로드 네임스페이스에 Istio ambient를 활성화한다 | ❌ | dev 비활성 |
| SEC-108 | ambient 우회(M1 설정 오류)가 발생하지 않음을 검증한다 | 🎯 | ADR-043 — 신규 검증 항목 |
| SEC-109 | 외부 egress는 FQDN 화이트리스트로 제한한다 | 🎯 | CiliumNetworkPolicy |
| SEC-110 | 클러스터 노드의 공인 IP는 인바운드를 전면 차단한다 | ✅ | `network/vultr/main.tf:44-46` |
| SEC-111 | bastion은 SSH(22)와 WireGuard(51820)만 노출한다 | ✅ | `network/vultr/main.tf:18-42` |
| SEC-112 | 클러스터 관리 접근은 VPN을 경유한다 | ✅ | `bootstrap-k3s.sh` |
| SEC-113 | 남-북 트래픽에 인라인 IPS를 적용한다 | 🎯 | OPNsense + Suricata |
| SEC-114 | 외부 노출 HTTP 엔드포인트는 WAF를 경유한다 | 🎯 | SafeLine |
| SEC-115 | 외부 노출 경로에 레이트리밋과 페이로드 상한을 설정한다 | 🎯 | v1은 `proxy-body-size: 1024m` — 과도 |

### SEC-2xx — 인증 · 인가

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-201 | 모든 워크로드는 전용 ServiceAccount를 사용한다 | ❌ | 15개 지정 / 3개 존재 (G18·G34) |
| SEC-202 | `automountServiceAccountToken`은 필요한 워크로드에만 허용한다 | 🎯 | `09-rbac-audit.sh` 검사 대상 |
| SEC-203 | RBAC에 와일드카드 동사·리소스를 사용하지 않는다 | ✅ | Falco·Trivy |
| SEC-204 | `secret-rotator` Role은 `resourceNames`로 대상을 한정한다 | ❌ | G30 |
| SEC-205 | 외부 노출 UI·API는 OIDC 인증 뒤에만 배치한다 | 🎯 | oauth2-proxy + Keycloak |
| SEC-206 | Kafka Bridge는 인증 계층 뒤에만 배치한다 | 🎯 | Bridge에 자체 인증 없음 (ADR-035) |
| SEC-207 | Bridge의 Kafka 자격증명은 공개 대상 토픽으로 ACL을 제한한다 | 🎯 | Kafka SASL·ACL 부재 → ADR-034 |
| SEC-208 | Bridge 관리·메타데이터 엔드포인트는 외부에 노출하지 않는다 | 🎯 | Ingress path 화이트리스트 |
| SEC-209 | ArgoCD AppProject는 사용하는 모든 API 그룹을 화이트리스트한다 | ❌ | G17 |
| SEC-210 | Keycloak을 사용자 마스터로 하고 LDAP은 페더레이션한다 | 🎯 | TODO-35 |
| SEC-211 | Hadoop `proxyuser` 위임은 사용자·호스트를 한정한다 | ⚠️ | `users=hive` 로 좁혔으나 `hosts=*` 다. Kerberos 미채택(`authentication=simple`)이라 위임 자체를 검증할 수단이 없다 — dev/prod 는 Knox·Ranger 경유로 대체할지 결정할 것 (TODO-48) |
| SEC-212 | Kyverno `disallow-root-user` 는 파드 레벨 `runAsNonRoot` 를 인정한다 | ✅ | 단일 `pattern` 으로 `containers[*]` 만 검사하던 것을 `anyPattern` 으로 고쳤다. 이 레포 규약은 파드 레벨이라 **prod 렌더의 컨테이너 53개 전부가 위반**이었고, prod 는 Enforce 라 배포가 통째로 거부될 상태였다(LOCAL-DEPLOYMENT §8-20). PSS `restricted` 의 판정도 "파드 또는 컨테이너"다 |

### SEC-3xx — 런타임 보안

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-301 | 모든 노드에서 syscall 수준 런타임 탐지를 수행한다 | ✅ | Falco DaemonSet |
| SEC-302 | 런타임 위협은 SIEM으로 전달된다 | 🔶 | Falcosidekick → ES/Kafka. Wazuh는 목표 |
| SEC-303 | 특권 런타임 에이전트는 예외를 매니페스트에 명시한다 | ✅ | Falco·Filebeat |
| SEC-304 | 탐지에서 차단으로 전환 가능한 런타임 통제를 갖춘다 | 🎯 | Tetragon (ADR-025) |
| SEC-305 | 이미지에 없던 바이너리의 실행을 차단한다 | 🎯 | **부분 커버만 가능** |
| SEC-306 | 호스트 파일 무결성 감시(FIM)를 수행한다 | 🎯 | Wazuh |
| SEC-307 | Kubernetes audit log를 SIEM으로 수집한다 | 🎯 | Wazuh |

### SEC-4xx — 시크릿 관리

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| **SEC-401** | **git 이력에 개인키·인증서가 존재하지 않는다** | ❌ | **`v1/cluster/tls.key` — 즉시 조치** |
| **SEC-402** | **ConfigMap에 평문 자격증명이 존재하지 않는다** | ❌ | **`v1/ranger/admin/ranger-admin-configmap.yaml:6`** |
| **SEC-403** | **워크로드가 참조하는 모든 Secret이 배포된다** | ❌ | **12개 전부 주석 처리 (G2) — 기동 불가** |
| SEC-404 | 커밋된 `*.enc.yaml`은 유효한 SOPS 메타데이터를 갖는다 | ❌ | 12개 전부 플레이스홀더 (G1) |
| SEC-405 | `.sops.yaml`의 age 수신자는 실제 공개키다 | ❌ | `age1xxxxx…` (G1) |
| SEC-406 | 로테이션이 패치하는 Secret 키 이름이 소비자와 일치한다 | ❌ | 7개 중 4개 불일치 (G19) |
| SEC-407 | ECK 관리 자격증명을 외부 로테이션이 덮어쓰지 않는다 | ❌ | G20 |
| SEC-408 | 관리자 자격증명 전송 시 TLS 인증서를 검증한다 | ❌ | `--insecure` (G29) |
| SEC-409 | 시크릿 자료가 git에 저장되지 않는다 | 🎯 | Vault (ADR-024) |
| SEC-410 | 시크릿 로테이션은 사람의 승인 없이 prod 매니페스트를 변경하지 않는다 | ❌ | git-sync + `selfHeal` (G26) |
| SEC-411 | age 개인키 접근 주체를 최소화하고 접근을 감사한다 | 🎯 | 현재 2개 파드 + `sops-age` |
| SEC-412 | Git 이력 시크릿 스캔을 머지 게이트로 강제한다 | 🎯 | Gitleaks |

### SEC-5xx — 공급망

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-501 | HIGH/CRITICAL CVE 발견 시 CI를 실패시킨다 | ✅ | `trivy-image-scan`, `trivy-config-scan` |
| SEC-502 | 이미지 서명은 스캔 통과 후에만 수행한다 | ✅ | `needs: trivy-image-scan` |
| SEC-503 | 클러스터 내 실행 중 이미지를 지속 스캔한다 | 🔶 | CronJob **동작 불가** → Trivy Operator |
| SEC-504 | 모든 빌드 산출물에 SBOM을 생성하고 보관한다 | 🎯 | Syft → Dependency-Track |
| SEC-505 | 배포된 이미지에 신규 CVE 공개 시 소급 알림한다 | 🎯 | Dependency-Track |
| SEC-506 | IaC 코드를 스캔하고 실패 시 파이프라인을 중단한다 | 🔶 | Trivy config만. Checkov 추가 |
| SEC-507 | prod 이미지는 다이제스트로 핀닝한다 | ❌ | 태그까지만 (G37) |
| SEC-508 | 워크로드는 사설 레지스트리에서만 이미지를 가져온다 | ❌ | `registry.oneinchmarket.co.kr` 참조 0건, `imagePullSecrets` 없음 |
| SEC-509 | 취약점 결과를 단일 조회 지점에 통합한다 | 🎯 | DefectDojo + Policy Reporter |
| SEC-510 | 취약점 SLA를 정의·추적한다 (CRITICAL 7일 / HIGH 30일) | 🎯 | DefectDojo |
| SEC-511 | 메시징 계층 구성요소는 OSI 승인 라이선스를 사용한다 | 🎯 | Confluent → Apicurio·Strimzi Bridge (ADR-032) |
| SEC-512 | 런타임에 외부에서 바이너리·드라이버를 내려받지 않는다 | ❌ | Hive Metastore JDBC 드라이버 |

### SEC-6xx — 호스트 · IaC

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-601 | 프로바이더 방화벽이 실제 인스턴스에 부착된다 | ❌ | Hetzner 미부착 (G28) — ADR-019로 제거 |
| SEC-602 | SSH는 인터넷에 전면 노출하지 않는다 | 🔶 | Vultr는 bastion만, Hetzner는 `0.0.0.0/0` |
| SEC-603 | tfstate는 원격 백엔드에 잠금과 함께 저장한다 | ❌ | `backend "local"` (TODO-08) |
| SEC-604 | WireGuard 피어를 개인별로 발급·회수할 수 있다 | ❌ | 단일 하드코딩 피어 |
| SEC-605 | 호스트 하드닝 벤치마크를 정기 점검한다 | 🎯 | Wazuh SCA / OpenSCAP |
| SEC-606 | 컨테이너 이미지는 재현 가능한 태그를 사용한다 | ❌ | `fedora:rawhide` (TODO-38) |

### SEC-7xx — 감사 · 검증

| ID | 요구사항 | 상태 | 구현 위치 / 비고 |
|---|---|:-:|---|
| SEC-701 | CIS Kubernetes Benchmark를 정기 실행한다 | ✅ | `01-kube-bench.yaml` |
| SEC-702 | 매니페스트 정적 보안 점수를 검증한다 | ✅ | `02-kubesec-scan.sh` |
| SEC-703 | 로테이션 dry-run과 연쇄 재시작을 검증한다 | ✅ | `04-rotation-dryrun.sh` |
| SEC-704 | Kyverno 정책 위반 리포트를 확인한다 | ✅ | `05-kyverno-audit.sh` |
| SEC-705 | 런타임 탐지 규칙을 실제 트리거로 검증한다 | ✅ | `06-falco-test.yaml` |
| SEC-706 | NetworkPolicy 허용·차단을 실트래픽으로 검증한다 | 🔶 | **정책 이름 오류로 항상 MISS (G33)** |
| SEC-707 | age 키 보관 상태를 검증한다 | 🔶 | **오늘 실행 시 전부 FAIL (G33)** |
| SEC-708 | RBAC 최소권한을 감사한다 | ✅ | `09-rbac-audit.sh` |
| SEC-709 | 클러스터 포스처를 프레임워크 기준으로 점검한다 | 🎯 | Kubescape |
| SEC-710 | 네트워크 플로우 드롭 원인을 추적할 수 있다 | 🎯 | Hubble + ztunnel 로그 |
| SEC-711 | 적대적 시뮬레이션으로 탐지 스택 유효성을 검증한다 | 🎯 | Caldera — **dev/local 전용, prod 금지** |
| SEC-712 | 시뮬레이션 실행 창을 SIEM 알림 규칙에 등록해 실사고와 구분한다 | 🎯 | ADR-030 |

**총 68건 — 충족 18 · 부분 12 · 미충족 20 · 목표 18.**

---

## 9. 검증 스위트 매핑

| 스크립트 | 검증하는 SEC ID |
|---|---|
| `01-kube-bench.yaml` | SEC-701 |
| `02-kubesec-scan.sh` | SEC-001~006, SEC-702 |
| `03-trivy-scan.sh` | SEC-501, SEC-506 |
| `04-rotation-dryrun.sh` | SEC-403, SEC-406, SEC-703 |
| `05-kyverno-audit.sh` | SEC-001~003, SEC-008, SEC-704 |
| `06-falco-test.yaml` | SEC-301, SEC-705 |
| `07-netpol-test.sh` | SEC-101~103, SEC-706 **(수정 필요)** |
| `08-age-key-backup.sh` | SEC-404, SEC-405, SEC-411, SEC-707 |
| `09-rbac-audit.sh` | SEC-201~204, SEC-708 |
| **신규 10** | SEC-108 — ambient 우회 탐지 |
| **신규 11** | SEC-709 — Kubescape 포스처 |
| **신규 12** | SEC-710 — Hubble 플로우 / 드롭 교차 확인 |
| **신규 13** | SEC-711 — Caldera 시나리오 실행 |
| **신규 14** | SEC-412 — Gitleaks 이력 스캔 |
| **신규 15** | SEC-504 — SBOM 존재 검증 |
| **신규 16** | SEC-014 — `verifyImages` 정책 동작 검증 |

---

## 관련 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 데이터 흐름, 갭 목록(G1~G41), TODO
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 보안 속성
- [DEPLOYMENT.md](./DEPLOYMENT.md) — 배포 블로커, INFRA 요구사항
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — 보안 관련 결정 근거
