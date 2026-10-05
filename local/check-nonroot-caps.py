#!/usr/bin/env python3
"""비-root 컨테이너에 적힌 capability 를 전수로 찾는다 — 그것은 전부 무력하다.

★★★ 왜 필요한가 (2026-10-06 실측)
  `databases-migrate` 의 `git` 초기화 컨테이너가 `chown: Operation not
  permitted` 로 죽어 OpenReplay 스키마가 만들어지지 않았고, 그 증상은 엉뚱한
  곳(`chalice-openreplay` 의 `relation "public.tenants" does not exist`)에
  나왔다. 원인은 설정 오류가 아니라 **구조**였다.

  일회성 파드로 직접 쟀다 — uid 1001 · `capabilities: {add: [CHOWN], drop: [ALL]}`:

      CapBnd: 0000000000000001   <- add 는 **bounding set** 에만 들어간다
      CapPrm: 0000000000000000
      CapEff: 0000000000000000   <- 실효 권한은 0이다
      CapAmb: 0000000000000000   <- 쿠버네티스는 ambient set 을 설정하지 않는다
      chown: Operation not permitted

  즉 **비-root 프로세스는 permitted/effective capability 를 물려받지 못한다.**
  `capabilities.add` 는 "이 컨테이너가 가질 수 **있는** 최대치" 만 넓히고,
  실제로 주지는 않는다. 파일 capability 가 붙은 바이너리이거나 ambient set 을
  쓰는 런타임이 아니면 아무 일도 일어나지 않는다.

★★★ 다만 **언제나** 무력한 것은 아니다 — 이 구분이 중요하다.
  `add` 가 넣는 자리는 **bounding set** 이고, 그것은 "이 프로세스가
  앞으로 얻을 수 있는 상한" 이다. 그래서 컨테이너가 나중에 **setuid
  바이너리**(또는 파일 capability 가 붙은 바이너리)를 실행하면, 그때
  얻을 수 있는 capability 의 상한이 바로 그 bounding set 이다.
  즉 `drop: [ALL]` 로 비운 뒤 `add` 로 되돌려 둔 것이 **필요하다.**

  가르는 것은 `allowPrivilegeEscalation` 이다:
    · `false` -> `NoNewPrivs` 가 걸려 setuid 비트가 무시된다.
      어떤 경로로도 권한을 얻을 수 없으므로 `add` 는 **확정적으로 무력**하다.
    · `true`  -> setuid 경로가 살아 있으므로 `add` 가 **뜻이 있다.**
  실측(2026-10-06, local 렌더):
      buildkit/buildkitd      uid=1000 allowPrivEsc=True  add=[SETUID,SETGID]  <- 필요하다
      databases-migrate/git   uid=1001 allowPrivEsc=False add=[CHOWN]          <- 무력하다
  앞의 것은 rootless BuildKit 이 `newuidmap`/`newgidmap` 을 부르기
  때문이다(Gotcha 149). 그래서 이 검사기는 **`allowPrivilegeEscalation`
  이 false 인 것만 결함으로 센다** — 달성할 수 없는 게이트는 없는
  게이트보다 나쁘다(Gotcha 73·90).

★ 그래서 이것은 **조용히 틀리는 설정**이다 — 매니페스트는 의도를 또렷하게
  적고 있고, 어드미션도 통과하고, 파드도 뜬다. 드러나는 것은 그 권한이 실제로
  필요한 순간뿐이고 그때의 증상은 원인과 멀다.

★★ 이 레포가 한 번 그 함정에 빠진 경로: §8-49 가 Kyverno `disallow-root` 를
  통과시키려고 root 였던 마이그레이션 Job 을 "CAP_CHOWN 으로 낮췄다". 정책은
  통과했고 chown 은 죽었다. 옛 클러스터에는 스키마가 이미 있어 아무도 아프지
  않았으므로 **재구축에서야 청구됐다**(Gotcha 166).

처방 세 가지 — 어느 것이든 이 검사를 통과한다:
  ① 그 일이 정말 필요한지 다시 묻는다(이번 경우 답은 "아니오" 였다)
  ② `fsGroup`·`volume.permissions` 로 푼다(권한이 아니라 소유권 문제일 때가 많다)
  ③ 그 일만 하는 **root 초기화 컨테이너**로 떼어낸다(권한 범위를 좁게 가둔다)

사용
  python3 local/check-nonroot-caps.py [--check] [overlay...]
  --check  : 한 건이라도 있으면 1 로 끝낸다(CI 게이트)
  overlay  : 기본값 local dev prod
"""
import json
import subprocess
import sys

