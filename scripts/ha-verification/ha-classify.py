# -*- coding: utf-8 -*-
"""컴포넌트별 HA 등급표 생성기 — docs/LOCAL-DEPLOYMENT.md §17 의 원천.

손으로 적은 목록은 반드시 빠진다. §16 이 124개 중 30개만 다루고도 완전한
것처럼 보였다. 살아 있는 클러스터를 훑어 **전부** 나열하고, 규칙에 없는 것은
`미분류` 로 남긴다 — 빠진 것이 조용히 사라지지 않게 하는 것이 요점이다.

  python3 scripts/ha-verification/ha-classify.py         # 표 형식
  python3 scripts/ha-verification/ha-classify.py --md    # 마크다운 표

등급
  R  복제만 하면 됨      무상태 · 상태가 외부(DB/ES/오브젝트)에 있다
  C  클러스터링 구성     앱 고유 프로토콜 필요(RF · Raft · Galera · replSet · Infinispan)
  S  상태를 먼저 옮겨야  로컬 디스크에 상태가 있다 → 외부 저장소 선행
  L  리더 선출           오퍼레이터 · 컨트롤러. replicas 2 + leader election
  D  DaemonSet           구조상 노드당 1 — 이미 그 형태다
  J  Job/CronJob         HA 개념이 다르다. 멱등성 · 중복 실행 방지가 관건
  X  실익 없음/불가      단일 전제 설계이거나 상용 기능
"""
import json
import re
import subprocess
import sys
from collections import Counter

KUBECTL = ["sudo", "k3s", "kubectl"]

RULES = [
    (r"^coredns$", "R", "replicas 2 + anti-affinity. DNS 는 전부의 의존성이다"),
    (r"^istiod$", "R", "replicas 2"),
    (r"^(ingress-istio|waypoint)$", "R", "replicas 2"),
    (r"^kafka$", "C", "브로커 3 + 토픽 RF>=2 + min.insync.replicas=2"),
    (r"^elasticsearch", "C", "ECK nodeSets 3 + 인덱스 복제본 >=1"),
    (r"^wazuh-indexer$", "C", "OpenSearch 클러스터 3노드"),
    (r"^wazuh-manager$", "C", "master/worker 클러스터 모드 — 매니페스트에 설정 없음"),
    (r"^zookeeper$", "C", "앙상블 3"),
    (r"^postgresql$", "C", "CloudNativePG — 스트리밍 복제 + 자동 페일오버 (§13-2)"),
    (r"^mariadb$", "C", "Galera 3중 (§13-2)"),
    (r"^mongodb$", "C", "네이티브 replica set (§13-2)"),
    (r"^clickhouse$", "C", "ReplicatedMergeTree + Keeper 3 (§13-2)"),
    (r"^redis$", "S", "Sentinel 은 클라이언트 8곳이 미지원 → AOF 지속화만 (§13-2)"),
    (r"^vault$", "C", "Raft 3노드. ★ auto-unseal 이 선행 — 없으면 무의미"),
    (r"^keycloak$", "C", "상태는 PG 에 있다. replicas 2 + JGroups DNS_PING(세션 복제)"),
    (r"^solr$", "C", "SolrCloud 로 전환 + ZK 앙상블"),
    (r"^ds389$", "C", "multi-supplier 복제. 복제본만 늘리면 갈라진다"),
    (r"^hadoop-namenode$", "C", "JournalNode 3 + ZKFC + standby NN — 큰 작업"),
    (r"^hbase-master$", "C", "마스터 여럿 + ZK 선출"),
    (r"^minio$", "C", "분산 모드는 엔드포인트 4개 이상. Loki·Tempo·Grafana·백업의 선행"),
    (r"^alertmanager$", "C", "네이티브 gossip 클러스터. 현재 --cluster.listen-address= 로 꺼져 있다"),
    (r"^grafana$", "S", "SQLite on PVC → PostgreSQL 로 옮긴 뒤 replicas 2"),
    (r"^loki$", "S", "filesystem → MinIO(S3) + 마이크로서비스 모드"),
    (r"^tempo$", "S", "backend local → MinIO"),
    (r"^pyroscope$", "S", "로컬 저장 → 오브젝트 스토리지 필요"),
    (r"^prometheus$", "R", "동일 설정 2대 병렬(HA 쌍). 중복은 Alertmanager 가 제거"),
    (r"^logstash$", "R", "Kafka 컨슈머 그룹이 분배. replicas 2"),
    (r"^kibana", "R", "상태는 ES 에 있다"),
    (r"^hive-metastore$", "R", "상태는 PG 에 있다 — 싸다"),
    (r"^hive-server$", "R", "메타스토어를 공유"),
    (r"^trino$", "X", "코디네이터 HA 가 Trino 에 없다. 워커만 늘어난다"),
    (r"^apicurio-registry$", "R", "상태는 PG 에 있다"),
    (r"^(apicurio-ui|akhq)$", "R", "무상태 UI"),
    (r"^(admin|cmmn-api)$", "R", "상태는 MariaDB/Mongo 에 있다"),
    (r"^nginx$", "R", "무상태"),
    (r"^knox$", "R", "무상태 게이트웨이"),
    (r"^lam$", "R", "상태는 DS389 에 있다"),
    (r"^ranger-admin$", "R", "상태는 DB 에 있다"),
    (r"^ranger-usersync$", "X", "단일 동기화기 — 여럿 돌리면 중복 동기화"),
    (r"^otel-gateway$", "R", "무상태 수집기"),
    (r"^falcosidekick$", "R", "무상태 전달자"),
    (r"^kube-state-metrics$", "R", "무상태. 2대면 지표가 이중이 되므로 Prometheus 쪽에서 제거"),
    (r"^kafka-bridge$", "R", "무상태"),
    (r"^openmeter-api$", "R", "상태는 PG/CH/Redis. ★ 과금 진입점이라 우선순위 높음"),
    (r"^openmeter-(sink|balance|billing)-worker$", "R", "Kafka 컨슈머 그룹이 분배"),
    (r"^openmeter-notification-service$", "R", "무상태"),
    (r"^glitchtip-web$", "R", "상태는 PG/Redis 에 있다"),
    (r"^glitchtip-worker$", "R", "큐 워커 — 늘리면 그대로 분산"),
    (r"^defectdojo-(django|nginx)$", "R", "상태는 PG 에 있다"),
    (r"^defectdojo-celery-worker$", "R", "큐 워커"),
    (r"^defectdojo-celery-beat$", "X", "★ beat 는 단일이어야 한다 — 여럿이면 스케줄이 중복 발행된다"),
    (r"^dependency-track-apiserver$", "S", "PVC 를 쓴다 — 외부 저장소 전환 선행"),
    (r"^dependency-track-frontend$", "R", "무상태"),
    (r"^(spark-connect|spark-history|livy)$", "X", "단일 전제. 실익 작음"),
    (r"^(hadoop-datanode|hbase-regionserver)$", "R", "데이터 노드는 늘리면 그대로 분산된다"),
    (r"^jenkins$", "X", "컨트롤러 HA 는 상용 기능. 에이전트 확장 + 백업"),
    (r"^gitlab$", "X", "Gitaly Cluster(Praefect) + Redis + 오브젝트 스토리지 필요 — 범위 밖"),
    (r"^caldera$", "X", "랩 전용 단일"),
    (r"^safeline", "X", "compose 태생 단일"),
    (r"-openreplay$", "R", "OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis)"),
    (r"^kyverno-", "L", "replicas 2 + 리더 선출(차트 기본 지원)"),
    (r"^cert-manager", "L", "replicas 2 + 리더 선출"),
    (r"^elastic-operator$", "L", "리더 선출. 오퍼레이터가 죽어도 기존 ES 는 계속 돈다"),
    (r"^(tetragon-operator|trivy-operator|policy-reporter)", "L", "리더 선출"),
    (r"^local-path-provisioner$", "L", "리더 선출. ★ 다만 볼륨은 노드 로컬이다(§11-2-b)"),
    (r"^metrics-server$", "R", "무상태"),
    (r"^cilium-operator$", "L", "replicas 2 + 리더 선출. 죽어도 기존 데이터패스는 계속 돈다"),
]


