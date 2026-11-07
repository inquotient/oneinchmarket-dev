#!/bin/sh
# Ranger 2.9.0 감사 모듈(agents-audit/dest-solr)을 SolrJ 9 로 빌드하기 전에 SolrCloud(ZooKeeper) 분기를 걷어낸다 (2026-11-07)
#
# ★ 왜: Kafka 4 는 KRaft 라 ZooKeeper 가 없다. SolrJ 8.11 은 응답을 풀 때 ZooKeeper 클래스를 불러
#   감사가 11-03 부터 멈춰 있었다(Dockerfile 머리말). SolrJ 9 는 ZooKeeper 를 solr-solrj-zookeeper 로
#   떼어 냈고, 그 모듈은 넣지 않는다. 그러면 남은 ZooKeeper 경로는 이 파일의 SolrCloud 분기 하나뿐이다
#   (CloudSolrClient.Builder(zkHosts) — 이 클러스터는 xasecure.audit.destination.solr.urls 만 쓴다).
#   그 분기를 두면 설정 하나로 런타임 NoClassDefFoundError 가 되살아나므로 소스에서 지운다.
# ★ 나머지 API(LBHttpSolrClient · HttpClientUtil · Krb5HttpClientBuilder · addSolrServer ·
#   withConnectionTimeout(int))는 SolrJ 9.11 에 그대로 있다 — 수정 없이 컴파일된다(실측).
# ★ 각 수정은 바뀐 것을 세고 아니면 실패한다(Gotcha 86) — 소스가 바뀌면 조용히 빗나가지 않게.
set -eu
F="$1/agents-audit/dest-solr/src/main/java/org/apache/ranger/audit/destination/SolrAuditDestination.java"
test -f "$F"

# ① SolrCloud 분기의 본문을 오류 로그 한 줄로 바꾼다 — `if (zkHosts ...) {` 부터 `} else if (solrURLs ...) {` 앞까지.
awk '
  /if \(zkHosts != null && !zkHosts\.isEmpty\(\)\) \{/ && !done {
    print
    print "\t\t\t\t\t\tLOG.error(\"SolrCloud(ZooKeeper) mode is not supported in this build - use xasecure.audit.destination.solr.urls. zkHosts=\" + zkHosts);"
    skip = 1; done = 1; next
  }
  skip && /\} else if \(solrURLs != null && !solrURLs\.isEmpty\(\)\) \{/ { skip = 0 }
  !skip { print }
' "$F" > "$F.new"
mv "$F.new" "$F"

# ② CloudSolrClient import 를 지운다(남아 있으면 SolrCloud 를 다시 쓸 수 있다는 신호가 된다)
sed -i '/^import org\.apache\.solr\.client\.solrj\.impl\.CloudSolrClient;$/d' "$F"

# ── 검증 ──
n=$(grep -c 'SolrCloud(ZooKeeper) mode is not supported' "$F")
[ "$n" -eq 1 ] || { echo "[solrj9-patch] SolrCloud 분기 치환이 $n 건이다(1 이어야 한다)" >&2; exit 1; }
if grep -q 'CloudSolrClient' "$F"; then echo "[solrj9-patch] CloudSolrClient 가 남았다" >&2; exit 1; fi
grep -q 'LBHttpSolrClient.Builder builder = new LBHttpSolrClient.Builder();' "$F" \
  || { echo "[solrj9-patch] URL 분기(LBHttpSolrClient)가 사라졌다" >&2; exit 1; }
echo "[solrj9-patch] SolrCloud(ZooKeeper) 분기를 지웠다 — URL 분기만 남았다"
