# OneinchMarket v2 인프라 아키텍처 계획서

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [현재 상태 진단](#2-현재-상태-진단)
3. [스택 전환 설계](#3-스택-전환-설계)
4. [프로젝트 구조 (v2)](#4-프로젝트-구조-v2)
5. [OpenTofu 멀티 프로바이더](#5-opentofu-멀티-프로바이더)
6. [보안 설계](#6-보안-설계)
7. [비밀번호 자동 로테이션](#7-비밀번호-자동-로테이션)
8. [컨테이너 보안 4계층 방어](#8-컨테이너-보안-4계층-방어)
9. [리소스 총합 및 비용 산정](#9-리소스-총합-및-비용-산정)
10. [작업 계획](#10-작업-계획)

---

## 1. 프로젝트 개요

### 현재 프로젝트

- **위치**: `/mnt/c/Users/sfau2/OneDrive/Desktop/oneinchmarket/infra/dev/oneinchmarket-dev/`
- **내용**: Kubernetes 매니페스트(YAML) 153개 파일, ~40개 서비스
- **용도**: 로컬 개발 환경
- **브랜치**: `main` (현재 버전 유지) → `v2` (신규 브랜치로 개편)

### 핵심 기술 결정 사항

| 결정 | 현재 (v1) | 변경 (v2) |
|------|----------|----------|
| 데이터 플랫폼 | Hadoop HDFS + HBase + Hive | **MinIO + Trino + Iceberg** |
| 메시지 코디네이션 | ZooKeeper | **제거** (Kafka KRaft 모드) |
| 접근제어 | Ranger + DS389/LDAP | **제거** (Hadoop 전용이었음) |
| Schema Registry | Confluent Schema Registry | **Apicurio Registry** |
| Kafka UI | Kafka-UI | **AKHQ** |
| Git 호스팅 | GitLab Self-hosted | GitLab Self-hosted (유지) |
| GitOps | 수동 배포 | **ArgoCD** |
| Service Mesh | 없음 | **Istio Ambient Mode** |
| SIEM | 없음 | **ELK (ES×3 + Kibana×2 + Logstash×2 + Filebeat)** |
| IaC | 없음 | **OpenTofu** (Terraform 호환, MPL 2.0 라이선스) |
| K8s 매니페스트 | Raw YAML | **Kustomize** (base + overlay) |
| Secret 관리 | ConfigMap 평문 | **SOPS + age** |
| 컨테이너 보안 | 없음 | **Trivy + Cosign + Kyverno + Falco** |
| 비밀번호 로테이션 | 없음 | **CronJob 자동화 (30일/90일 주기)** |
| 클라우드 | 없음 | **Hetzner** (Vultr 이식성 확보) |
| K8s 배포판 | 없음 | **k3s** |

---

## 2. 현재 상태 진단

### Critical (즉시 수정 필요)

| # | 이슈 | 영향 범위 | 상세 |
|---|------|---------|------|
| 1 | **ConfigMap에 평문 비밀번호** | 13개 서비스 | PostgreSQL: `rPLUQxANR6WQPgVtKJEqBOBjT44cvtS6`, Keycloak: admin/db/store 3개, MariaDB, MongoDB, Redis(`ALLOW_EMPTY_PASSWORD=yes`), GitLab 등 |
| 2 | **root로 실행되는 컨테이너** | 20+ 컨테이너 | PostgreSQL(`runAsUser: 0`), Redis(`runAsUser: 0`), MongoDB, MariaDB, Kafka 등 |
| 3 | **특권 컨테이너** | 3개 | securityContext 없이 실행 |
| 4 | **NetworkPolicy 없음** | 전체 클러스터 | Pod간 무제한 통신 허용 |

### High (조기 수정 권장)

| # | 이슈 | 영향 범위 | 상세 |
|---|------|---------|------|
| 5 | **리소스 제한 없음** | 35+ 컨테이너 | requests/limits 미설정 → 노이지 네이버 문제 |
| 6 | **Health Probe 없음** | 35/38 서비스 | liveness/readiness/startup 프로브 미설정 |
| 7 | **:latest 이미지 태그** | 24개 이미지 | `keycloak/keycloak:latest`, `bitnami/postgresql:latest` 등 (Kafka 4.1.1은 핀닝 양호) |
| 8 | **단일 레플리카 SPOF** | 26개 서비스 | `replicas: 1`로 장애 시 서비스 중단 |
| 9 | **NodePort 남용** | 30개 서비스 | 대부분 ClusterIP로 충분 |

### Medium (개선 권장)

| # | 이슈 | 상세 |
|---|------|------|
| 10 | PodDisruptionBudget 없음 | 노드 유지보수 시 가용성 보장 불가 |
| 11 | 표준 레이블 미사용 | `app.kubernetes.io/*` 미적용 |
| 12 | securityContext 미흡 | `allowPrivilegeEscalation`, `capabilities`, `readOnlyRootFilesystem` 미설정 |

---

## 3. 스택 전환 설계

### Hadoop → MinIO Data Lakehouse

**제거 (29 pods)**:

| 서비스 | Pod 수 |
|--------|:------:|
| hadoop-namenode | 2 |
| hadoop-datanode | 3 |
| hadoop-journalnode | 3 |
| hadoop-rbf-router | 1 |
| hbase-hmaster | 2 |
| hbase-regionserver | 3 |
| hive-server | 1 |
| zookeeper | 3 |
| solr | 1 |
| knox | 1 |
| ranger-admin | 1 |
| ranger-usersync | 1 |
| ds389 | 1 |
| kerberos | 1 |
| freeipa | 1 |
| lam | 1 |
| schema-reg | 1 |
| kafka-ui | 1 |

**추가 (3-4 pods)**:

| 서비스 | 역할 | Pod 수 |
|--------|------|:------:|
| MinIO | 오브젝트 스토리지 (HDFS 대체) | 1 |
| Trino | 분산 쿼리 엔진 (Hive Server 대체) | 1 |
| Hive Metastore | 메타데이터 관리 (기존 유지, S3A 설정) | 1 |

### Hive Metastore 설정 변경

```diff
- <name>hive.metastore.warehouse.dir</name>
- <value>hdfs://hdfs-ns-kr/warehouse/tables</value>
+ <name>hive.metastore.warehouse.dir</name>
+ <value>s3a://warehouse/tables</value>
+ <name>fs.s3a.endpoint</name>
+ <value>http://minio-headless:9000</value>
```

### 최종 서비스 목록 (v2)

| 카테고리 | 서비스 | Pod 수 |
|---------|--------|:------:|
| Data Lakehouse | MinIO, Trino, Hive Metastore | 3 |
| Messaging | Kafka KRaft ×3, Apicurio, AKHQ | 5 |
| Database | PostgreSQL ×2, MongoDB ×3, MariaDB ×2, Redis ×6 | 13 |
| Security/Auth | Keycloak ×2 | 2 |
| Observability | ES ×3, Kibana ×2, Logstash ×2, Filebeat DS | 7+DS |
| DevOps | GitLab, ArgoCD (×10), GitLab Runner | 12 |
| Application | Admin, CMMN-API, Nginx ×2 | 4 |
| Service Mesh | istiod, ztunnel DS, waypoint ×2 | 3+DS |
| Container Security | Kyverno ×2, Falco DS, Falcosidekick | 3+DS |
| Operations | Stakater Reloader | 1 |
| **합계** | | **53 + DS** |

---

## 4. 프로젝트 구조 (v2)

```
oneinchmarket-infra/           # v2 브랜치
│
├── infra/                     # Layer 1: OpenTofu (IaaS)
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── terraform.tfvars    # provider = "hetzner"
│   │   │   └── backend.tf
│   │   └── prod/
│   │       └── terraform.tfvars    # provider = "vultr" (미래)
│   ├── modules/
│   │   ├── compute/               # 프로바이더 추상화
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   ├── hetzner/
│   │   │   └── vultr/
│   │   ├── network/
│   │   │   ├── hetzner/
│   │   │   └── vultr/
│   │   ├── dns/
│   │   │   ├── hetzner/
│   │   │   └── vultr/
│   │   ├── storage/
│   │   │   ├── hetzner/
│   │   │   └── vultr/
│   │   └── bastion/
│   │       └── wireguard.tf
│   └── scripts/
│       ├── bootstrap-k3s.sh
│       ├── install-istio.sh
│       ├── install-argocd.sh
│       └── install-reloader.sh
│
├── kubernetes/                # Layer 2: Kustomize (K8s 매니페스트)
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── data-lakehouse/    # MinIO, Trino, Hive Metastore
│   │   ├── messaging/         # Kafka, Apicurio, AKHQ
│   │   ├── database/          # PostgreSQL, MongoDB, MariaDB, Redis
│   │   ├── security/          # Keycloak, Kyverno 정책, Falco 규칙
│   │   ├── observability/     # ES, Kibana, Logstash, Filebeat
│   │   ├── devops/            # GitLab, ArgoCD
│   │   ├── application/       # Admin, CMMN-API, Nginx
│   │   ├── service-mesh/      # Istio 설정
│   │   ├── network-policies/  # NetworkPolicy
│   │   └── rotation/          # 비밀번호 로테이션 CronJob
│   └── overlays/
│       ├── dev/
│       │   ├── kustomization.yaml
│       │   ├── patches/
│       │   └── secrets/       # SOPS 암호화된 Secret
│       └── prod/
│           ├── kustomization.yaml
│           ├── patches/
│           └── secrets/
│
├── argocd/                    # Layer 3: GitOps
│   ├── projects/
│   │   └── oneinchmarket.yaml
│   ├── applications/
│   │   ├── dev.yaml
│   │   └── prod.yaml
│   └── events/
│       ├── kafka-eventsource.yaml
│       └── kafka-sensor.yaml
│
├── .sops.yaml                 # SOPS 암호화 설정
├── .gitlab-ci.yml             # CI/CD (Trivy, Cosign)
└── .gitignore                 # *.dec.yaml 등
```

---

## 5. OpenTofu 멀티 프로바이더

### 공통 인터페이스

```hcl
# infra/modules/compute/variables.tf
variable "provider_name" {
  type        = string
  description = "Cloud provider: hetzner or vultr"
  validation {
    condition     = contains(["hetzner", "vultr"], var.provider_name)
    error_message = "Supported providers: hetzner, vultr"
  }
}

variable "worker_count" {
  type    = number
  default = 4
}

variable "worker_spec" {
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 8, memory = 32 }
}

variable "location" {
  type        = string
  description = "Region identifier (sin, sgp, icn, etc.)"
}

variable "ssh_public_key" {
  type = string
}

variable "env" {
  type    = string
  default = "dev"
}
```

### 조건부 분기

```hcl
# infra/modules/compute/main.tf
module "hetzner" {
  source = "./hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

  worker_count = var.worker_count
  server_type  = local.hetzner_server_type
  location     = local.hetzner_location
  ssh_key      = var.ssh_public_key
  env          = var.env
}

module "vultr" {
  source = "./vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  worker_count = var.worker_count
  plan         = local.vultr_plan
  region       = local.vultr_region
  ssh_key      = var.ssh_public_key
  env          = var.env
}

locals {
  hetzner_server_type = lookup({
    "8-32"  = "ccx33"
    "16-64" = "ccx53"
    "4-16"  = "ccx23"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "ccx33")

  vultr_plan = lookup({
    "8-32"  = "vhp-8c-32gb-amd"
    "16-64" = "vhp-16c-64gb-amd"
    "4-16"  = "vhp-4c-16gb-amd"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "vhp-8c-32gb-amd")

  hetzner_location = lookup({
    "sin" = "sin"
    "sgp" = "sin"
    "fsn" = "fsn1"
  }, var.location, "sin")

  vultr_region = lookup({
    "sin" = "sgp"
    "sgp" = "sgp"
    "icn" = "icn"
  }, var.location, "sgp")
}
```

### 통일된 출력

```hcl
# infra/modules/compute/outputs.tf
output "worker_ips" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].worker_ips : module.vultr[0].worker_ips
}

output "worker_private_ips" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].private_ips : module.vultr[0].private_ips
}

output "bastion_ip" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].bastion_ip : module.vultr[0].bastion_ip
}
```

### Hetzner 구현체

```hcl
# infra/modules/compute/hetzner/main.tf
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

resource "hcloud_ssh_key" "deploy" {
  name       = "${var.env}-deploy-key"
  public_key = var.ssh_key
}

resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = "${var.env}-worker-${count.index + 1}"
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"
  ssh_keys    = [hcloud_ssh_key.deploy.id]

  labels = {
    role = "worker"
    env  = var.env
  }
}
```

### Vultr 구현체

```hcl
# infra/modules/compute/vultr/main.tf
terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

resource "vultr_ssh_key" "deploy" {
  name    = "${var.env}-deploy-key"
  ssh_key = var.ssh_key
}

resource "vultr_instance" "worker" {
  count       = var.worker_count
  label       = "${var.env}-worker-${count.index + 1}"
  plan        = var.plan
  region      = var.region
  os_id       = 2284  # Ubuntu 24.04
  ssh_key_ids = [vultr_ssh_key.deploy.id]

  tags = ["worker", var.env]
}
```

### 프로바이더 전환

```hcl
# infra/environments/dev/terraform.tfvars

# Hetzner 싱가포르 배포
provider_name = "hetzner"
location      = "sin"
worker_count  = 5
worker_spec   = { cpu = 8, memory = 32 }
env           = "dev"

# Vultr로 전환 시:
# provider_name = "vultr"
# location      = "sgp"
```

전환 절차:
```bash
# 1. terraform.tfvars에서 provider_name 변경
# 2. tofu init
# 3. tofu destroy -target=module.compute  (기존 인프라 제거)
# 4. tofu apply                           (새 인프라 생성)
# 5. ./scripts/bootstrap-k3s.sh           (k3s 설치)
# 6. ArgoCD가 자동으로 K8s 매니페스트 배포
```

> K8s 레이어(Kustomize + ArgoCD)는 IaaS와 완전히 분리되어 프로바이더 전환 시 변경 불필요

---

## 6. 보안 설계

### 6-1. Secret 관리: SOPS + age

#### 선택 근거

| | SealedSecrets | SOPS + age | External Secrets | HashiCorp Vault |
|---|---|---|---|---|
| **추가 인프라** | 컨트롤러 1개 | **없음** | 컨트롤러 + 외부 저장소 | Vault 서버 3 Pod |
| **Kustomize 연동** | kubectl 기반 | **네이티브 (KSOPS)** | Generator 플러그인 | Agent Injector |
| **IaaS 이식성** | 클러스터 의존 | **클러스터 독립** | 외부 의존 | 클러스터 내 |
| **복잡도** | 낮음 | **가장 낮음** | 중간 | 높음 |
| **비용** | 무료 | **무료** | 외부 저장소 비용 | 서버 리소스 |

#### 동작 흐름

```
개발자 PC                         Git (GitLab)                    ArgoCD + k3s
─────────                       ──────────                     ────────────────

1. 평문 secret.yaml 작성
2. sops --encrypt → 암호화
3. git push ─────────────→  암호화된 YAML 저장
                                       │
                                       └──────────→ 4. ArgoCD 감지
                                                    5. KSOPS가 age 키로 복호화
                                                    6. K8s Secret 생성 (클러스터 내부)
```

#### 설정

**age 키 생성** (1회):
```bash
age-keygen -o keys.txt
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

**SOPS 설정** (`.sops.yaml`):
```yaml
creation_rules:
  - path_regex: kubernetes/.*secret.*\.yaml$
    age: "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
```

**평문 Secret** (`.gitignore`에 추가):
```yaml
# kubernetes/base/database/postgresql-secret.dec.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
type: Opaque
stringData:
  postgresql-password: "rPLUQxANR6WQPgVtKJEqBOBjT44cvtS6"
```

**암호화 → Git 저장**:
```bash
sops --encrypt postgresql-secret.dec.yaml > postgresql-secret.enc.yaml
git add postgresql-secret.enc.yaml
```

**Kustomize + KSOPS 연동**:
```yaml
# kubernetes/base/database/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: postgresql-secret-generator
files:
  - ./postgresql-secret.enc.yaml
```

```yaml
# kubernetes/base/database/kustomization.yaml
generators:
  - ./secret-generator.yaml
resources:
  - postgresql-statefulset.yaml
  - postgresql-headless.yaml
```

**ArgoCD에 age 키 등록** (1회):
```bash
kubectl create secret generic sops-age \
  --namespace=argocd \
  --from-file=keys.txt=keys.txt
```

#### age 키 보관 정책

```
age 키 (keys.txt) 보관 위치:
├── 1차: 팀 리더 PC (로컬)
├── 2차: Bitwarden/1Password 등 팀 비밀번호 관리자
└── 3차: 오프라인 USB (금고 보관)

절대 금지:
├── Git 저장소에 커밋
├── Slack/메일로 전송
└── 서버 홈 디렉토리에 평문 보관
```

### 6-2. 보안 컨텍스트 강화

모든 컨테이너에 적용할 공통 보안 정책:

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

| 서비스 | 현재 | 수정 |
|--------|------|------|
| PostgreSQL | `runAsUser: 0` | `runAsUser: 999` (postgres) |
| Redis | `runAsUser: 0` | `runAsUser: 1001` (redis) |
| MongoDB | `runAsUser: 0` | `runAsUser: 999` (mongodb) |
| MariaDB | `runAsUser: 0` | `runAsUser: 999` (mysql) |
| Keycloak | 미설정 | `runAsUser: 1000` |
| Nginx | 미설정 | `runAsUser: 101` (nginx) |
| Kafka | `runAsUser: 0` | `runAsUser: 1000` (appuser) |
| MinIO (신규) | - | `runAsUser: 1000` |

### 6-3. 리소스 제한

| 서비스 | requests (CPU/MEM) | limits (CPU/MEM) |
|--------|--------------------|-------------------|
| PostgreSQL | 500m / 1Gi | 2000m / 4Gi |
| Keycloak | 500m / 1Gi | 2000m / 2Gi |
| Kafka Broker | 500m / 2Gi | 2000m / 4Gi |
| Elasticsearch | 1000m / 4Gi | 2000m / 8Gi |
| MinIO | 500m / 1Gi | 1000m / 2Gi |
| Trino | 500m / 2Gi | 2000m / 4Gi |
| MongoDB | 250m / 512Mi | 1000m / 2Gi |
| Redis | 100m / 256Mi | 500m / 1Gi |
| GitLab | 500m / 2Gi | 2000m / 4Gi |
| Logstash | 500m / 1Gi | 1000m / 2Gi |
| 기타 | 100m / 256Mi | 500m / 1Gi |

### 6-4. Health Probe

| 서비스 | livenessProbe | readinessProbe | startupProbe |
|--------|---------------|----------------|--------------|
| PostgreSQL | `tcpSocket: 5432` | `exec: pg_isready` | `tcpSocket: 5432`, failureThreshold: 30 |
| Keycloak | `httpGet: /health/live:8080` | `httpGet: /health/ready:8080` | failureThreshold: 60 |
| Kafka | `tcpSocket: 9092` | `exec: kafka-broker-api-versions` | failureThreshold: 30 |
| Elasticsearch | `httpGet: /_cluster/health:9200` | `httpGet: /_cluster/health?wait_for_status=yellow` | failureThreshold: 30 |
| MinIO | `httpGet: /minio/health/live:9000` | `httpGet: /minio/health/ready:9000` | - |
| Redis | `exec: redis-cli ping` | 동일 | failureThreshold: 30 |
| MongoDB | `exec: mongosh --eval "db.adminCommand('ping')"` | 동일 | failureThreshold: 30 |
| Nginx | `httpGet: /:80` | 동일 | - |
| GitLab | `httpGet: /-/liveness:80` | `httpGet: /-/readiness:80` | failureThreshold: 60 |
| Trino | `httpGet: /v1/info:8080` | 동일 | - |

### 6-5. NetworkPolicy

```yaml
# kubernetes/base/network-policies/database-netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgresql-netpol
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: keycloak
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: gitlab
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: hive-metastore
      ports:
        - port: 5432
          protocol: TCP
```

### 6-6. 표준 레이블

```yaml
metadata:
  labels:
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/instance: postgresql-dev
    app.kubernetes.io/version: "latest"
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
```

### 6-7. PodDisruptionBudget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: elasticsearch-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: elasticsearch
```

---

## 7. 비밀번호 자동 로테이션

### 아키텍처

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐     ┌──────────────┐
│  CronJob    │────→│ 1. 새 비번 생성 │────→│ 2. 서비스에 적용 │────→│ 3. Secret 갱신│
│ (30일 주기)  │     │   (openssl)   │     │ (ALTER USER 등)│     │ (kubectl patch)│
└─────────────┘     └──────────────┘     └───────────────┘     └──────┬───────┘
                                                                       │
                                          ┌──────────────┐             │
                                          │ 5. Git Push   │◄────────────┤
                                          │ (SOPS 암호화)  │     ┌──────┴───────┐
                                          └──────┬───────┘     │ 4. Reloader  │
                                                 │             │ (Pod 재시작)   │
                                                 ▼             └──────────────┘
                                          ┌──────────────┐
                                          │ ArgoCD Sync  │
                                          │ (상태 일치 확인)│
                                          └──────────────┘
```

### 서비스별 로테이션 분석

| 서비스 | 비밀번호 유형 | 변경 방법 | 의존 클라이언트 | 무중단 | 위험도 |
|--------|-------------|----------|---------------|:-----:|:-----:|
| **PostgreSQL** | DB root/user | `ALTER USER ... PASSWORD` | Keycloak, GitLab, Hive, Apicurio | Live + Two-Phase | 높음 |
| **MariaDB** | DB root/user | `ALTER USER ... IDENTIFIED BY` | Admin, CMMN-API | Live + Two-Phase | 높음 |
| **MongoDB** | DB root | `db.changeUserPassword()` | Application | Live + Two-Phase | 높음 |
| **Redis** | cluster 인증 | `CONFIG SET requirepass` (노드별) | Keycloak 세션 | Live + Two-Phase | 높음 |
| **Elasticsearch** | elastic 사용자 | `_security/user/_password` API | Kibana, Logstash, Filebeat | Live + Two-Phase | 중간 |
| **Keycloak** | admin 비번 | Admin REST API | 없음 (UI용) | **Live** | 낮음 |
| **Keycloak** | DB 접속 비번 | 환경변수 기반 | - (자기 자신) | Restart | 높음 |
| **GitLab** | admin 비번 | Rails API | 없음 (UI용) | **Live** | 낮음 |
| **GitLab** | DB 접속 비번 | 환경변수 기반 | - (자기 자신) | Restart | 높음 |
| **MinIO** | root 자격증명 | 환경변수 기반 | Trino, Hive | **Restart** 필수 | 높음 |
| **ArgoCD** | admin 비번 | `argocd account update-password` | 없음 (UI용) | **Live** | 낮음 |

### 의존관계 맵

```
PostgreSQL 비번 변경
├── keycloak-db-secret 갱신 → Keycloak 재시작
├── gitlab-db-secret 갱신 → GitLab 재시작
├── hive-db-secret 갱신 → Hive Metastore 재시작
└── apicurio-db-secret 갱신 → Apicurio 재시작

MariaDB 비번 변경
├── admin-db-secret 갱신 → Admin 재시작
└── cmmn-api-db-secret 갱신 → CMMN-API 재시작

MongoDB 비번 변경
└── app-mongo-secret 갱신 → Application 재시작

Redis 비번 변경
└── redis-secret 갱신 → Keycloak, 캐시 클라이언트 재시작

Elasticsearch 비번 변경
├── kibana-es-secret 갱신 → Kibana 재시작
├── logstash-es-secret 갱신 → Logstash 재시작
└── filebeat-es-secret 갱신 → Filebeat 재시작

MinIO 비번 변경
├── trino-s3-secret 갱신 → Trino 재시작
└── hive-s3-secret 갱신 → Hive Metastore 재시작

Keycloak/GitLab/ArgoCD Admin 비번 변경
└── 연쇄 영향 없음 (UI 로그인용)
```

### 올바른 로테이션 순서

```
❌ 잘못된 순서 (장애 발생):
1. K8s Secret 변경 → 2. Reloader가 Keycloak 재시작 →
3. Keycloak이 새 비번으로 접속 → PostgreSQL은 아직 옛날 비번 → 접속 실패!

✅ 올바른 순서 (무중단):
1. PostgreSQL에서 ALTER USER (새 비번 적용)
2. K8s Secret 변경
3. Reloader가 Keycloak Rolling Restart
4. Keycloak이 새 비번으로 접속 → 성공
```

### CronJob 예시: PostgreSQL

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rotate-postgresql-password
spec:
  schedule: "0 3 1,15 * *"    # 매월 1일, 15일 새벽 3시
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: secret-rotator
          restartPolicy: OnFailure
          containers:
            - name: rotator
              image: bitnami/postgresql:latest
              command:
                - bash
                - -c
                - |
                  set -euo pipefail

                  # 1. 새 비밀번호 생성
                  NEW_PW=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
                  echo "[1/4] 새 비밀번호 생성 완료"

                  # 2. PostgreSQL에서 비밀번호 변경
                  PGPASSWORD="$CURRENT_PASSWORD" psql \
                    -h postgresql-0.postgresql-headless \
                    -U postgres \
                    -c "ALTER USER keycloak WITH PASSWORD '${NEW_PW}';"
                  echo "[2/4] PostgreSQL keycloak 사용자 비밀번호 변경 완료"

                  # 3. K8s Secret 패치
                  NEW_PW_B64=$(echo -n "$NEW_PW" | base64 -w 0)
                  kubectl patch secret keycloak-db-secret \
                    -p "{\"data\":{\"db-password\":\"${NEW_PW_B64}\"}}"
                  echo "[3/4] K8s Secret 갱신 완료"

                  # 4. Reloader가 의존 Pod 자동 Rolling Restart
                  echo "[4/4] Stakater Reloader가 의존 Pod를 Rolling Restart합니다"
              env:
                - name: CURRENT_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: db-password
```

### 서비스별 로테이션 명령

**MariaDB**:
```bash
MYSQL_PWD="$CURRENT_PASSWORD" mysql \
  -h mariadb-0.mariadb-headless -u root \
  -e "ALTER USER 'cmmn'@'%' IDENTIFIED BY '${NEW_PW}';"
```

**MongoDB**:
```bash
mongosh "mongodb://mongodb-0.mongodb-headless:27017" \
  -u root -p "$CURRENT_PASSWORD" --authenticationDatabase admin \
  --eval "db.changeUserPassword('appuser', '${NEW_PW}')"
```

**Redis** (클러스터 전체 노드):
```bash
for i in $(seq 0 5); do
  redis-cli -h redis-${i}.redis-headless -a "$CURRENT_PASSWORD" \
    CONFIG SET requirepass "$NEW_PW"
done
```

**Elasticsearch**:
```bash
curl -s -X PUT "https://elasticsearch-0.elasticsearch-headless:9200/_security/user/elastic/_password" \
  -H "Content-Type: application/json" \
  -u "elastic:${CURRENT_PASSWORD}" \
  -d "{\"password\": \"${NEW_PW}\"}"
```

**Keycloak Admin** (API, 무중단):
```bash
TOKEN=$(curl -s -X POST "https://keycloak-0.keycloak-headless:8443/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&username=admin&password=${CURRENT_PASSWORD}&grant_type=password" \
  --insecure | jq -r '.access_token')

ADMIN_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://keycloak-0.keycloak-headless:8443/admin/realms/master/users?username=admin" \
  --insecure | jq -r '.[0].id')

curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://keycloak-0.keycloak-headless:8443/admin/realms/master/users/${ADMIN_ID}/reset-password" \
  -d "{\"type\":\"password\",\"value\":\"${NEW_PW}\",\"temporary\":false}" \
  --insecure
```

### Git Sync (GitOps 정합성)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rotation-git-sync
spec:
  schedule: "30 3 1,15 * *"    # 로테이션 30분 후
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: secret-rotator
          restartPolicy: OnFailure
          containers:
            - name: git-sync
              image: alpine/git:latest
              command:
                - sh
                - -c
                - |
                  set -euo pipefail
                  apk add --no-cache sops age kubectl

                  export SOPS_AGE_KEY_FILE=/age/keys.txt

                  git clone https://oauth2:${GIT_TOKEN}@gitlab.oneinchmarket.co.kr/infra/oneinchmarket-infra.git repo
                  cd repo && git checkout v2

                  for secret in postgresql-secret keycloak-db-secret mariadb-app-secret mongodb-app-secret redis-secret elasticsearch-secret minio-secret; do
                    kubectl get secret $secret -o yaml \
                      | kubectl neat \
                      | sops --encrypt --input-type yaml --output-type yaml /dev/stdin \
                      > kubernetes/base/secrets/${secret}.enc.yaml
                  done

                  git add -A
                  git diff --cached --quiet || {
                    git commit -m "chore: auto-rotate secrets $(date +%Y-%m-%d)"
                    git push origin v2
                  }
              volumeMounts:
                - name: age-key
                  mountPath: /age
                  readOnly: true
              env:
                - name: GIT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: gitlab-deploy-token
                      key: token
          volumes:
            - name: age-key
              secret:
                secretName: sops-age
```

### 로테이션 실행 시간 순서

```
03:00  DB 비번 변경 (PostgreSQL, MariaDB, MongoDB, Redis)
       → K8s Secret 갱신 → Reloader → 클라이언트 Pod Rolling Restart
03:10  Elasticsearch 비번 변경
       → Kibana, Logstash, Filebeat 재시작
03:15  MinIO 비번 변경
       → MinIO, Trino, Hive 재시작
03:20  Admin 비번 변경 (Keycloak, GitLab, ArgoCD)
       → 연쇄 영향 없음
03:30  Git Sync Job (SOPS 암호화 → Git Push)
       → ArgoCD 상태 정합성 확인
```

### 로테이션 주기

| 서비스 | 주기 | 이유 |
|--------|------|------|
| DB (PostgreSQL, MariaDB, MongoDB) | **30일** | 내부 전용 |
| Redis | **30일** | 내부 전용 |
| Elasticsearch | **30일** | 내부 전용 |
| MinIO | **30일** | 내부 전용 |
| Keycloak Admin | **90일** | UI 로그인용, MFA 병행 |
| GitLab Admin | **90일** | UI 로그인용, MFA 병행 |
| ArgoCD Admin | **90일** | UI 로그인용 |
| TLS 인증서 | **365일** | cert-manager 자동 갱신 권장 |

### RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-rotator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-rotator
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-rotator
subjects:
  - kind: ServiceAccount
    name: secret-rotator
roleRef:
  kind: Role
  name: secret-rotator
  apiGroup: rbac.authorization.k8s.io
```

### Stakater Reloader

모든 StatefulSet/Deployment에 어노테이션 추가:
```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

Secret 변경 → Reloader 감지 → Rolling Restart → 새 비밀번호로 재접속

---

## 8. 컨테이너 보안 4계층 방어

```
┌─────────────────────────────────────────────────────────────┐
│                    컨테이너 라이프사이클                        │
│                                                             │
│   Build         →    Store        →   Deploy      →  Run   │
│   (이미지 빌드)      (레지스트리)      (배포 허가)      (런타임)  │
│                                                             │
│   ┌──────────┐   ┌──────────┐   ┌───────────┐  ┌─────────┐ │
│   │ Trivy    │   │ GitLab   │   │ Kyverno   │  │ Falco   │ │
│   │ 취약점 스캔 │   │ Registry │   │ 정책 강제   │  │ 위협 탐지 │ │
│   │ + Cosign │   │ + 서명 검증│   │ + PSS     │  │ → ELK   │ │
│   └──────────┘   └──────────┘   └───────────┘  └─────────┘ │
│                                                             │
│   Layer 1         Layer 2        Layer 3        Layer 4     │
└─────────────────────────────────────────────────────────────┘
```

### Layer 1: 이미지 빌드 보안

#### Trivy — 이미지 취약점 스캔

| 항목 | 상세 |
|------|------|
| **도구** | Aqua Trivy (오픈소스, 무료) |
| **스캔 대상** | 컨테이너 이미지, Dockerfile, K8s 매니페스트, SBOM |
| **시점** | GitLab CI/CD 파이프라인에서 빌드 시 자동 스캔 |
| **리소스** | CLI 도구 (클러스터 리소스 불필요) |

**GitLab CI 연동**:
```yaml
# .gitlab-ci.yml
stages:
  - build
  - scan
  - deploy

image-scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --severity HIGH,CRITICAL --exit-code 1 ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}
    - trivy config --severity HIGH,CRITICAL --exit-code 1 kubernetes/
  allow_failure: false
```

**CronJob으로 운영 중 정기 스캔**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: trivy-image-scan
spec:
  schedule: "0 6 * * 1"   # 매주 월요일 06:00
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: trivy-scanner
          restartPolicy: OnFailure
          containers:
            - name: trivy
              image: aquasec/trivy:latest
              command:
                - sh
                - -c
                - |
                  kubectl get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
                    | sort -u | while read img; do
                    echo "=== Scanning: $img ==="
                    trivy image --severity HIGH,CRITICAL --format json "$img" \
                      >> /tmp/scan-report.json
                  done
                  curl -X POST "http://elasticsearch-headless:9200/trivy-reports/_doc" \
                    -H "Content-Type: application/json" \
                    -d @/tmp/scan-report.json
```

#### Cosign — 이미지 서명/검증

```bash
# 빌드 시 서명 (GitLab CI)
cosign sign --key cosign.key ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}

# 배포 시 검증 (Kyverno 정책으로 자동화)
cosign verify --key cosign.pub ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}
```

### Layer 2: 레지스트리 보안

GitLab Self-hosted 내장 Container Registry 활용:

| 정책 | 설정 |
|------|------|
| Private Registry | 외부 이미지 직접 Pull 금지, GitLab Registry 경유 |
| Pull Policy | `imagePullPolicy: Always` |
| Mirror | 외부 이미지를 GitLab Registry에 미러링 |
| 이미지 정리 | 90일 이상 미사용 이미지 자동 삭제 |

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: gitlab-registry-secret
      containers:
        - name: app
          image: registry.oneinchmarket.co.kr/infra/postgresql:latest
          imagePullPolicy: Always
```

### Layer 3: 배포 시 정책 강제

#### Kyverno 선택 근거

| | Kyverno | OPA Gatekeeper |
|---|---|---|
| **정책 언어** | YAML (K8s 네이티브) | Rego (전용 언어 학습 필요) |
| **학습 곡선** | **낮음** | 높음 |
| **이미지 서명 검증** | **내장 (Cosign 연동)** | 별도 구성 |
| **리소스** | ~256MB | ~512MB |

#### Kyverno 정책 세트

**정책 1 — root 컨테이너 차단**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-user
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-runAsNonRoot
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "컨테이너는 root로 실행할 수 없습니다"
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
```

**정책 2 — 리소스 제한 필수**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-limits
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "모든 컨테이너에 resources.requests와 resources.limits 필수"
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

**정책 3 — latest 태그 차단 (prod만)**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce    # prod: Enforce, dev: Audit
  rules:
    - name: check-image-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "latest 태그 사용 불가"
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

**정책 4 — 이미지 서명 검증**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-cosign
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.oneinchmarket.co.kr/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
```

**정책 5 — 권한 상승 차단**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privilege-escalation
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-privilege
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "allowPrivilegeEscalation은 false여야 합니다"
        pattern:
          spec:
            containers:
              - securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
```

**정책 6 — Private Registry만 허용 (prod)**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "허용된 레지스트리: registry.oneinchmarket.co.kr"
        pattern:
          spec:
            containers:
              - image: "registry.oneinchmarket.co.kr/*"
```

> dev overlay: `validationFailureAction: Audit` (경고만)
> prod overlay: `validationFailureAction: Enforce` (차단)

#### Pod Security Standards (K8s 네이티브)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

| PSS 레벨 | 적용 대상 |
|----------|---------|
| **Privileged** | `kube-system` (Istio, Falco 등 시스템 Pod) |
| **Restricted** | `dev`, `prod` namespace |

### Layer 4: 런타임 위협 탐지

#### Falco 선택 근거

| | Falco | Tetragon | KubeArmor |
|---|---|---|---|
| **원리** | eBPF syscall 모니터링 | eBPF 관찰+강제 | eBPF + LSM |
| **기능** | 탐지 전용 (알림) | 탐지 + 차단 | 탐지 + 차단 |
| **ELK 연동** | **Falcosidekick → ES 기본 지원** | 별도 구성 | 별도 구성 |
| **성숙도** | **CNCF Graduated (2016~)** | Incubating | Sandbox |

#### Falco 아키텍처

```
모든 Worker 노드
┌────────────────────────────────┐
│  Falco (DaemonSet)             │
│  ├── eBPF로 syscall 모니터링     │
│  ├── 규칙 위반 → 이벤트 생성      │
│  └── stdout / gRPC 출력         │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│  Falcosidekick (Deployment)    │
│  ├── → Elasticsearch 전송       │  ← ELK SIEM 대시보드
│  ├── → Slack/Teams 알림         │
│  └── → Kafka (선택)             │
└────────────────────────────────┘
```

#### Falco 탐지 규칙

**컨테이너 내 쉘 실행**:
```yaml
- rule: Terminal shell in container
  desc: 컨테이너 내에서 터미널 쉘이 실행됨
  condition: >
    spawned_process and container and
    proc.name in (bash, sh, zsh, ash) and
    proc.pname != healthcheck
  output: >
    쉘 실행 탐지 (user=%user.name container=%container.name
    image=%container.image.repository command=%proc.cmdline)
  priority: WARNING
  tags: [container, shell, mitre_execution]
```

**민감 파일 수정**:
```yaml
- rule: Modify sensitive files
  desc: 컨테이너 내 민감 파일 수정 시도
  condition: >
    open_write and container and
    fd.name startswith /etc and
    not proc.name in (sed, tee)
  output: >
    민감 파일 수정 (file=%fd.name container=%container.name)
  priority: ERROR
  tags: [filesystem, mitre_persistence]
```

**비정상 아웃바운드 연결**:
```yaml
- rule: Unexpected outbound connection
  desc: 허용되지 않은 외부 네트워크 연결
  condition: >
    outbound and container and
    not fd.sip in (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
  output: >
    비정상 외부 연결 (container=%container.name connection=%fd.name)
  priority: ERROR
  tags: [network, mitre_exfiltration]
```

**컨테이너 탈출 시도**:
```yaml
- rule: Container escape attempt
  desc: 컨테이너 탈출 시도 (nsenter, mount 등)
  condition: >
    spawned_process and container and
    proc.name in (nsenter, mount, unshare)
  output: >
    컨테이너 탈출 시도! (container=%container.name command=%proc.cmdline)
  priority: CRITICAL
  tags: [container, escape, mitre_privilege_escalation]
```

**암호화폐 채굴 탐지**:
```yaml
- rule: Crypto mining detection
  desc: 암호화폐 채굴 프로세스 또는 마이닝풀 연결
  condition: >
    (spawned_process and container and
     proc.name in (xmrig, minerd, minergate)) or
    (outbound and container and
     fd.sport in (3333, 4444, 5555, 8333))
  output: >
    암호화폐 채굴 의심 (container=%container.name process=%proc.name)
  priority: CRITICAL
  tags: [crypto, mining, mitre_resource_hijacking]
```

#### Falcosidekick → ELK SIEM

```yaml
config:
  elasticsearch:
    hostport: "http://elasticsearch-headless:9200"
    index: "falco-alerts"
    type: "_doc"
    minimumpriority: "warning"
  slack:
    webhookurl: "https://hooks.slack.com/services/..."
    minimumpriority: "critical"
```

Kibana 대시보드:
```
┌─────────────────────────────────────────────────────┐
│  Falco Security Dashboard                            │
│                                                      │
│  ┌────────────┐ ┌────────────┐ ┌──────────────────┐ │
│  │ CRITICAL: 0│ │ ERROR: 3   │ │ WARNING: 127     │ │
│  └────────────┘ └────────────┘ └──────────────────┘ │
│                                                      │
│  최근 이벤트                                          │
│  ─────────────────────────────────────────────       │
│  ERROR  | 민감파일수정   | keycloak-0  | /etc/passwd  │
│  WARN   | 쉘 실행       | admin-0     | /bin/bash    │
│  WARN   | 쉘 실행       | gitlab-0    | /bin/sh      │
└─────────────────────────────────────────────────────┘
```

### 보안 스택 리소스 요약

| 계층 | 도구 | 역할 | 리소스 |
|------|------|------|--------|
| Layer 1 | Trivy | 이미지 스캔 | CI/CD만 (클러스터 0) |
| Layer 1 | Cosign | 이미지 서명 | CI/CD만 (클러스터 0) |
| Layer 2 | GitLab Registry | Private Registry | GitLab에 포함 |
| Layer 3 | Kyverno | 배포 정책 강제 | Controller ~256MB |
| Layer 3 | PSS | Namespace 보안 수준 | 추가 리소스 0 |
| Layer 4 | Falco | 런타임 위협 탐지 | DaemonSet ~128MB × 노드수 |
| Layer 4 | Falcosidekick | 알림 라우팅 | Deployment ~128MB |

---

## 9. 리소스 총합 및 비용 산정

### 전체 워크로드 리소스

| 카테고리 | 서비스 | Pod 수 | CPU req | CPU lim | MEM req | MEM lim |
|---------|--------|:------:|---------|---------|---------|---------|
| **Data Lakehouse** | MinIO | 1 | 500m | 1,000m | 1Gi | 2Gi |
| | Trino | 1 | 500m | 2,000m | 2Gi | 4Gi |
| | Hive Metastore | 1 | 500m | 1,000m | 1Gi | 2Gi |
| **Messaging** | Kafka KRaft | 3 | 1,500m | 6,000m | 6Gi | 12Gi |
| | Apicurio Registry | 1 | 250m | 500m | 512Mi | 1Gi |
| | AKHQ | 1 | 250m | 500m | 512Mi | 1Gi |
| **Database** | PostgreSQL HA | 2 | 1,000m | 4,000m | 2Gi | 8Gi |
| | MongoDB RS | 3 | 750m | 3,000m | 1.5Gi | 6Gi |
| | MariaDB HA | 2 | 1,000m | 2,000m | 2Gi | 4Gi |
| | Redis Cluster | 6 | 600m | 3,000m | 1.5Gi | 6Gi |
| **Security/Auth** | Keycloak HA | 2 | 1,000m | 4,000m | 2Gi | 4Gi |
| **Observability** | Elasticsearch | 3 | 3,000m | 6,000m | 12Gi | 24Gi |
| | Kibana | 2 | 1,000m | 2,000m | 2Gi | 4Gi |
| | Logstash | 2 | 1,000m | 2,000m | 2Gi | 4Gi |
| | Filebeat | **DS** | /node | /node | /node | /node |
| **DevOps** | GitLab | 1 | 500m | 2,000m | 2Gi | 4Gi |
| | ArgoCD (전체) | 10 | 1,500m | 3,000m | 2Gi | 4Gi |
| | GitLab Runner | 1 | 250m | 1,000m | 512Mi | 1Gi |
| **Application** | Admin | 1 | 250m | 500m | 512Mi | 1Gi |
| | CMMN-API | 1 | 250m | 500m | 512Mi | 1Gi |
| | Nginx Ingress | 2 | 500m | 1,000m | 512Mi | 1Gi |
| **Service Mesh** | istiod | 1 | 500m | 1,000m | 1Gi | 2Gi |
| | ztunnel | **DS** | /node | /node | /node | /node |
| | waypoint proxy | 2 | 200m | 1,000m | 256Mi | 512Mi |
| **Container Security** | Kyverno | 2 | 300m | 700m | 384Mi | 768Mi |
| | Falco | **DS** | /node | /node | /node | /node |
| | Falcosidekick | 1 | 50m | 200m | 128Mi | 256Mi |
| **Operations** | Stakater Reloader | 1 | 100m | 200m | 128Mi | 256Mi |

### DaemonSet 리소스 (노드당)

| DaemonSet | CPU req | CPU lim | MEM req | MEM lim |
|-----------|---------|---------|---------|---------|
| Filebeat | 200m | 500m | 256Mi | 512Mi |
| ztunnel | 200m | 500m | 256Mi | 512Mi |
| Falco | 100m | 500m | 128Mi | 256Mi |
| **노드당 합계** | **500m** | **1,500m** | **640Mi** | **1,280Mi** |

### 노드 수별 총합

| 항목 | 4 Worker | 5 Worker |
|------|----------|----------|
| 고정 Pod | 53 | 53 |
| DaemonSet Pod | 12 (3×4) | 15 (3×5) |
| **총 Pod** | **65** | **68** |
| CPU requests | **19.3 vCPU** | **19.8 vCPU** |
| CPU limits | **54.1 vCPU** | **55.6 vCPU** |
| MEM requests | **46.3 GB** | **47.0 GB** |
| MEM limits | **102.7 GB** | **103.9 GB** |

### 스토리지 (PVC)

| 서비스 | 용량 |
|--------|------|
| MinIO | 200Gi |
| Elasticsearch ×3 | 300Gi |
| Kafka ×3 | 150Gi |
| Redis ×6 | 120Gi |
| MongoDB ×3 | 60Gi |
| PostgreSQL ×2 | 40Gi |
| MariaDB ×2 | 40Gi |
| Keycloak ×2 | 40Gi |
| GitLab | 50Gi |
| 기타 | 60Gi |
| **합계** | **~1,060Gi ≈ 1TB** |

### 노드 구성 옵션

노드당 시스템 오버헤드 (k3s agent + OS): ~0.7 vCPU, ~1.5GB

| 구성 | 총 CPU | 가용 CPU | CPU 오버커밋 | 총 MEM | 가용 MEM | MEM 사용률 | 로컬 디스크 | 1노드 장애 시 |
|------|--------|---------|:----------:|--------|---------|:--------:|:---------:|:----------:|
| **A) 3×16C/64GB** | 48C | 45.9C | 1.18x | 192GB | 187.5GB | 55% | 1,080GB | MEM 82% 생존 |
| **B) 4×8C/32GB** | 32C | 29.2C | 1.85x | 128GB | 122GB | 84% | 960GB | MEM 112% **위험** |
| **C) 5×8C/32GB** | 40C | 36.5C | 1.53x | 160GB | 152.5GB | 68% | 1,200GB | MEM 85% 생존 |
| **D) 4×16C/64GB** | 64C | 61.2C | 0.91x | 256GB | 250GB | 41% | 1,440GB | MEM 55% 여유 |

> CPU 오버커밋: CPU limits ÷ 가용 CPU. CPU는 throttle만 되므로 2x까지 허용 가능
> MEM 사용률: MEM limits ÷ 가용 MEM. 메모리는 OOM Kill이므로 85% 이하 권장

### 비용 산정

#### 노드 단가 (월)

| 스펙 | Hetzner EU (독일) | Hetzner SG (싱가포르, +72%) | Vultr SG (싱가포르) |
|------|:-----------------:|:-------------------------:|:-----------------:|
| 2C/8GB (Bastion) | $15 | $26 | $48 |
| 8C/32GB (Worker) | $55 | $95 | $192 |
| 16C/64GB (Worker) | $107 | $184 | $384 |

#### Option A: 3 Worker × 16C/64GB + Bastion

| | Hetzner EU | Hetzner SG | Vultr |
|---|---:|---:|---:|
| Worker ×3 | $321 | $552 | $1,152 |
| Bastion ×1 | $15 | $26 | $48 |
| **월 합계** | **$336** | **$578** | **$1,200** |
| **연 합계** | **$4,032** | **$6,936** | **$14,400** |

#### Option B: 4 Worker × 8C/32GB + Bastion

| | Hetzner EU | Hetzner SG | Vultr |
|---|---:|---:|---:|
| Worker ×4 | $220 | $380 | $768 |
| Bastion ×1 | $15 | $26 | $48 |
| 추가 스토리지 (100GB) | $5 | $9 | $10 |
| **월 합계** | **$240** | **$415** | **$826** |
| **연 합계** | **$2,880** | **$4,980** | **$9,912** |

#### Option C: 5 Worker × 8C/32GB + Bastion ← 추천

| | Hetzner EU | Hetzner SG | Vultr |
|---|---:|---:|---:|
| Worker ×5 | $275 | $475 | $960 |
| Bastion ×1 | $15 | $26 | $48 |
| **월 합계** | **$290** | **$501** | **$1,008** |
| **연 합계** | **$3,480** | **$6,012** | **$12,096** |

#### Option D: 4 Worker × 16C/64GB + Bastion

| | Hetzner EU | Hetzner SG | Vultr |
|---|---:|---:|---:|
| Worker ×4 | $428 | $736 | $1,536 |
| Bastion ×1 | $15 | $26 | $48 |
| **월 합계** | **$443** | **$762** | **$1,584** |
| **연 합계** | **$5,316** | **$9,144** | **$19,008** |

#### 전체 비교 매트릭스

| 구성 | 노드 | Hetzner EU | Hetzner SG | Vultr | 장애 내성 | 판정 |
|------|------|---:|---:|---:|:---------:|:---:|
| **A** 3×16C/64GB | 4대 | $336/mo | $578/mo | $1,200/mo | 1대 생존 | 충분한 여유 |
| **B** 4×8C/32GB | 5대 | $240/mo | $415/mo | $826/mo | **위험** | MEM 부족 위험 |
| **C** 5×8C/32GB | 6대 | **$290/mo** | **$501/mo** | **$1,008/mo** | 1대 생존 | **추천** |
| **D** 4×16C/64GB | 5대 | $443/mo | $762/mo | $1,584/mo | 1대 여유 | 확장 대비 |

#### 추천 조합

| 우선순위 | 조합 | 월 비용 | 이유 |
|---------|------|--------|------|
| **1순위** | Option C + Hetzner EU | **$290/mo** | 최적 가성비, 장애 내성 확보 |
| **2순위** | Option C + Hetzner SG | **$501/mo** | 아시아 지연시간 최소화 |
| **3순위** | Option A + Hetzner EU | **$336/mo** | 관리 노드 수 최소 |
| **참고** | Option C + Vultr | **$1,008/mo** | Vultr 필요 시 |

---

## 10. 작업 계획

### 7-Phase 실행 계획

| Phase | 작업 | 기간 | 주요 산출물 |
|-------|------|------|------------|
| **1** | 프로젝트 구조 설정, `.sops.yaml`, v2 브랜치 | 1일 | v2 브랜치, 디렉토리 구조, `.gitignore` |
| **2** | OpenTofu 멀티 프로바이더 + bootstrap 스크립트 (k3s, Istio, ArgoCD, Reloader) | 2.5일 | Hetzner/Vultr 모듈, 설치 스크립트 |
| **3** | Kustomize Base + 보안 수정 + Secret SOPS 암호화 + Kyverno 정책 + PSS | 4.5일 | 보안 강화된 매니페스트, 정책 YAML |
| **4** | Kustomize Overlay + NetworkPolicy + PDB | 1일 | dev/prod overlay, 네트워크 정책 |
| **5** | ArgoCD GitOps + 비밀번호 로테이션 CronJob + Trivy CI + Cosign + Registry 미러링 | 2.5일 | GitOps 파이프라인, 로테이션 자동화 |
| **6** | Istio Ambient + ELK SIEM + Falco + Falcosidekick | 1.5일 | mTLS, SIEM 대시보드, 위협 탐지 |
| **7** | 보안 검증 + 로테이션 테스트 + Kyverno Audit + Falco 룰 테스트 + Trivy 스캔 | 2일 | CIS 벤치마크, 보안 리포트 |
| **합계** | | **~15일** | |

### Phase 3 상세 (보안 수정 항목)

| # | 작업 | 대상 |
|---|------|------|
| 3-1 | ConfigMap 비밀번호 → SOPS 암호화 Secret | 13개 서비스 |
| 3-2 | securityContext (runAsNonRoot, capabilities drop) | 20+ 컨테이너 |
| 3-3 | resources requests/limits | 35+ 컨테이너 |
| 3-4 | liveness/readiness/startup 프로브 | 35/38 서비스 |
| 3-5 | 이미지 태그 latest 유지 (prod overlay에서 핀닝 구조) | 24개 이미지 |
| 3-6 | Hadoop → MinIO 전환 매니페스트 | 29 pods 제거, 4 pods 추가 |
| 3-7 | Kyverno 정책 6개 작성 | 클러스터 전역 |
| 3-8 | PSS Restricted 레이블 | dev/prod namespace |

### Phase 5 상세 (로테이션 + CI/CD)

| # | 작업 | 대상 |
|---|------|------|
| 5-1 | ArgoCD Application/AppProject 정의 | dev, prod |
| 5-2 | Argo Events 이관 (Kafka EventSource + Sensor) | Keycloak 이벤트 |
| 5-3 | Sync Wave 설정 (의존관계 순서) | DB → Messaging → App → Observability |
| 5-4 | 로테이션 CronJob 7개 | PostgreSQL, MariaDB, MongoDB, Redis, ES, MinIO, Admin |
| 5-5 | Git Sync CronJob | SOPS 암호화 → Git Push |
| 5-6 | Trivy CI 파이프라인 (.gitlab-ci.yml) | 이미지 + 매니페스트 스캔 |
| 5-7 | Cosign 서명 파이프라인 | 자체 빌드 이미지 |
| 5-8 | GitLab Registry 미러링 설정 | 외부 이미지 미러 |

### Phase 7 상세 (보안 검증)

| # | 작업 |
|---|------|
| 7-1 | kube-bench (CIS Benchmark) 실행 |
| 7-2 | kubesec 매니페스트 보안 점수 검증 |
| 7-3 | Trivy 이미지 CVE 스캔 |
| 7-4 | 로테이션 dry-run + 의존관계 연쇄 재시작 검증 |
| 7-5 | Kyverno Audit 리포트 확인 |
| 7-6 | Falco 규칙 테스트 (쉘 실행, 파일 수정 시뮬레이션) |
| 7-7 | NetworkPolicy 허용/차단 트래픽 검증 |
| 7-8 | age 키 백업 검증 |
| 7-9 | RBAC 최소 권한 검증 |

---

## ArgoCD Application 참고

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oneinchmarket-dev
  namespace: argocd
spec:
  project: oneinchmarket
  source:
    repoURL: https://gitlab.oneinchmarket.co.kr/infra/oneinchmarket-infra.git
    targetRevision: v2
    path: kubernetes/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## MinIO StatefulSet 참고

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
spec:
  serviceName: minio-headless
  replicas: 1
  template:
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits: { cpu: "1000m", memory: "2Gi" }
          livenessProbe:
            httpGet: { path: /minio/health/live, port: 9000 }
          readinessProbe:
            httpGet: { path: /minio/health/ready, port: 9000 }
```

---

*문서 작성일: 2026-02-28*
*프로젝트: OneinchMarket Infrastructure v2*
