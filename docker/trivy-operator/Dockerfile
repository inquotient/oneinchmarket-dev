# trivy-operator 0.36.1 + 등급 결함 패치(sevfix.sh, Gotcha 221).
#
# 상류 이미지를 그대로 두고 **바이너리 하나만** 바꾼다 — 사용자(10000)·엔트리포인트·
# 베이스(alpine)가 상류와 같아야 install-operators.sh 가 적용하는 상류 매니페스트와 어긋나지 않는다.
# ★ TRIVY_OPERATOR_VERSION(install-operators.sh)을 올릴 때 이 두 FROM·태그를 함께 움직일 것.
FROM docker.io/library/golang:1.27.3 AS build
ARG VERSION=v0.36.1
WORKDIR /src
RUN git clone --depth 1 --branch "${VERSION}" https://github.com/aquasecurity/trivy-operator.git .
COPY sevfix.sh /sevfix.sh
RUN sh /sevfix.sh \
 && go test ./pkg/vulnerabilityreport/ -run 'TestSevfixFallback' -count=1 \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /trivy-operator ./cmd/trivy-operator

FROM docker.io/aquasec/trivy-operator:0.36.1
COPY --from=build /trivy-operator /usr/local/bin/trivy-operator
