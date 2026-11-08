#!/usr/bin/env python3
# Ranger 2.9.0 plugin-solr / ranger-solr-plugin-shim 을 Solr 10.x 에 맞춘다 (2026-11-03 · 10.1 대응 2026-11-08).
# 각 수정은 "있던 것이 정확히 바뀌었는지" 를 세고, 아니면 실패한다(조용히 빗나가지 않게).
import re, sys
B = sys.argv[1] if len(sys.argv) > 1 else "/src"
AUTH = B + "/plugin-solr/src/main/java/org/apache/ranger/authorization/solr/authorizer/RangerSolrAuthorizer.java"
SHIM = B + "/ranger-solr-plugin-shim/src/main/java/org/apache/ranger/authorization/solr/authorizer/RangerSolrAuthorizer.java"

def edit(path, fn, label):
    s = open(path, encoding="utf-8").read()
    n = fn(s)
    if n == s:
        sys.exit("[patch] 변화 없음: %s (%s)" % (label, path))
    open(path, "w", encoding="utf-8").write(n)
    print("[patch] ok:", label)

# 1) Solr 9 에서 없어진 권한 이름(autoscaling · metrics history). 대응할 요청이 없으므로 인가 공백이 아니다.
def drop_removed_perms(s):
    s = s.replace("\t\t\t\t\tcase METRICS_HISTORY_READ_PERM:\n", "", 1)
    i = s.index("case AUTOSCALING_READ_PERM:")
    i = s.rindex("\n", 0, i) + 1
    j = s.index("case ALL: {", i)
    j = s.rindex("\n", 0, j) + 1
    return s[:i] + s[j:]
edit(AUTH, drop_removed_perms, "Solr 10 에서 없어진 권한 이름 제거")

# 2) NamedListInitializedPlugin.init(NamedList<?>) — 원시 타입이면 이름 충돌이다.
for p in (AUTH, SHIM):
    s = open(p, encoding="utf-8").read()
    if "init(NamedList args)" in s:
        edit(p, lambda t: t.replace("init(NamedList args)", "init(NamedList<?> args)"), "init(NamedList<?>) " + p.split("/")[3])

# 3) SolrJ 는 solr-core 의 하위 의존으로 오지 않는다 — 명시한다. 서블릿 API 는 Solr 가 런타임에 준다(provided).
DEPS = """
        <dependency><groupId>org.apache.solr</groupId><artifactId>solr-solrj</artifactId><version>${solr.version}</version><scope>provided</scope></dependency>
        <dependency><groupId>jakarta.servlet</groupId><artifactId>jakarta.servlet-api</artifactId><version>6.0.0</version><scope>provided</scope></dependency>"""
for pom in (B + "/plugin-solr/pom.xml", B + "/ranger-solr-plugin-shim/pom.xml"):
    s = open(pom, encoding="utf-8").read()
    if "jakarta.servlet-api" not in s:
        edit(pom, lambda t: t.replace("<dependencies>", "<dependencies>" + DEPS, 1), "SolrJ·서블릿 의존 " + pom.split("/")[2])

# 4) Solr 10 에서 없어진 컬렉션·코어 작업 이름. 대응할 요청이 없으므로 인가 공백이 아니다.
UTIL = B + "/plugin-solr/src/main/java/org/apache/ranger/authorization/solr/authorizer/SolrAuthzUtil.java"
def drop_removed_actions(s):
    s = re.sub(r"(?m)^[ \t]*case (MIGRATESTATEFORMAT|INVOKE|FORCEPREPAREFORLEADERSHIP):[ \t]*\n", "", s)
    return s.replace("case DELETEALIAS: {", "{", 1)
edit(UTIL, drop_removed_actions, "Solr 10 에서 없어진 작업 이름 제거")

# 5) Lucene 9 부터 CoveringQuery 는 sandbox 로 옮겨졌다.
SUB = B + "/plugin-solr/src/main/java/org/apache/ranger/authorization/solr/authorizer/SubsetQueryPlugin.java"
edit(SUB, lambda t: t.replace("import org.apache.lucene.search.CoveringQuery;", "import org.apache.lucene.sandbox.search.CoveringQuery;"), "CoveringQuery -> lucene sandbox")
LDEPS = """
        <dependency><groupId>org.apache.lucene</groupId><artifactId>lucene-core</artifactId><version>10.3.2</version><scope>provided</scope></dependency>
        <dependency><groupId>org.apache.lucene</groupId><artifactId>lucene-sandbox</artifactId><version>10.3.2</version><scope>provided</scope></dependency>"""
