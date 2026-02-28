# Prod 환경 State 저장소
# S3-compatible backend (MinIO 또는 클라우드 오브젝트 스토리지) 권장
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # S3 backend 전환 시:
  # backend "s3" {
  #   bucket         = "oneinchmarket-tfstate"
  #   key            = "prod/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}