try:
    import yaml
except ImportError:
    # ★ 조용히 통과시키지 않는다 — 검사기가 아무 일도 하지 않는 것이
    #   제일 나쁘다(Gotcha 84·141 과 같은 부류).
    sys.exit("PyYAML 이 필요하다: python3 -m pip install pyyaml")

POD_KINDS = {
    "Pod", "Deployment", "StatefulSet", "DaemonSet",
    "Job", "CronJob", "ReplicaSet",
}


def pod_spec(doc):
    """kind 별로 PodSpec 이 사는 자리가 다르다."""
    k = doc.get("kind")
    spec = doc.get("spec") or {}
    if k == "Pod":
        return spec
    if k == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {})
                .get("template") or {}).get("spec") or {}
    return ((spec.get("template") or {}).get("spec")) or {}


def is_nonroot(pod_sc, c_sc):
    """컨테이너 설정이 파드 설정을 덮는다."""
    for sc in (c_sc, pod_sc):
        if sc.get("runAsNonRoot") is True:
            return True
        u = sc.get("runAsUser")
        if u is not None:
            return u != 0
    return False   # 선언이 없으면 이미지 기본값 — root 일 수 있으므로 세지 않는다


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    gate = "--check" in sys.argv[1:]
    overlays = args or ["local", "dev", "prod"]

    total = 0
    for ov in overlays:
        try:
            out = subprocess.run(
                ["kubectl", "kustomize", f"kubernetes/overlays/{ov}"],
                capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError as e:
            print(f"[caps] {ov}: 렌더 실패 — {e.stderr.strip()[:160]}")
            total += 1
            continue

        hits, allowed, containers = [], [], 0
        for doc in yaml.safe_load_all(out):
            if not isinstance(doc, dict) or doc.get("kind") not in POD_KINDS:
                continue
            ps = pod_spec(doc)
            if not ps:
                continue
            pod_sc = ps.get("securityContext") or {}
            name = (doc.get("metadata") or {}).get("name", "?")
            for field in ("initContainers", "containers"):
                for c in ps.get(field) or []:
                    containers += 1
                    c_sc = c.get("securityContext") or {}
                    add = ((c_sc.get("capabilities") or {}).get("add")) or []
                    if not (add and is_nonroot(pod_sc, c_sc)):
                        continue
                    uid = c_sc.get("runAsUser", pod_sc.get("runAsUser"))
                    ape = c_sc.get("allowPrivilegeEscalation")
                    row = (doc["kind"], name, field, c.get("name"), add, uid, ape)
                    # ★ allowPrivilegeEscalation 이 true 면 setuid 경로가 살아
                    #   있어 bounding set 확장에 뜻이 있다 - 결함이 아니다.
                    (allowed if ape else hits).append(row)

        print(f"[caps] {ov:5s} 컨테이너 {containers} 건 · "
              f"무력 {len(hits)} 건 · setuid 경로로 유효 {len(allowed)} 건")
        for kind, name, field, cname, add, uid, ape in hits:
            print(f"        ★ {kind}/{name} [{field}:{cname}] uid={uid} "
                  f"allowPrivEsc=false add={add}  <- 무력하다")
        for kind, name, field, cname, add, uid, ape in allowed:
            print(f"          {kind}/{name} [{field}:{cname}] uid={uid} "
                  f"allowPrivEsc=true  add={add}  (setuid 경로 - 유효)")
        total += len(hits)

    if gate and total:
        print(f"[caps] ★ {total} 건 — 비-root 컨테이너의 capability 는 "
              f"권한을 주지 않는다. 스크립트 머리말의 처방 ①②③ 을 볼 것.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
