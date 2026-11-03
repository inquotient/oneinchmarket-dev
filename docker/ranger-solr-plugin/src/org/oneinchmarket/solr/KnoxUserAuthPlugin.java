/*
 * Knox 가 붙인 user.name 을 Solr 의 사용자로 받는 인증 플러그인 (2026-11-03).
 *
 * 왜 직접 쓰나: Ranger 의 Solr 인가 플러그인(RangerSolrAuthorizer)은 요청의 사용자(Principal)를
 *   보고 정책을 고른다. Solr 의 사람 입구는 Knox 이고 Knox 는 백엔드로 보낼 때 Authorization 헤더를
 *   떼고 쿼리 문자열에 user.name=<사용자> 만 붙인다. 이 클러스터의 Solr 10 슬림 이미지에는 그 값을
 *   사용자로 받아 줄 기성 인증 모듈(Hadoop simple auth)이 없다.
 *
 * ★ 신뢰 전제 — 이 플러그인은 user.name 을 **검증하지 않고 믿는다.** 그것이 안전한 이유는
 *   base/governance/solr/solr-authz.yaml(AuthorizationPolicy)이 Solr 에 닿는 메시 신원을 Knox ·
 *   ranger-admin · 감사 플러그인 · 정리 Job 으로 좁히기 때문이다. 그 정책이 없거나 넓어지면 누구나
 *   user.name 으로 남을 사칭할 수 있다 — 정책과 이 플러그인은 함께 움직여야 한다.
 * ★ user.name 이 없는 요청(감사 플러그인·Ranger Admin·정리 Job)은 defaultUser(기본 "solr")로 둔다 —
 *   Ranger 서비스 정의(oim-solr)의 username 이 그 사용자라 기본 정책으로 전권을 받는다.
 * ★ POST 본문을 읽지 않는다 — request.getParameter() 는 form 본문을 소비해 Solr 가 업데이트 본문을
 *   못 읽게 만든다. 쿼리 문자열만 직접 파싱한다.
 * ★★ 코어 이름을 내부 헤더(X-Oim-Solr-Core)로 넘긴다 (2026-11-04). 단독(standalone) 모드 Solr 는
 *   요청을 코어로만 식별하고 AuthorizationContext.getCollectionRequests() 를 비워 둔다. Ranger 의
 *   authorizer 는 그 목록을 돌며 검사 요청을 만들므로, 비면 **검사 없이 통과**했다(실측: analyst 의
 *   select·update 200). 이 플러그인은 전체 경로(/solr/<코어>/...)를 보므로 여기서 코어 이름을 뽑아
 *   붙이고, 이식한 authorizer(solr10-patch.py ⑦)가 목록이 빌 때 그것을 쓴다.
 *   클라이언트가 같은 이름의 헤더를 보내면 **버린다** — 남의 코어 이름을 대고 통과하지 못하게.
 */
package org.oneinchmarket.solr;

import jakarta.servlet.FilterChain;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.Principal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import org.apache.solr.security.AuthenticationPlugin;

public class KnoxUserAuthPlugin extends AuthenticationPlugin {

  private static final Pattern SAFE = Pattern.compile("[A-Za-z0-9._@-]{1,64}");

  /** solr10-patch.py ⑦ 의 authorizer 쪽 상수와 같아야 한다. */
  static final String CORE_HEADER = "X-Oim-Solr-Core";

  /** 코어가 아닌 첫 경로 조각 — 관리 API · v2 API · 관리 UI 정적 파일. */
  private static final Set<String> NOT_CORE =
      Set.of("admin", "api", "____v2", "css", "js", "img", "libs", "partials", "index.html");

  private String userParam = "user.name";
  private String defaultUser = "solr";

  @Override
  public void init(Map<String, Object> config) {
    Object p = config.get("userParam");
    if (p instanceof String && !((String) p).isEmpty()) userParam = (String) p;
    Object d = config.get("defaultUser");
    if (d instanceof String && SAFE.matcher((String) d).matches()) defaultUser = (String) d;
  }

  @Override
  public boolean doAuthenticate(
      HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws Exception {
    String user = fromQueryString(request.getQueryString(), userParam);
    if (user == null || user.isEmpty()) {
      user = defaultUser;
    } else if (!SAFE.matcher(user).matches()) {
      response.sendError(401, "invalid " + userParam);
      return false;
    }
    final String name = user;
    final Principal principal = () -> name;
    final String core = coreFromPath(request.getRequestURI(), request.getContextPath());
    HttpServletRequestWrapper wrapped =
        new HttpServletRequestWrapper(request) {
          @Override
          public Principal getUserPrincipal() {
            return principal;
          }

          @Override
          public String getRemoteUser() {
            return name;
          }

          // 클라이언트가 보낸 X-Oim-Solr-Core 는 무시하고 경로에서 뽑은 값만 보인다.
          @Override
          public String getHeader(String h) {
            if (CORE_HEADER.equalsIgnoreCase(h)) return core;
            return super.getHeader(h);
          }

          @Override
          public Enumeration<String> getHeaders(String h) {
            if (CORE_HEADER.equalsIgnoreCase(h)) {
              return Collections.enumeration(
                  core == null ? Collections.<String>emptyList() : Collections.singletonList(core));
            }
            return super.getHeaders(h);
          }

          @Override
          public Enumeration<String> getHeaderNames() {
            List<String> names = new ArrayList<>();
            Enumeration<String> e = super.getHeaderNames();
            while (e != null && e.hasMoreElements()) {
              String n = e.nextElement();
              if (!CORE_HEADER.equalsIgnoreCase(n)) names.add(n);
            }
            if (core != null) names.add(CORE_HEADER);
            return Collections.enumeration(names);
          }
        };
    filterChain.doFilter(wrapped, response);
    return true;
  }

  /** /solr/<코어>/... 의 첫 경로 조각. 관리·v2 경로이거나 이름 형식이 아니면 null. */
  static String coreFromPath(String uri, String contextPath) {
    if (uri == null) return null;
    String p = uri;
    if (contextPath != null && !contextPath.isEmpty() && p.startsWith(contextPath)) {
      p = p.substring(contextPath.length());
    }
    while (p.startsWith("/")) p = p.substring(1);
    int i = p.indexOf('/');
    String seg = i < 0 ? p : p.substring(0, i);
    if (seg.isEmpty() || NOT_CORE.contains(seg) || !SAFE.matcher(seg).matches()) return null;
    return seg;
  }

  static String fromQueryString(String qs, String key) {
    if (qs == null) return null;
    for (String kv : qs.split("&")) {
      int i = kv.indexOf('=');
      String k = i < 0 ? kv : kv.substring(0, i);
      if (URLDecoder.decode(k, StandardCharsets.UTF_8).equals(key)) {
        return i < 0 ? "" : URLDecoder.decode(kv.substring(i + 1), StandardCharsets.UTF_8);
      }
    }
    return null;
  }

  @Override
  public void close() {}
}
