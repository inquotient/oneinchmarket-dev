# OneinchMarket Infrastructure (v2)

Kubernetes 기반 데이터 레이크하우스 플랫폼의 인프라 코드 저장소입니다.

## 구조

```
├── infra/              # OpenTofu IaC (Hetzner/Vultr)
│   ├── environments/   # dev / prod 환경별 설정
│   ├── modules/        # compute, network, dns, storage, bastion
│   └── scripts/        # 프로비저닝 스크립트
├── kubernetes/         # Kustomize 매니페스트
│   ├── base/           # 공통 베이스 매니페스트
│   └── overlays/       # dev / prod 오버레이
├── argocd/             # ArgoCD 앱 정의 및 이벤트
│   ├── projects/
│   ├── applications/
│   └── events/
└── v1/                 # 레거시 v1 매니페스트 (참조용)
```

## Kubernetes 서비스 카테고리

| 카테고리 | 서비스 |
|----------|--------|
| Data Lakehouse | Hadoop, HBase, Hive, Solr |
| Messaging | Kafka (KRaft), Schema Registry, Kafka REST |
| Database | MariaDB, PostgreSQL, MongoDB, Redis |
| Security | Keycloak, Kerberos, Ranger, Knox |
| Observability | ELK Stack, AKHQ |
| DevOps | GitLab, Jenkins, ArgoCD |
| Application | Admin, Common API |

## 시작하기

```bash
# Dev 환경 매니페스트 빌드
kustomize build kubernetes/overlays/dev/

# Prod 환경 매니페스트 빌드
kustomize build kubernetes/overlays/prod/
```

## 시크릿 관리

SOPS + age를 사용하여 시크릿을 암호화합니다. `.sops.yaml` 참조.
