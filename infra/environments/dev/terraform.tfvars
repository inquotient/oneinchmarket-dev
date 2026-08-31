# Hetzner 싱가포르 배포
# provider_name = "hetzner"
# location      = "sin"

# Vultr 배포
provider_name = "vultr"
location      = "kor"
env           = "dev"

# 노드 구성: bastion(1) + master(1) + worker(N)
# bastion: vc2-1c-1gb (WireGuard VPN 전용, 기본값)
# master: worker_spec 기반 자동 결정 (worker보다 한 단계 아래)
# worker: worker_spec 기반 결정
worker_count = 5
worker_spec  = { cpu = 8, memory = 32 }