pom = B + "/plugin-solr/pom.xml"
s = open(pom, encoding="utf-8").read()
if "lucene-sandbox" not in s:
    edit(pom, lambda t: t.replace("<dependencies>", "<dependencies>" + LDEPS, 1), "Lucene 의존")

# 6) org.apache.solr.common.StringUtils 는 Solr 10 에서 없어졌다 — shim 이 쓰는 곳은 equals 하나다.
edit(SHIM, lambda t: t.replace("import org.apache.solr.common.StringUtils;\n", "import java.util.Objects;\n")
                      .replace("StringUtils.equals(super.getName(), RANGER_SOLR_AUTHORIZER_IMPL_CLASSNAME)",
                               "Objects.equals(super.getName(), RANGER_SOLR_AUTHORIZER_IMPL_CLASSNAME)"),
     "shim StringUtils -> Objects")

# 7) 단독(standalone) 모드에서 컬렉션 목록이 비면 검사 없이 통과하던 구멍을 막는다 (2026-11-04).
#    Solr 는 단독 모드에서 요청을 코어로만 식별하고 getCollectionRequests() 를 비워 둔다. 원본은
#    그 목록을 돌며 검사 요청을 만들어서, 비면 READ/UPDATE 가 **무조건 허용**됐다(실측: analyst 의
#    select·update 200). KnoxUserAuthPlugin 이 경로에서 뽑아 붙인 X-Oim-Solr-Core 를 쓰고, 그것도
#    없으면 "*" 로 검사한다 — 모든 컬렉션 권한을 가진 사용자만 통과하는 fail-closed 다.
#    헤더 이름은 KnoxUserAuthPlugin.CORE_HEADER 와 같아야 한다.
OLD_LOOP = """						for (CollectionRequest req : context.getCollectionRequests()) {
							rangerRequests.add(createRequest(userName, userGroups, ip, eventTime, context,
									RangerSolrConstants.RESOURCE_TYPE.COLLECTION, req.collectionName, accessType));
						}
						break;
"""
NEW_LOOP = """						for (CollectionRequest req : context.getCollectionRequests()) {
							rangerRequests.add(createRequest(userName, userGroups, ip, eventTime, context,
									RangerSolrConstants.RESOURCE_TYPE.COLLECTION, req.collectionName, accessType));
						}
						if (context.getCollectionRequests().isEmpty()) {
							String oimCore = context.getHttpHeader("X-Oim-Solr-Core");
							rangerRequests.add(createRequest(userName, userGroups, ip, eventTime, context,
									RangerSolrConstants.RESOURCE_TYPE.COLLECTION,
									(oimCore == null || oimCore.isEmpty()) ? "*" : oimCore, accessType));
						}
						break;
"""
def standalone_core(s):
    if s.count(OLD_LOOP) != 1:
        sys.exit("[patch] READ/UPDATE 루프가 정확히 하나가 아니다: %d" % s.count(OLD_LOOP))
    return s.replace(OLD_LOOP, NEW_LOOP, 1)
edit(AUTH, standalone_core, "단독 모드 코어 이름으로 컬렉션 검사")

# 8) Solr 10.1 은 LocalSolrQueryRequest 를 없앴다 — SolrQueryRequestBase 가 abstract 에서 구체 클래스가 되어
#    그 자리를 대신한다(2026-11-08, javap 로 10.0·10.1 대조). HTTP 요청은 10.1 에서도 익명 하위 클래스
#    (SolrRequestParsers$1 extends SolrQueryRequestBase)라서, **정확히 그 클래스인 것**만 로컬 요청이다.
#    instanceof 로 바꾸면 모든 HTTP 요청이 superuser 가 되므로 쓰지 말 것.
#    ★ 이 경로(getUserName(SolrQueryRequest))는 문서 수준 인가(prepare, 기본 꺼짐)에서만 불린다.
def local_request(s):
    a = "import org.apache.solr.request.LocalSolrQueryRequest;"
    b = "if (req instanceof LocalSolrQueryRequest) {"
    if s.count(a) != 1 or s.count(b) != 1:
        sys.exit("[patch] LocalSolrQueryRequest 사용처가 예상과 다르다: import=%d use=%d" % (s.count(a), s.count(b)))
    return (s.replace(a, "import org.apache.solr.request.SolrQueryRequestBase;")
             .replace(b, "if (req.getClass() == SolrQueryRequestBase.class) {"))
edit(AUTH, local_request, "LocalSolrQueryRequest -> exact SolrQueryRequestBase")
