# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OneinchMarket Infrastructure (v2) — a Kubernetes-based data lakehouse platform running on k3s (Hetzner Cloud). GitOps-managed, security-hardened infrastructure. The `v2` branch is the active development branch; `main` holds legacy v1 code.

**v1 → v2 migration**: Hadoop/HBase/Hive/ZooKeeper replaced with MinIO/Trino/Iceberg/Kafka KRaft. Raw YAML replaced with Kustomize + ArgoCD GitOps. SOPS+age secrets added.

## Key Commands

```bash
# Validate manifests (primary way to check changes)
kustomize build kubernetes/overlays/dev
kustomize build kubernetes/overlays/prod

# Strict schema validation
kustomize build kubernetes/overlays/dev | kubeconform -strict -summary

# OpenTofu (IaC)
cd infra/environments/dev && tofu init && tofu plan

# Security verification suite
cd scripts/security-verification && ./run-all.sh [namespace]
```

## Architecture

### Repository Layout

- `kubernetes/base/` — Kustomize base manifests organized by category
- `kubernetes/overlays/dev/` and `overlays/prod/` — Environment-specific patches
- `infra/` — OpenTofu IaC with multi-provider modules (Hetzner + Vultr)
- `argocd/` — ArgoCD projects, applications, and Argo Events definitions
- `scripts/security-verification/` — Phase 7 security test suite (9 checks)
- `v1/` — Legacy manifests, **reference only, never deploy these**

### Service Categories (ArgoCD Sync Wave Order)

| Wave | Category | Key Services |
|:---:|---|---|
| 0 | network-policies, service-mesh, security | Default-deny NetPols, Istio Ambient mTLS, Kyverno policies, namespaces |
| 1 | database | PostgreSQL, MariaDB, MongoDB, Redis Cluster |
| 2 | messaging | Kafka KRaft (3-node), Apicurio Schema Registry, AKHQ |
| 3 | data-lakehouse | MinIO, Trino, Hive Metastore |
| 5 | devops | GitLab EE |
| 6 | application | Admin, Common API, Nginx |
| 7 | observability | Elasticsearch (ECK 3-node), Kibana, Logstash, Filebeat, Falco, Trivy CronJob |
| 8 | rotation | Secret rotation CronJobs + git-sync |

### Key Technology Choices

- **No Helm** — all manifests are hand-authored YAML managed by Kustomize
- **Kafka KRaft mode** — no ZooKeeper dependency
- **Istio Ambient mode** — no sidecar injection; uses ztunnel + waypoint proxy
- **ECK operator** — Elasticsearch/Kibana use `elasticsearch.k8s.elastic.co/v1` CRDs
- **Multi-provider IaC** — `infra/modules/` support Hetzner and Vultr via count-based switching

### Security Layers

1. **Admission**: 6 Kyverno ClusterPolicies (disallow-root, disallow-latest, disallow-privilege-escalation, require-labels, require-probes, require-resources)
2. **Network**: Default-deny NetworkPolicies + Istio AuthorizationPolicies (mTLS STRICT)
3. **Runtime**: Falco DaemonSet → Falcosidekick → Elasticsearch/Slack/Kafka
4. **Supply Chain**: Trivy scans in CI + weekly CronJob; Cosign image signing

## Dev vs Prod

| Concern | Dev | Prod |
|---|---|---|
| Namespace | `dev` | `prod` |
| Replicas | Reduced (Kafka: 1, Redis: 1) | HA (PostgreSQL: 2, MongoDB: 3, etc.) |
| Image tags | `latest` | Pinned versions (set in `overlays/prod/kustomization.yaml` `images:` block) |
| Kyverno `disallow-latest` | audit | enforce |
| PodDisruptionBudgets | None | All stateful services |
| CI deploy | Auto on `v2` branch | Manual gate (`when: manual`) |

## Manifest Conventions

### File Naming

Each service directory: `<service>-statefulset.yaml` (or `-deployment.yaml`/`-daemonset.yaml`), `<service>-headless.yaml`, `<service>-service.yaml`, `<service>-configmap.yaml`, `<service>-secret.enc.yaml`, `kustomization.yaml`.

### Required Labels

```yaml
app.kubernetes.io/name: <service>
app.kubernetes.io/component: <category>
app.kubernetes.io/part-of: oneinchmarket
app.kubernetes.io/managed-by: kustomize
```

### Required Security Context (all workloads)

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

### Annotations

- `reloader.stakater.com/auto: "true"` — enables auto-restart on Secret/ConfigMap change
- `argocd.argoproj.io/sync-wave: "<N>"` — set via `commonAnnotations` in category `kustomization.yaml`

## Secret Management

- SOPS + age encryption. Path regex: `kubernetes/.*\.enc\.yaml$` (configured in `.sops.yaml`)
- Encrypted files committed as `*.enc.yaml`; decrypted `*.dec.yaml` is gitignored
- ArgoCD uses `kustomize-sops` CMP plugin with age key from `sops-age` K8s secret
- Rotation CronJobs run bi-monthly; `rotation-git-sync` CronJob re-encrypts and commits back to `v2`

```bash
# Encrypt
sops --encrypt --age <PUBLIC_KEY> --input-type yaml --output-type yaml \
  input.dec.yaml > output.enc.yaml

# Decrypt (for local inspection only, never commit .dec.yaml)
sops --decrypt secret.enc.yaml > secret.dec.yaml
```

## CI/CD Pipeline (.gitlab-ci.yml)

Stages: `validate` → `build` → `scan` → `sign` → `mirror` → `deploy`

- **validate**: `kustomize build` + `kubeconform` on `kubernetes/**/*` changes
- **build**: Docker build for `inquotient/admin` and `inquotient/cmmn-api`
- **scan**: Trivy image/config/filesystem scans
- **sign**: Cosign image signing (after Trivy passes)
- **mirror**: Skopeo mirroring of upstream images (scheduled only)
- **deploy**: ArgoCD sync — dev auto, prod manual

Registry: `registry.oneinchmarket.co.kr`

## Gotchas

- `v1/` directory is legacy — never apply these manifests to a cluster
- Prod images must use pinned tags (Kyverno enforces `disallow-latest`)
- Dev overlay `secrets/` directory is empty; secrets live at base level
- Never commit `*.dec.yaml`, `keys.txt`, `*.age`, TLS certs, or `*.tfstate`
- The ArgoCD repo URL is `https://gitlab.oneinchmarket.co.kr/infra/oneinchmarket-infra.git` on branch `v2`
