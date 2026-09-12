#!/usr/bin/env python3
"""slo/*.yaml(Sloth 명세)에서 Pyrra 의 ServiceLevelObjective 를 생성한다.

★★★ 왜 이 스크립트가 있는가 -- 2026-09-12 에 **원천이 둘이고 이미 어긋나 있는
  것**을 발견했다. 같은 SLO(ingress 게이트웨이의 5xx 비율)를 두 파일이 각자
  적고 있었다:
      slo/gateway.yaml                     Sloth 명세. 기간 30d(기본값)
      pyrra.yaml 의 pyrra-slos ConfigMap   Pyrra CR.  기간 4w(=28d)
  목표(99%)는 같은데 **기간이 달라서 오차 예산이 다르다.** 어느 쪽도 틀렸다고
  말해 주지 않는다 -- Gotcha 71 이 요금제와 쿼터에서 경고한 것과 같은 모양이다.

★ 그래서 원천을 `slo/*.yaml` 하나로 두고 Pyrra CR 을 여기서 **생성**한다.
  손으로 고치지 말 것 -- 마커 사이는 매번 덮어쓴다.

★★ Pyrra 의 규칙은 Prometheus 에 넣지 않는다(그래서 이 스크립트는 CR 만 만든다).
  Sloth 가 만든 규칙이 이미 `prometheus-rules` ConfigMap 에 들어가 있고, Pyrra
  규칙을 함께 넣으면 **같은 값을 다른 이름으로 두 번 계산**하게 된다
  (`slo:sli_error:ratio_rate5m` 대 `istio_requests:burnrate5m`).
  그러면 "오차 예산이 얼마인가" 에 답이 둘이 된다 -- 고치려던 결함을 규칙
  계층에서 되살리는 셈이다. Pyrra 는 **UI** 로만 쓰고 원시 지표에서 계산한다.
  복귀 조건: Pyrra UI 가 느려서 못 쓸 정도가 되면 그때 Pyrra 규칙을 넣되
  **Sloth 쪽을 빼고** 넣을 것. 둘을 동시에 두지 말 것.

사용
  local/slo-to-pyrra.py <pyrra.yaml> <slo 디렉터리>
  local/slo-to-pyrra.py <pyrra.yaml> <slo 디렉터리> --check   # 뒤처졌으면 1
"""
import io, os, sys, glob

NL = chr(10)
BEGIN = "  # >>> slo-generated -- local/render-slo.sh 가 쓴다. 손으로 고치지 말 것"
END = "  # <<< slo-generated"


def die(msg):
    sys.stderr.write("[pyrra] " + msg + NL)
    sys.exit(1)


def parse_sloth(path):
    """Sloth 명세에서 필요한 것만 뽑는다.

    ★ yaml 모듈에 기대지 않는다 -- 이 스크립트는 노드에서도 CI 에서도 돌아야
      하는데 PyYAML 이 없는 자리가 있다(Gotcha 56 과 같은 부류). 대신
      **읽어낸 값이 전부 채워졌는지 검사**하고 하나라도 비면 죽는다.
    """
    txt = io.open(path, encoding="utf-8").read()
    out = {"service": None, "name": None, "objective": None,
           "description": None, "error_query": None, "total_query": None,
           "owner": None,
           # ★ Sloth 명세에 period 를 적지 않으면 기본이 30d 다(실측: 생성된
           #   규칙이 ratio_rate30d 를 쓴다). Pyrra 쪽에는 4w(=28d)로 적혀
           #   있었고 그것이 두 원천이 어긋나 있던 자리다.
           "period": "30d"}
    for raw in txt.split(NL):
        line = raw.strip()
        for key, prefix in (("service", "service:"), ("name", "- name:"),
                            ("objective", "objective:"),
                            ("description", "description:"),
                            ("error_query", "error_query:"),
                            ("total_query", "total_query:"),
                            ("owner", "owner:")):
            if line.startswith(prefix) and out[key] is None:
                v = line[len(prefix):].strip()
                if len(v) >= 2 and v[0] == chr(34) and v[-1] == chr(34):
                    v = v[1:-1]
                out[key] = v
    # ★ 목표값 표기를 맞춘다 -- Sloth 는 99.0, Pyrra CR 에는 99 로 적혀 있었다.
    #   같은 값이지만 문자열이 다르면 --check 가 매번 다르다고 말한다.
    if out["objective"] is not None and out["objective"].endswith(".0"):
        out["objective"] = out["objective"][:-2]
    missing = [k for k, v in out.items() if v is None]
    if missing:
        die(os.path.basename(path) + ": 읽어내지 못한 항목 " + ",".join(missing))
    # ★ Sloth 의 쿼리에는 {{.window}} 템플릿이 들어 있다. Pyrra 는 지표만
    #   받으므로 rate(...[{{.window}}]) 껍데기를 벗겨 안쪽 셀렉터만 남긴다.
    for k in ("error_query", "total_query"):
        v = out[k]
        head = "sum(rate("
        if not v.startswith(head):
            die(k + ": 예상한 모양이 아니다 -> " + v)
        inner = v[len(head):]
        cut = inner.find("[{{.window}}]")
        if cut < 0:
            die(k + ": {{.window}} 를 못 찾았다 -> " + v)
        out[k] = inner[:cut]
    return out


def render(specs):
    lines = [BEGIN]
    for s in specs:
        nm = s["service"] + "-" + s["name"]
        lines.append("  " + nm + ".yaml: |")
        lines.append("    apiVersion: pyrra.dev/v1alpha1")
        lines.append("    kind: ServiceLevelObjective")
        lines.append("    metadata:")
        lines.append("      name: " + nm)
        lines.append("      namespace: local")
        lines.append("      labels:")
        lines.append("        pyrra.dev/team: " + s["owner"])
        lines.append("    spec:")
        lines.append('      target: "' + s["objective"] + '"')
        # ★ 기간을 Sloth 와 맞춘다. 이것이 어긋나 있던 값이다(4w 대 30d).
        lines.append("      window: " + s["period"])
        lines.append('      description: "' + s["description"] + '"')
        lines.append("      indicator:")
        lines.append("        ratio:")
        lines.append("          errors:")
        lines.append("            metric: " + s["error_query"])
        lines.append("          total:")
        lines.append("            metric: " + s["total_query"])
    lines.append(END)
    return NL.join(lines)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if len(args) != 2:
        die("사용: slo-to-pyrra.py <pyrra.yaml> <slo 디렉터리> [--check]")
    dest, srcdir = args
    files = sorted(glob.glob(os.path.join(srcdir, "*.yaml")))
    if not files:
        die(srcdir + ": SLO 명세가 0건이다")
    specs = [parse_sloth(f) for f in files]
    block = render(specs)

    old = io.open(dest, encoding="utf-8").read()
    if BEGIN not in old or END not in old:
        die(os.path.basename(dest) + ": 마커가 없다 -- BEGIN/END 를 먼저 넣을 것")
    head = old.split(BEGIN, 1)[0]
    tail = old.split(END, 1)[1]
    new = head + block + tail

    if check:
        if new != old:
            die("Pyrra CR 이 slo/ 와 다르다 -- local/render-slo.sh 를 돌리고 커밋할 것")
        print("[pyrra] Pyrra CR 이 slo/ 와 같다")
        return
    if new == old:
        print("[pyrra] 변화 없음 (SLO " + str(len(specs)) + "건)")
        return
    io.open(dest, "w", encoding="utf-8", newline="").write(new)
    print("[pyrra] Pyrra CR 갱신 (SLO " + str(len(specs)) + "건)")


if __name__ == "__main__":
    main()
