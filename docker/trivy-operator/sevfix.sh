#!/bin/sh
# trivy-operator 의 등급 결함을 고친다 (Gotcha 221).
#
# 상류 pkg/vulnerabilityreport/io.go 는 trivy 가 이미 정한 Severity 를 버리고
#   severity := sr.VendorSeverity[sr.SeveritySource].String()
# 로 다시 찾는다. trivy 가 등급을 vendor 표가 아닌 곳에서 정하면 SeveritySource 가 비어
# 조회가 빗나가고 UNKNOWN 이 된다. 실측 2026-11-08: Go stdlib·x/net·x/crypto·curl·openssl
# 등 리포트 78개에서 12,222건이 UNKNOWN 이었고 그중 점수로 HIGH 이상이 5,865건이었다
# (trivy CLI 는 같은 항목을 HIGH 로 낸다). 요약(summary) 집계도 이 값을 쓴다.
#
# 처방: vendor 표에 그 출처가 없으면 trivy 의 Severity 를 쓴다 — trivy CLI 와 같은 값이다.
# ★ 패치가 빗나가면 빌드를 멈춘다(Gotcha 86) — 줄이 바뀐 판에서는 이 파일을 다시 볼 것.
# ★ 상류가 고치면 이 디렉터리를 지우고 install-operators.sh 의 이미지 덮어쓰기를 걷을 것.
set -eu
f=pkg/vulnerabilityreport/io.go
old='		severity := sr.VendorSeverity[sr.SeveritySource].String()'
[ "$(grep -cxF "$old" "$f")" = 1 ] || { echo "sevfix: 대상 줄이 정확히 하나가 아니다" >&2; exit 1; }

cat > /tmp/new.txt <<'EOF'
		severity := sr.VendorSeverity[sr.SeveritySource].String()
		// oneinchmarket sevfix: fall back to trivy's own Severity when the source is not in VendorSeverity
		if _, ok := sr.VendorSeverity[sr.SeveritySource]; !ok && sr.Severity != "" {
			severity = sr.Severity
		}
EOF
awk -v old="$old" 'FNR==NR { buf = buf $0 "\n"; next } $0 == old { printf "%s", buf; next } { print }' \
  /tmp/new.txt "$f" > /tmp/io.go
mv /tmp/io.go "$f"
[ "$(grep -c 'oneinchmarket sevfix' "$f")" = 1 ] || { echo "sevfix: 패치가 들어가지 않았다" >&2; exit 1; }

# 회귀 시험 — 출처가 빈 HIGH 는 HIGH, 출처가 있는 것은 vendor 값 그대로.
cat > pkg/vulnerabilityreport/sevfix_test.go <<'EOF'
package vulnerabilityreport

import (
	"testing"

	dbtypes "github.com/aquasecurity/trivy-db/pkg/types"
	ty "github.com/aquasecurity/trivy/pkg/types"
)

func TestSevfixFallback(t *testing.T) {
	r := ty.Result{Vulnerabilities: []ty.DetectedVulnerability{
		{VulnerabilityID: "A", Vulnerability: dbtypes.Vulnerability{Severity: "HIGH",
			VendorSeverity: dbtypes.VendorSeverity{"redhat": dbtypes.SeverityMedium}}},
		{VulnerabilityID: "B", SeveritySource: "redhat", Vulnerability: dbtypes.Vulnerability{Severity: "MEDIUM",
			VendorSeverity: dbtypes.VendorSeverity{"redhat": dbtypes.SeverityMedium}}},
	}}
	v := GetVulnerabilitiesFromScanResult(r, AdditionalFields{})
	if string(v[0].Severity) != "HIGH" || string(v[1].Severity) != "MEDIUM" {
		t.Fatalf("got %s %s", v[0].Severity, v[1].Severity)
	}
}
EOF
echo "sevfix: applied"