def sh(args):
    out = subprocess.run(KUBECTL + args + ["-o", "json"], capture_output=True, text=True).stdout
    return json.loads(out or "{}")


def classify(name, kind, has_pvc):
    if kind == "DaemonSet":
        return "D", "구조상 노드당 1 — 이미 그 형태다"
    if kind == "CronJob":
        return "J", "HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건"
    for pat, grade, how in RULES:
        if re.search(pat, name):
            return grade, how
    hint = "PVC 있음 — 로컬 상태 여부부터 확인할 것" if has_pvc else "PVC 없음 — 무상태면 R 일 가능성"
    return "미분류", hint


def collect():
    rows = []
    for kind, api in [("Deployment", "deploy"), ("StatefulSet", "sts"),
                      ("DaemonSet", "ds"), ("CronJob", "cronjob")]:
        for it in sh(["get", api, "-A"]).get("items", []):
            ns = it["metadata"]["namespace"]
            name = it["metadata"]["name"]
            sp = it["spec"]
            if kind == "CronJob":
                tpl = sp["jobTemplate"]["spec"]["template"]["spec"]
                reps = "-"
            else:
                tpl = sp["template"]["spec"]
                reps = 1 if kind == "DaemonSet" else sp.get("replicas", 1)
            pvc = bool(sp.get("volumeClaimTemplates")) or any(
                v.get("persistentVolumeClaim") for v in tpl.get("volumes", []))
            grade, how = classify(name, kind, pvc)
            rows.append((grade, ns, name, kind, reps, pvc, how))
    order = {"R": 0, "C": 1, "S": 2, "L": 3, "D": 4, "J": 5, "X": 6, "미분류": 7}
    rows.sort(key=lambda r: (order.get(r[0], 9), r[1], r[2]))
    return rows


def main():
    rows = collect()
    if "--md" in sys.argv:
        print("| 등급 | 컴포넌트 | 종류 | 현재 | PVC | HA 구성 방법 |")
        print("|:-:|---|---|:-:|:-:|---|")
        for grade, ns, name, kind, reps, pvc, how in rows:
            nsx = "" if ns == "local" else " `%s`" % ns
            print("| **%s** | %s%s | %s | %s | %s | %s |"
                  % (grade, name, nsx, kind, reps, "Y" if pvc else "-", how))
    else:
        for grade, ns, name, kind, reps, pvc, _ in rows:
            print("%-6s %-16s %-34s %-12s %-3s %s"
                  % (grade, ns, name, kind, reps, "PVC" if pvc else ""))

    counts = Counter(r[0] for r in rows)
    print()
    print("합계 %d 개 — " % len(rows)
          + " · ".join("%s %d" % (k, counts[k])
                       for k in ["R", "C", "S", "L", "D", "J", "X", "미분류"] if counts[k]))
    if counts["미분류"]:
        print("★ 미분류 %d 건 — RULES 에 추가할 것" % counts["미분류"])


main()
