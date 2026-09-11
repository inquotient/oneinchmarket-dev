#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sloth 생성물을 prometheus-rules ConfigMap 안으로 넣는다.

★★★ 왜 이 단계가 필요한가 — 생성만 하면 아무도 읽지 않는다.
    Prometheus 의 rule_files 는 /etc/prometheus/rules/*.yml 이고,
    그 디렉터리에는 prometheus-rules ConfigMap 하나만 마운트된다.
    즉 규칙을 살리려면 그 ConfigMap 의 키가 되어야 한다.
★   확장자가 .yml 이어야 한다 — .yaml 로 넣으면 마운트되고도 조용히 무시된다.
★   사람이 읽는 원본은 slo/generated/ 에 그대로 남긴다(리뷰 때 diff 가 짧다).

원천은 slo/*.yaml 하나다(Gotcha 117). 이 블록을 손으로 고치면 --check 가 잡는다.

사용:  slo-to-configmap.py <configmap.yaml> <generated-dir> [--check]
"""
import glob
import io
import os
import sys

NL = chr(10)
BEGIN = "  # >>> sloth-generated — local/render-slo.sh 가 쓴다. 손으로 고치지 말 것"
END = "  # <<< sloth-generated"


def build_block(out_dir):
    blocks = []
    for path in sorted(glob.glob(os.path.join(out_dir, "*.rules.yaml"))):
        key = "slo-" + os.path.basename(path).replace(".rules.yaml", "") + ".rules.yml"
        body = io.open(path, encoding="utf-8").read().rstrip(NL)
        # ConfigMap 의 리터럴 블록이라 4칸 들여쓴다. 빈 줄에는 공백을 남기지
        # 않는다 — 남기면 들여쓰기가 흔들려 읽기 어려워진다.
        lines = [("    " + l) if l.strip() else "" for l in body.split(NL)]
        blocks.append("  " + key + ": |" + NL + NL.join(lines))
    return NL.join([BEGIN] + blocks + [END]), len(blocks)


def main():
    cm_path, out_dir = sys.argv[1], sys.argv[2]
    check = "--check" in sys.argv[3:]

    block, n = build_block(out_dir)
    if n == 0:
        sys.stderr.write("[slo] 생성물이 0개다 — 주입할 것이 없다" + NL)
        return 1

    old = io.open(cm_path, encoding="utf-8").read()
    if BEGIN in old and END in old:
        head = old.split(BEGIN, 1)[0]
        tail = old.split(END, 1)[1]
        new = head + block + tail
    else:
        new = old.rstrip(NL) + NL + block + NL

    if new == old:
        print("[slo] prometheus-rules ConfigMap 이미 최신 (키 %d개)" % n)
        return 0
    if check:
        sys.stderr.write(
            "[slo] prometheus-rules.yaml 이 뒤처졌다 — render-slo.sh 를 돌리고 커밋할 것" + NL)
        return 1
    io.open(cm_path, "w", encoding="utf-8", newline="").write(new)
    print("[slo] prometheus-rules ConfigMap 갱신 (키 %d개)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
