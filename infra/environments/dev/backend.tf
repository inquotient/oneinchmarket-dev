# State 저장소 설정
# 로컬 backend (초기 설정)
# 프로덕션 전환 시 S3-compatible backend 권장
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
