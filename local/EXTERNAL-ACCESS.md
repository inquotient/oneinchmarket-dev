# 클러스터 외부에서 접속하기 — 브라우저 · DBeaver · Knox · VPN

> 브랜치 `local` · **2026-10-11 실측** · 베어메탈 2노드
> (`192.168.0.103` control-plane · `192.168.0.104` agent)
>
> **비밀번호는 이 문서에 적지 않는다.** 값 대신 **조회 명령**을 적는다 —
> 문서에 넣는 순간 git 에 들어가고, `CLAUDE.md` 가 금지하는 항목이다(Gotcha 186).
>
> ★ 이 문서는 **외부 경로**를 다룬다. `kubectl port-forward` 로 보는 법은
> [ACCESS.md](./ACCESS.md) 다. 둘은 대체 관계가 아니다 — 외부 경로가 깨졌을
> 때 port-forward 가 대조군이 된다.

<!-- GENERATED:counts START -->
웹 호스트 **56**(자체 인증 25 · 인증 없음 19 · 도구용 12, 그중 백엔드가 HTTPS 인 것 5) · TCP 대상 **15**
<!-- GENERATED:counts END -->

---

## 0. 구조 — 경로가 셋이다

```text
                      +------------------------------------------------+
  브라우저              |  192.168.0.103:443  (externalIPs, Cilium)       |
  -------------------> |  Istio Gateway (Envoy)                         |
  https://<app>        |   · TLS 종단: gateway-ca 가 발급한 *.local       |
   .oneinchmarket      |   · 호스트명으로 라우팅 (경로는 전부 /)           |
   .local              |   · 백엔드로는 HBONE(15008) + mTLS               |
                       +----------------------+-------------------------+
                                              | 신원 sa/ingress-istio
                                              v
                                   각 컴포넌트 (ambient 메시 안)

  DBeaver              +------------------------------------------------+
  -------------------> |  192.168.0.103:304xx  (NodePort, 고정)          |
  jdbc:postgresql      |  db-gateway  (nginx stream TCP 프록시)           |
   ://...:30432        |   · 메시 안 워크로드 = **신원이 있다**             |
                       +----------------------+-------------------------+
                                              | 신원 sa/db-gateway
                                              v
                          PostgreSQL · MariaDB · Mongo · Redis · ...

  Hadoop               +------------------------------------------------+
  -------------------> |  https://knox.oneinchmarket.local               |
  WebHDFS/Hive/HBase   |  Knox (DS389 LDAP basic 인증)                   |
                       +----------------------+-------------------------+
                                              v
                         WebHDFS · HiveServer2(http) · HBase REST
```

### 왜 이렇게 갈라지는가 — 실측이 정한 것이다

1. **UI 는 HTTPRoute 만 붙이면 된다.** 게이트웨이는 ztunnel 에 포획되지
   않지만(`istio.io/dataplane-mode: none`) **그 자체가 신원을 가진 Istio
   프록시**라 백엔드로 HBONE(15008)을 쓴다. 그 포트는 `allow-istio-hbone` 이
   모든 파드에 열어 두므로 **백엔드마다 NetworkPolicy 를 더할 필요가 없다.**
   근거: Envoy 통계의 `destination_principal` 이
   `spiffe://cluster.local/ns/local/sa/grafana` 이고 응답이 200 이었다.
   > ★ 메시 밖의 **평범한** 파드로 이것을 흉내내면 전부 타임아웃이다(평문으로
   > 대상 포트를 직접 쳐서 Cilium 이 떨군다). 그 대리 실험으로 한 번 틀렸고,
   > 실제 경로를 치니 200 이었다 — **대리의 조건이 대상과 같은지 먼저 볼 것.**

2. **데이터 계층은 그렇게 되지 않는다.** `AuthorizationPolicy` 가 선택하는
   워크로드는 실측 **12개**(DB 6종 + shardingsphere · kafka · opensearch ·
   minio · spark-connect · data-prepper · 게이트웨이)이고, ALLOW 정책이
   워크로드를 선택하면 **매칭되지 않은 전부가 거부된다**(Gotcha 9·19). 신원
   없는 외부 TCP 는 ztunnel 이 받아들인 뒤 HBONE 계층에서 끊으므로 **TCP 는
   열리고 프로토콜에서 죽는다**(Gotcha 147·194). 그래서 신원을 가진 **메시 안
   프록시**(`db-gateway`)를 둔다.

3. **TCP 를 게이트웨이로 보낼 수 없다.** 이 클러스터의 Gateway API 는
   **standard 채널**이라 CRD 가 `httproutes`·`grpcroutes` 뿐이고
   **`TCPRoute`·`TLSRoute` 가 없다**(실측). experimental 채널을 넣으면 CRD 가
   늘어 ArgoCD 컨트롤러 캐시가 커지고(Gotcha 119) AppProject 화이트리스트도
   함께 고쳐야 한다(Gotcha 57). 그 비용 대신 nginx stream 파드 하나로 끝낸다.

4. **443 은 노드 DNAT 가 아니라 `externalIPs` 로 받는다.** NodePort 범위는
   `30000-32767` 이라 443 을 직접 열 수 없고, Gateway API 의 Service 는 Istio
   컨트롤러가 만들어 우리가 포트를 더할 수 없다. 처음에 iptables DNAT 를
   쓰려 했고 **측정해서 버렸다** — 규칙은 맞는데(실측 2패킷 120바이트) 연결이
   `000` 이다. Cilium 은 NodePort 를 **tc ingress 의 eBPF** 에서 처리하고
   그것은 netfilter 보다 앞에서 끝나므로, 포트를 바꿔 봐야 호스트에 그 포트를
   듣는 프로세스가 없다. `externalIPs` 는 Cilium 이 직접 프런트엔드로
   등록하므로 그 문제가 없다(`external-ips-service.yaml`).

---

## 1. 처음 한 번 — 전제 셋

### 1-a. 노드 쪽을 켠다 (와일드카드 DNS · VPN)

```bash
# 검사만 (게이트용 · 0 통과 / 1 실패 / 2 측정 불가)
ssh root@192.168.0.103 'bash /root/oneinchmarket-dev/local/external-access-node.sh --check'
# 적용
ssh root@192.168.0.103 'bash /root/oneinchmarket-dev/local/external-access-node.sh'
```

보는 것: `oim-wildcard-dns.service` 가 `*.oneinchmarket.local` 을 답하는지 ·
**외부 이름이 여전히 풀리는지**(와일드카드가 다른 것을 삼키지 않았는지) ·
`wg-quick@oim0` 과 UDP 51820 · `ip_forward` · MASQUERADE 인터페이스.
실측 2026-10-11: **통과 22 · 실패 0 · 측정 불가 0**.

> ★★ **443·80 은 이 스크립트가 다루지 않는다.** 그것은 클러스터 쪽
> (`external-ips-service.yaml`)이고 ArgoCD 가 유지한다. 노드에 남는 것은
> **DNS 와 VPN 뿐**이다 — 둘 다 쿠버네티스 오브젝트로 담을 수 없어서다
> (`registries.yaml` 과 같은 부류, Gotcha 126·183).
>
> ★ dnsmasq 를 **패키지로 설치하지 않는다.** 이 노드에는 `dnsmasq-base` 만
> 깔려 있어(libvirt/NetworkManager 가 끌고 온다) 바이너리는 있고 서비스는
> 없었다 — 첫 판이 바이너리 유무로 판정해 "기동 실패" 를 냈다. 지금은
> **전용 유닛 + 전용 설정**을 쓰고, 그래서 전역 `/etc/dnsmasq.conf` 와
> systemd-resolved 의 :53 다툼이 아예 생기지 않는다(Gotcha 111 회피).

### 1-b. 이름을 풀 수 있게 한다 — 둘 중 하나

**(권장) DNS 를 노드로 돌린다.** 호스트가 늘어도 손댈 것이 없다.
Windows → 어댑터 설정 → IPv4 → DNS 서버를 `192.168.0.103` 으로. 공유기
DHCP 에 넣으면 집 안 모든 기기가 함께 된다.

```powershell
# 먼저 노드가 답하는지 확인 (실측으로 192.168.0.103 을 돌려준다)
nslookup grafana.oneinchmarket.local 192.168.0.103
```

> 노드의 `:53` 은 systemd-resolved 가 `127.0.0.53`·`127.0.0.54` 에만 묶고
> 있어 LAN IP 의 53 이 비어 있다(실측). 전용 dnsmasq 는 `192.168.0.103` 에만
> 바인드해 노드 자신의 DNS 를 건드리지 않는다.

**(대안) hosts 파일.** 한 대에서만 쓰면 충분하고 공유기를 건드리지 않는다.

<!-- GENERATED:hosts START -->
```text
# oneinchmarket 외부 접속 — Windows 는 C:\Windows\System32\drivers\etc\hosts (관리자 권한)
# 192.168.0.103 = control-plane. 104 로 바꿔도 같다 — 양 노드가 같은 라우팅을 받는다.
192.168.0.103 grafana.oneinchmarket.local
192.168.0.103 prometheus.oneinchmarket.local
192.168.0.103 alertmanager.oneinchmarket.local
192.168.0.103 osd.oneinchmarket.local
192.168.0.103 loki.oneinchmarket.local
192.168.0.103 tempo.oneinchmarket.local
192.168.0.103 pyroscope.oneinchmarket.local
192.168.0.103 pyrra.oneinchmarket.local
192.168.0.103 airflow.oneinchmarket.local
192.168.0.103 temporal.oneinchmarket.local
192.168.0.103 flink.oneinchmarket.local
192.168.0.103 akhq.oneinchmarket.local
192.168.0.103 apicurio.oneinchmarket.local
192.168.0.103 apicurio-registry.oneinchmarket.local
192.168.0.103 kafka-bridge.oneinchmarket.local
192.168.0.103 kafka-connect.oneinchmarket.local
192.168.0.103 backstage.oneinchmarket.local
192.168.0.103 gravitee-console.oneinchmarket.local
192.168.0.103 gravitee-portal.oneinchmarket.local
192.168.0.103 gravitee-api.oneinchmarket.local
192.168.0.103 openmeter.oneinchmarket.local
192.168.0.103 keycloak.oneinchmarket.local
192.168.0.103 openbao.oneinchmarket.local
192.168.0.103 ranger.oneinchmarket.local
192.168.0.103 ranger-solr.oneinchmarket.local
192.168.0.103 solr.oneinchmarket.local
192.168.0.103 lam.oneinchmarket.local
192.168.0.103 knox.oneinchmarket.local
192.168.0.103 wazuh.oneinchmarket.local
192.168.0.103 wazuh-indexer.oneinchmarket.local
192.168.0.103 defectdojo.oneinchmarket.local
192.168.0.103 dtrack.oneinchmarket.local
192.168.0.103 dtrack-api.oneinchmarket.local
192.168.0.103 safeline.oneinchmarket.local
192.168.0.103 caldera.oneinchmarket.local
192.168.0.103 midpoint.oneinchmarket.local
192.168.0.103 openfga.oneinchmarket.local
192.168.0.103 opensearch.oneinchmarket.local
192.168.0.103 gitlab.oneinchmarket.local
192.168.0.103 jenkins.oneinchmarket.local
192.168.0.103 glitchtip.oneinchmarket.local
192.168.0.103 minio.oneinchmarket.local
192.168.0.103 s3.oneinchmarket.local
192.168.0.103 trino.oneinchmarket.local
192.168.0.103 spark-history.oneinchmarket.local
192.168.0.103 spark-ui.oneinchmarket.local
192.168.0.103 livy.oneinchmarket.local
192.168.0.103 hdfs.oneinchmarket.local
192.168.0.103 hbase.oneinchmarket.local
192.168.0.103 hbase-rs.oneinchmarket.local
192.168.0.103 hive.oneinchmarket.local
192.168.0.103 app-admin.oneinchmarket.local
192.168.0.103 app-api.oneinchmarket.local
192.168.0.103 www.oneinchmarket.local
192.168.0.103 openreplay.oneinchmarket.local
192.168.0.103 openreplay-api.oneinchmarket.local
192.168.0.103 api.oneinchmarket.local
```
<!-- GENERATED:hosts END -->

### 1-c. 인증서를 신뢰한다 (`-k` 를 안 쓰려면)

TLS 는 cert-manager 의 `gateway-ca` 가 발급한 **자체 서명 체인**이다. 공인
DNS 가 없어 ACME 를 쓸 수 없다. 루트를 받아 Windows 에 넣으면 브라우저 경고가
사라진다.

```powershell
# CA 인증서를 꺼낸다 (비밀값이 아니라 공개 인증서다)
ssh root@192.168.0.103 "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n local get secret gateway-ca-cert -o jsonpath='{.data.ca\.crt}'" | base64 -d > oim-ca.crt
# 관리자 PowerShell 에서 신뢰할 루트에 넣는다
Import-Certificate -FilePath .\oim-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

> 리프 인증서 SAN 은 `oneinchmarket.local` 과 `*.oneinchmarket.local` 이다
> (2026-10-11 에 이름 다섯을 와일드카드로 바꿨다).
> ★ 와일드카드는 **한 단계만** 덮는다 — `a.b.oneinchmarket.local` 은 안 된다.

---

## 2. 웹 UI — 브라우저에서 바로

전부 `https://<호스트>.oneinchmarket.local` 이다. 포트를 적지 않는다(443).

<!-- GENERATED:ui-table START -->
| 호스트 | 인증 | 백엔드 | 비고 |
|---|:-:|---|---|
| https://grafana.oneinchmarket.local | 자체 인증 | `grafana-headless:3000` | admin / `pw grafana-secret admin-password` |
| https://prometheus.oneinchmarket.local | **없음** | `prometheus-headless:9090` | 질의·규칙·타깃 |
| https://alertmanager.oneinchmarket.local | **없음** | `alertmanager:9093` | 경보 현황. 수신자는 Logstash webhook 이다(Gotcha 33) |
| https://osd.oneinchmarket.local | 자체 인증 | `opensearch-dashboards:5601` | admin / `pw opensearch-secret admin-password` · Dev Tools 가 가장 편하다 |
| https://loki.oneinchmarket.local | 도구용 | `loki-headless:3100` | `/ready` · 평소에는 Grafana 가 소비한다 |
| https://tempo.oneinchmarket.local | 도구용 | `tempo-headless:3200` | `/status` · 평소에는 Grafana 가 소비한다 |
| https://pyroscope.oneinchmarket.local | **없음** | `pyroscope:4040` | 연속 프로파일링 |
| https://pyrra.oneinchmarket.local | **없음** | `pyrra:9099` | SLO·오차예산. ★ 빈 그래프의 뜻은 둘이다(Gotcha 150·190) |
| https://airflow.oneinchmarket.local | 자체 인증 | `airflow-apiserver:8080` | admin / `pw airflow-secret admin-password` · 과금 DAG |
| https://temporal.oneinchmarket.local | **없음** | `temporal-ui-headless:8080` | 워크플로 이력. 서버는 gRPC 7233 이다 |
| https://flink.oneinchmarket.local | **없음** | `flink-jobmanager:8081` | 잡 0건. 판정은 `/overview` 의 slots-total 이다(Gotcha 164) |
| https://akhq.oneinchmarket.local | **없음** | `akhq-headless:8080` | Kafka 브라우저. **Kafka 를 보는 가장 좋은 길이다** |
| https://apicurio.oneinchmarket.local | **없음** | `apicurio-ui:8080` | SPA — 브라우저가 레지스트리를 직접 부른다(§6 의 SPA 항) |
| https://apicurio-registry.oneinchmarket.local | 도구용 | `apicurio-registry-headless:8080` | 계약 레지스트리 API. 위 UI 의 전제다 |
| https://kafka-bridge.oneinchmarket.local | **없음** | `kafka-bridge:8080` | HTTP->Kafka. ★ 자체 인증이 없다(SEC-206) |
| https://kafka-connect.oneinchmarket.local | 도구용 | `kafka-connect-headless:8083` | 커넥터 REST. `GET /connectors` |
| https://backstage.oneinchmarket.local | 자체 인증 | `backstage-headless:7007` | Keycloak OIDC. `portal` / `pw keycloak-secret portal-user-password` |
| https://gravitee-console.oneinchmarket.local | 자체 인증 | `gravitee-console-headless:8080` | admin / `pw gravitee-secret admin-password` · SPA(§6) |
| https://gravitee-portal.oneinchmarket.local | 자체 인증 | `gravitee-portal-headless:8080` | 구독·API 키 발급 · SPA(§6) |
| https://gravitee-api.oneinchmarket.local | 도구용 | `gravitee-management-api-headless:8083` | 위 둘의 전제. `/management` · `/portal` |
| https://openmeter.oneinchmarket.local | 도구용 | `openmeter-api:80` | 과금 수집·조회 API |
| https://keycloak.oneinchmarket.local | 자체 인증 | `keycloak-headless:8080` | admin / `pw keycloak-secret admin-password` · ★ iss 가 이 호스트로 발급된다 |
| https://openbao.oneinchmarket.local | 자체 인증 | `openbao:8200` | 토큰 `pw openbao-keys root-token` |
| https://ranger.oneinchmarket.local | 자체 인증 | `ranger-admin:6080` | admin / `pw ranger-secret admin-password` · ★★ 로그인 반복 실패 금지(Gotcha 11) |
| https://ranger-solr.oneinchmarket.local | **없음** | `ranger-solr:8983` | Ranger 감사 색인 |
| https://solr.oneinchmarket.local | **없음** | `solr-headless:8983` | 거버넌스 Solr |
| https://lam.oneinchmarket.local | 자체 인증 | `lam-headless:80` | `pw lam-secret master-password` · DS389 관리 |
| https://knox.oneinchmarket.local | 자체 인증 | `knox-headless:8443` **(https)** | DS389 LDAP basic. ★ **Hadoop 계층의 정식 진입점**(§4) |
| https://wazuh.oneinchmarket.local | 자체 인증 | `wazuh-manager:55000` **(https)** | `pw wazuh-secret api-username` / `api-password` |
| https://wazuh-indexer.oneinchmarket.local | 자체 인증 | `wazuh-indexer:9200` **(https)** | admin / `pw wazuh-secret indexer-admin-password` |
| https://defectdojo.oneinchmarket.local | 자체 인증 | `defectdojo:8080` | admin / `pw defectdojo-secret admin-password` |
| https://dtrack.oneinchmarket.local | 자체 인증 | `dependency-track:8080` | admin/admin — 최초 로그인에 변경을 요구한다 · SPA(§6) |
| https://dtrack-api.oneinchmarket.local | 도구용 | `dependency-track-api:8080` | 위 UI 가 브라우저에서 부르는 API |
| https://safeline.oneinchmarket.local | 자체 인증 | `safeline-mgt:1443` **(https)** | admin / `pw safeline-secret admin-password` · WAF 콘솔 |
| https://caldera.oneinchmarket.local | 자체 인증 | `caldera:8888` | red/blue — 키는 `caldera-secret` 에 있다 |
| https://midpoint.oneinchmarket.local | 자체 인증 | `midpoint-headless:8080` | IGA. administrator / `pw midpoint-secret admin-password` |
| https://openfga.oneinchmarket.local | 도구용 | `openfga-headless:8080` | ReBAC 인가 API. preshared key 가 필요하다(`openfga-secret`) |
| https://opensearch.oneinchmarket.local | 자체 인증 | `opensearch-headless:9200` **(https)** | 검색 엔진 REST. admin / `pw opensearch-secret admin-password` |
| https://gitlab.oneinchmarket.local | 자체 인증 | `gitlab-headless:80` | root / `pw gitlab-secret root-password` |
| https://jenkins.oneinchmarket.local | 자체 인증 | `jenkins-headless:8080` | admin / `pw jenkins-secret admin-password` |
| https://glitchtip.oneinchmarket.local | 자체 인증 | `glitchtip:8000` | 오류 추적. 가입이 필요하다 |
| https://minio.oneinchmarket.local | 자체 인증 | `minio-headless:9001` | 콘솔. `pw minio-secret root-user` / `root-password` |
| https://s3.oneinchmarket.local | 자체 인증 | `minio-headless:9000` | S3 API — `mc`·`s3cmd`·boto3. 서명 인증 |
| https://trino.oneinchmarket.local | **없음** | `trino-headless:8080` | 웹 UI(`/ui/`) + **JDBC**(§3-b). ★ `http-server.process-forwarded=true` 가 있어야 한다 — 없으면 전부 406 이다 |
| https://spark-history.oneinchmarket.local | **없음** | `spark-history-headless:18080` | 완료된 Spark 앱 |
| https://spark-ui.oneinchmarket.local | **없음** | `spark-connect-headless:4040` | Spark Connect 세션 UI |
| https://livy.oneinchmarket.local | **없음** | `livy-headless:8998` | Spark REST 세션 |
| https://hdfs.oneinchmarket.local | **없음** | `hadoop-namenode:9870` | NameNode UI. ★ 파일 조작은 Knox 의 WebHDFS 를 쓸 것 |
| https://hbase.oneinchmarket.local | **없음** | `hbase-master:16010` | HBase Master |
| https://hbase-rs.oneinchmarket.local | **없음** | `hbase-regionserver:16030` | RegionServer |
| https://hive.oneinchmarket.local | **없음** | `hive-server-headless:10002` | ★★ **게이트웨이 경유로는 500 이다** — Jetty 가 Host 헤더의 포트로 핸들러를 고른다(§6). JDBC 는 Knox 경유(§4) |
| https://app-admin.oneinchmarket.local | 도구용 | `admin-headless:3000` | 관리 프런트 |
| https://app-api.oneinchmarket.local | 도구용 | `cmmn-api-headless:8080` | ★ 과금 경로가 아니다(과금은 `api` 호스트 · JWT 필수). 루트는 404 이고 `/actuator/health` 가 200 이다 |
| https://www.oneinchmarket.local | 도구용 | `nginx:80` | 정적 프런트 |
| https://openreplay.oneinchmarket.local | 자체 인증 | `frontend-openreplay:8080` | 세션 리플레이. ★ 전제 2건이 미해결이라 데이터가 비어 있다 |
| https://openreplay-api.oneinchmarket.local | 도구용 | `api-openreplay:8080` | 위 프런트가 부르는 API |
<!-- GENERATED:ui-table END -->

**실측 전수(2026-10-11 · 443 으로)**: 56 중 **48 이 루트(`/`)에서 바로** 응답하고,
나머지 8 은 **그 앱의 실제 입구에서** 응답한다 — `app-api /actuator/health` 200 ·
`loki /ready` 200 · `openfga /healthz` 200 · `tempo /status` 200 ·
`trino /v1/info` 200 · `gravitee-api /management` 301 ·
`knox /gateway/oim/webhdfs/v1/?op=LISTSTATUS` 401(인증 요구 — 정상) ·
`openmeter /api/v1/meters` 200. **`hive` 하나만 500** 이고 그것은 §6 에 적은
Jetty 제약이다. 즉 **55/56 이 쓸 수 있는 상태**다.

> ★ 루트가 404 인 것을 결함으로 읽지 말 것 — 여러 앱의 `/` 는 입구가 아니다.
> **Envoy 자신의 404 와 가르는 값은 `content-length: 0` 이다**(Gotcha 185).

비밀번호 조회 헬퍼 — 노드에서 돌린다:

```bash
ssh root@192.168.0.103
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
pw() { kubectl -n local get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; echo; }
pw grafana-secret admin-password
```

### ★★ 인증이 없는 호스트 — 집 밖으로 내보내지 말 것

<!-- GENERATED:open-list START -->
**19 종** — `prometheus.oneinchmarket.local` · `alertmanager.oneinchmarket.local` · `pyroscope.oneinchmarket.local` · `pyrra.oneinchmarket.local` · `temporal.oneinchmarket.local` · `flink.oneinchmarket.local` · `akhq.oneinchmarket.local` · `apicurio.oneinchmarket.local` · `kafka-bridge.oneinchmarket.local` · `ranger-solr.oneinchmarket.local` · `solr.oneinchmarket.local` · `trino.oneinchmarket.local` · `spark-history.oneinchmarket.local` · `spark-ui.oneinchmarket.local` · `livy.oneinchmarket.local` · `hdfs.oneinchmarket.local` · `hbase.oneinchmarket.local` · `hbase-rs.oneinchmarket.local` · `hive.oneinchmarket.local`
<!-- GENERATED:open-list END -->

이것들은 **누구든 주소를 알면 그대로 들어온다.** 그리고 이 배치에서는
**출발지를 L3 로 좁힐 수 없다** — `externalIPs` 는 Cilium 의 eBPF 가 처리해
호스트의 iptables INPUT 이 그 트래픽을 보지 못하고, `ipBlock` CIDR 로는 node
신원이 매칭되지 않는다(Gotcha 187·197). 그러므로:

* **신뢰 경계는 LAN 이다.** 공유기에서 443 을 포트포워딩하지 말 것.
* 밖에서 봐야 하면 **VPN** 을 쓴다(§5). VPN 에 붙으면 LAN 에 있는 것과 같다.
* 더 좁히려면 Cilium 의 `bpf-lb-source-range-all-types=true` +
  `loadBalancerSourceRanges` 가 필요하고, 그것은 **Cilium 전역 설정 변경**이라
  모든 오버라이드를 다시 줘야 한다(Gotcha 141·168).

> ★ 컴포넌트별로 인증을 덧씌우는 것(oauth2-proxy 를 Istio `ext_authz` 로)은
> **하지 않았다.** 그러려면 `meshConfig.extensionProviders` 를 고쳐야 하는데
> 그 자리는 **과금 계량의 액세스 로그 공급자**가 쓰고 있고,
> `istioctl install` 이 그것을 지운 적이 있다(Gotcha 158 — 트래픽은 정상인데
> 청구만 사라졌다). 과금 경로를 건드리는 변경이라 지시를 받아야 한다.

### ★★★ 레이트 리밋 — 범위를 고쳤다

전에는 레이트 리밋이 게이트웨이의 **모든 가상 호스트**에 붙어 있었다(실측
58/58). descriptor 가 고정값 `[scope=api]` 라 **인증 없는 트래픽 전체가 분당
10건** 하나의 버킷을 썼고, 그 상태로는 외부 노출이 성립하지 않는다 —
브라우저가 UI 한 페이지를 열면 요청이 수십 건이라 즉시 429 다(실제로 전수
측정이 10건에서 막혔다).

쿼터는 ADR-072 의 **과금 대상 API** 의 것이므로 그 vhost 로 좁혔다. 지금은
`rate_limits` 가 붙은 vhost 가 **1개**(`api.oneinchmarket.local:443`)이고,
grafana 에 30건을 연속으로 쳐도 **200 이 30 · 429 가 0** 이다.

> ★ 테넌트별 상향 쿼터를 **헤더로 위조할 수 없다**(실측). `x-oim-tenant` 는
> `RequestAuthentication` 의 `outputClaimToHeaders` 가 토큰의 `tenant`
> 클레임으로 덮으므로, 클라이언트가 그 헤더를 보내도 쿼터가 오르지 않는다.
> 설계가 의도대로 동작한다는 뜻이다.

---

## 3. 데이터 계층 — DBeaver 와 전용 클라이언트

접속 주소는 **노드 IP + 고정 NodePort** 다. 호스트명·DNS 가 필요 없다.

<!-- GENERATED:tcp-table START -->
| 접속 주소 | 대상 | 접속 정보 |
|---|---|---|
| `192.168.0.103:30432` | **PostgreSQL 18.6** -> `postgresql-headless:5432` | `postgres` / `pw postgresql-secret postgres-password` · DB 13개 · ★ Show all databases 를 켤 것 |
| `192.168.0.103:30306` | **MariaDB 12.3** -> `mariadb-headless:3306` | `root` / `pw mariadb-secret root-password` · DB `cmmn` |
| `192.168.0.103:30307` | **ShardingSphere 5.5 (PG 와이어)** -> `shardingsphere:3307` | `proxyadmin` / `pw shardingsphere-secret proxy-password` · 논리 DB `oim` |
| `192.168.0.103:30633` | **ProxySQL 4.0 (MySQL 와이어)** -> `proxysql:6033` | `cmmn-api` / `pw cmmn-api-secret db-password` · DB `cmmn` |
| `192.168.0.103:30017` | **MongoDB 7.0** -> `mongodb-headless:27017` | `root` / `pw mongodb-secret root-password` · ★ `authSource=admin` 필수 |
| `192.168.0.103:30379` | **Redis 8.10** -> `redis-headless:6379` | `pw redis-secret redis-password` · ★★ 과금 중복제거 키 — `FLUSHALL` 금지(Gotcha 16) |
| `192.168.0.103:30123` | **ClickHouse 26.8 (HTTP)** -> `clickhouse-headless:8123` | ★ `default` 사용자가 없다 — `openmeter` 또는 `openreplay`(Gotcha 27) |
| `192.168.0.103:30900` | **ClickHouse (native)** -> `clickhouse-headless:9000` | 같은 인스턴스. 네이티브 프로토콜 |
| `192.168.0.103:30000` | **HiveServer2 (Thrift)** -> `hive-server-headless:10000` | ★ 인증이 없다. **Knox 경유를 권한다**(§4) |
| `192.168.0.103:30083` | **Hive Metastore (Thrift)** -> `hive-metastore-headless:9083` | 테이블 목록만 보려면 PG 의 `hive_metastore` 가 더 빠르다 |
| `192.168.0.103:30389` | **DS389 LDAP** -> `ds389-headless:3389` | `pw ds389-secret dm-password` · Apache Directory Studio·`ldapsearch` |
| `192.168.0.103:30636` | **DS389 LDAPS** -> `ds389-headless:3636` | 같은 디렉터리. TLS |
| `192.168.0.103:30092` | **Kafka 9092** -> `kafka-headless:9092` | ★★ 브로커가 클러스터 안 이름을 광고한다 — §3 의 제약을 볼 것. AKHQ 가 정답이다 |
| `192.168.0.103:30002` | **Spark Connect (gRPC)** -> `spark-connect-headless:15002` | PySpark 의 `SparkSession.builder.remote` 로 붙는다 |
| `192.168.0.103:30181` | **ZooKeeper** -> `zookeeper-headless:2181` | `zkCli.sh` |
<!-- GENERATED:tcp-table END -->

**실측 검증(2026-10-11)**: 15개 전부 nginx stream 상태 `200`(upstream 연결
성공) · 실패 **0건**. 프로토콜 왕복도 확인했다 — PostgreSQL·ShardingSphere 의
SSLRequest 응답 `N` · MariaDB·ProxySQL greeting 60바이트 · Redis `-NOAUTH` ·
ClickHouse `/ping` → `Ok.` · ZooKeeper `ruok` → `imok` · MongoDB 의 HTTP 전용
안내 메시지.

### 3-a. DBeaver 설정 예 — PostgreSQL (가장 중요한 것)

과금 원장·인증·메타데이터가 전부 여기 있다.

| DBeaver 항목 | 값 |
|---|---|
| 드라이버 | **PostgreSQL** |
| Host / Port | `192.168.0.103` / `30432` |
| Database | `postgres` (접속 후 전환) |
| Username | `postgres` |
| Password | `pw postgresql-secret postgres-password` |
| SSL | **끔** |
| JDBC URL | `jdbc:postgresql://192.168.0.103:30432/postgres` |

> **Show all databases** 를 켜야 13개가 다 보인다 — 연결 설정 → *PostgreSQL*
> 탭. `openmeter` 가 과금 원장이고 `ranger` 의 `x_auth_sess` 가 Gotcha 11 의
> 계정 잠금 자리다.

### 3-b. Trino — JDBC 는 게이트웨이로 간다

Trino 는 HTTP 프로토콜이라 **TCP 프록시가 아니라 HTTPS 게이트웨이**를 쓴다.

| 항목 | 값 |
|---|---|
| 드라이버 | **Trino** |
| JDBC URL | `jdbc:trino://trino.oneinchmarket.local:443/?SSL=true` |
| Username | 아무 값(예: `admin`) — 인증이 없다 |

> `gateway-ca` 를 신뢰하지 않았으면 `&SSLVerification=NONE` 을 붙인다.
>
> ★★ **2026-10-11 에 고친 것**: 게이트웨이가 붙이는 `X-Forwarded-For` 를
> Trino 가 거부해 **모든 요청이 406** 이었다. 증상이 원인을 가리키지 않는다 —
> 406 Not Acceptable 은 Accept 헤더 문제로 읽히고, 실제로 `Accept:
> application/json` 을 붙여도 그대로 406 이다. 진짜 단서는 **본문**이었다:
> `Server configuration does not allow processing of the X-Forwarded-For
> header`. `http-server.process-forwarded=true` 를 넣어 `/ui/` 200 ·
> `/v1/info` 200 이 됐다.

### 3-c. DBeaver CE 로는 안 되는 것

**Community Edition 은 관계형 DB 만 지원한다.**

| DB | CE | 대안 |
|---|:-:|---|
| PostgreSQL · MariaDB · ClickHouse · Trino · Hive | O | — |
| **MongoDB** | X | MongoDB Compass — `mongodb://root:<pw>@192.168.0.103:30017/?authSource=admin` |
| **Redis** | X | RedisInsight · `redis-cli -h 192.168.0.103 -p 30379 -a <pw>` |
| **OpenSearch** | X | `https://opensearch.oneinchmarket.local` 또는 OSD 의 Dev Tools |

### 3-d. ★ 이 경로로 되지 않는 것 — 프로토콜이 주소를 되돌려주기 때문이다

| 대상 | 왜 | 쓸 것 |
|---|---|---|
| **Kafka** `30092` | 브로커가 메타데이터로 **자기 광고 주소**(`kafka-headless:9092`)를 돌려준다. 클라이언트는 bootstrap 뒤 그 이름으로 다시 붙으려 하고 밖에서는 풀리지 않는다 | **AKHQ**(`akhq.oneinchmarket.local`). 꼭 네이티브로 붙어야 하면 `advertised.listeners` 에 외부 리스너를 더해야 하고 그것은 base 매니페스트 변경이다 |
| **HDFS RPC** `8020` | NameNode 가 **DataNode 주소**를 돌려준다. DataNode 는 노출돼 있지 않다 | **Knox 의 WebHDFS**(§4) — 모든 홉이 Knox 를 지난다 |
| **HBase RPC** `16000/16020` | 위와 같은 이유(RegionServer 주소) | **Knox 의 HBase REST**(§4) |

> ★ 이것은 설정 실수가 아니라 **프로토콜의 성질**이다. "포트를 열었는데 안
> 된다" 로 읽히지만, 열린 포트로 bootstrap 은 성공하고 **그 다음 홉에서**
> 죽는다. 증상이 원인과 멀다. 그래서 포트는 열어 두되 이 표를 함께 둔다 —
> 정책을 의심하며 시간을 쓰지 않도록.

---

## 4. Knox — Hadoop 계층의 정식 진입점

`https://knox.oneinchmarket.local/gateway/oim/...` 하나로 WebHDFS · Hive ·
HBase REST 가 다 들어온다. **인증은 DS389 LDAP** 이고 Knox 가 인증된 사용자
이름을 백엔드로 넘긴다.

```bash
# 사용자 예시: ranger-sync (DS389 의 ou=people)
PW=$(ssh root@192.168.0.103 "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n local get secret ds389-secret -o jsonpath='{.data.sync-password}'" | base64 -d)

curl -u "ranger-sync:$PW" \
  'https://knox.oneinchmarket.local/gateway/oim/webhdfs/v1/?op=LISTSTATUS'
```

| 서비스 | 경로 | 확인 |
|---|---|---|
| **WebHDFS** | `/gateway/oim/webhdfs/v1/?op=LISTSTATUS` | 200 + 디렉터리 목록 |
| **HBase REST** | `/gateway/oim/hbase/version/cluster` | 200 + 버전 |
| **Hive JDBC** | 아래 | `show databases` 동작 |

**DBeaver 에서 Hive 를 Knox 경유로:**

```text
드라이버   Apache Hive
JDBC URL  jdbc:hive2://knox.oneinchmarket.local:443/default;ssl=true;transportMode=http;httpPath=gateway/oim/hive
Username  <DS389 사용자>
Password  <그 비밀번호>
```

> ★ **실측으로 TLS 오리지네이션이 확인됐다** — 자격 없이 부르면 **401** 이다.
> 그 401 은 Knox 자신의 응답이므로 게이트웨이 → Knox 구간의 HTTPS 가 성립한
> 것이다(실패였다면 502 였다). DS389 에 없는 사용자·틀린 비밀번호도 401 이라
> 세 경우가 구분되지 않으니 자격을 먼저 확인할 것.
>
> ★★ **Knox 는 인증만 하고 인가는 하지 않는다.** Ranger 플러그인이 HDFS 에만
> 있고 Hive·HBase 쪽은 비호환으로 빠져 있다(Gotcha 38·41·42). 즉 인증을 통과한
> 사용자는 HDFS POSIX 퍼미션 외에는 제한이 없다. **알려진 공백이다.**
>
> ★ 게이트웨이 → Knox 구간의 TLS 는 `destinationrules.yaml` 이 연다.
> 한쪽만 고치면 이 호스트만 502 가 된다.

---

## 5. VPN — 집 밖에서, 그리고 LAN 밖의 기기를 위해

WireGuard 를 노드에 둔다. **VPN 에 붙으면 LAN 에 있는 것과 같아져** 위의 모든
경로가 그대로 동작한다 — 호스트명·포트·접속정보가 바뀌지 않는다.

```bash
# 피어를 만든다 (이름은 기기별로 · 소문자·숫자·하이픈만)
ssh root@192.168.0.103 'bash /root/oneinchmarket-dev/local/external-access-node.sh --peer laptop'
# 설정을 가져간다 (개인키가 들어 있어 화면에 찍지 않는다)
scp root@192.168.0.103:/etc/wireguard/peers/laptop.conf .
```

그 파일의 `Endpoint = REPLACE_WITH_PUBLIC_ADDRESS:51820` 을 바꾼다 — 집
안에서만 쓰면 `192.168.0.103`, 밖에서 쓰면 공유기의 공인 주소(또는 DDNS).
공유기에서 **UDP 51820 만** 포워딩하면 밖에서 붙는다.

> ★ VPN 서브넷은 **`172.30.0.0/24`** 다. `10.88.x` 류를 쓰지 않는 이유가
> **둘** 있고 둘 다 실측이다: ① 이 클러스터의 **Pod CIDR 이 `10.0.0.0/8`** 이라
> 10.x 는 그 안에 들어간다 ② 이 노드에는 **`podman0` 이 `10.88.0.1/16`** 으로
> 떠 있다(로컬 이미지 빌드에 쓰인다). 둘 중 하나만 봤다면 다른 쪽에서 물렸다.
>
> ★★ 클라이언트에 미는 라우트는 **`192.168.0.0/24` 뿐**이다. Pod·Service
> CIDR 을 밀지 않는다 — 그쪽으로 직접 가면 신원이 없어
> `default-deny-ingress` 에 막히고(노드발 트래픽에는 Cilium 이
> `remote-node` 신원을 주는데 `ipBlock` CIDR 로는 그것이 매칭되지 않는다,
> Gotcha 187·197), 게이트웨이·db-gateway 를 지나는 경로는 **신원이 있어서**
> 그 문제가 없다. 즉 **우회로를 만들지 않는 쪽이 보안도 단순함도 낫다.**
>
> ★ DNS(`192.168.0.103`)도 함께 밀어 `*.oneinchmarket.local` 이 VPN 안에서
> 풀린다. 그리고 다른 노드(104)로 가는 트래픽은 노드가 `enp86s0` 으로
> MASQUERADE 한다 — 첫 판이 그 인터페이스를 `lo` 로 잡아 **조용히 반쪽만**
> 동작했고, 스크립트가 지금은 그것을 수리한다.

---

## 6. 고친 것과 남은 것

### 고친 것 ①: 브라우저가 부르는 주소가 박혀 있던 앱 다섯

SPA 는 **브라우저에서** 백엔드를 직접 부르므로 `localhost` 가 박혀 있으면
외부에서 흰 화면이 된다. `overlays/local/patches/external-urls-local.yaml` 이
그 값을 외부 호스트명으로 덮는다.

| 앱 | 설정 | 이전 -> 이후 |
|---|---|---|
| `apicurio-ui` | `REGISTRY_API_URL` | `http://localhost:8080/...` -> `https://apicurio-registry.../apis/registry/v3` |
| `dependency-track-frontend` | `API_BASE_URL` | `http://localhost:8087` -> `https://dtrack-api...` |
| `gravitee-console` | `MGMT_API_URL` | `http://localhost:8083/management` -> `https://gravitee-api.../management` |
| `gravitee-portal` | `PORTAL_API_URL` | `http://localhost:8083/portal` -> `https://gravitee-api.../portal` |
| `temporal-ui` | `TEMPORAL_CORS_ORIGINS` | `http://localhost:18088` -> `https://temporal...` |

> ★ 이 값들은 **port-forward 용 주소였다.** 바꾸면 ACCESS.md 가 안내하는
> port-forward 경로가 그만큼 깨진다 — 브라우저가 `localhost:8081` 대신
> `apicurio-registry.oneinchmarket.local` 을 부르게 되므로, port-forward 만
> 띄우고 hosts/DNS 를 안 하면 목록이 비어 보인다. 둘 다 되게 하려면 앱마다
> CORS·다중 origin 설정이 필요하고 그것은 앱마다 다르다 — 하나를 고르는 쪽이
> 정직하다. ACCESS.md 에 그 사실을 적어 두었다.

### 고친 것 ②: 레이트 리밋 범위와 Trino

| 무엇 | 증상 | 고친 것 |
|---|---|---|
| 레이트 리밋이 **모든 vhost** 에 붙어 있었다 | 인증 없는 트래픽 전체가 분당 10건 — 브라우저가 즉시 429 | `ratelimit-envoyfilter.yaml` 의 `VIRTUAL_HOST` 패치를 `api.oneinchmarket.local:443` 으로 좁혔다. 실측 58/58 -> **1/58** |
| Trino 가 `X-Forwarded-For` 를 거부 | **모든 요청 406** · 본문에만 사유 | `http-server.process-forwarded=true` |

### 남은 것

| 무엇 | 지금 상태 | 왜 그대로 두었나 |
|---|---|---|
| **HiveServer2 웹 UI**(`hive` 호스트) | 게이트웨이 경유로 **500** | Jetty 가 **Host 헤더의 포트**로 핸들러를 고른다(`No handler found for port 80`). 게이트웨이는 Host 를 `<이름>:10002` 로 만들어 줄 수 없다 — `URLRewrite.hostname` 은 포트를 담지 못한다. ★ **대조군이 선재 결함이 아님을 말해 줬다**: 클러스터 안에서 같은 경로가 **200** 이다. 주변 UI 하나 때문에 구조를 비틀지 않는다 — 테이블 목록은 PG 의 `hive_metastore` 가 더 빠르고(ACCESS.md), 질의는 Knox JDBC 다 |
| **Backstage 의 Keycloak OIDC** | 외부에서 로그인이 깨질 수 있다 | 백엔드는 `keycloak-headless:8080` 으로 토큰을 교환하고 브라우저는 `keycloak...local` 로 간다 — `iss` 가 갈린다(Gotcha 69·136). 처방은 **양쪽을 같은 이름으로 맞추는 것**이고, 그러려면 CoreDNS 가 클러스터 안에서도 `*.oneinchmarket.local` 을 게이트웨이로 풀어 줘야 한다. ★ 그 CoreDNS 오버라이드는 **지금 넣지 않았다** — 쓰는 소비자가 없는 기전을 남기지 않는다(Gotcha 131). Backstage 를 고치는 날 함께 넣을 것 |
| **과금 경로 쿼터의 행동 검증** | 런타임 설정으로만 확인했다 | `api` 호스트는 토큰 없이는 RBAC 403 에서 멈춰 레이트 리밋 필터에 닿지 않는다. 토큰을 쓰려면 스모크 클라이언트가 필요한데 그 `tenant` 클레임이 **`acme-corp` 로 하드코딩**돼 있고 그것은 **구독이 있는 실제 고객**이다 — 시험이 곧 청구 이벤트가 되고(CLAUDE.md 금지), 게다가 그 쿼터는 분당 600 이라 11건으로는 429 가 나오지도 않는다. 비청구 테넌트 클라이언트를 따로 만들면 행동 검증이 가능하다 |
| **ArgoCD · Hubble UI** | 외부 경로가 없다 | `argocd`·`kube-system` 네임스페이스에 있고 리스너가 `allowedRoutes.namespaces.from: Same` 이다. 넘으려면 `ReferenceGrant` 가 필요하다 |
| **GitLab 컨테이너 레지스트리** | 밖에서 당길 수 없다 | 평문 HTTP 이고 주소가 클러스터 안 이름이다(§9-8 로 미뤄져 있다) |
| **컴포넌트별 인증 덧씌우기** | 없다 | §2 의 경고 참조 — 과금 계량 설정과 같은 자리를 건드린다 |

---

## 7. 자주 걸리는 것

| 증상 | 원인 |
|---|---|
| 브라우저가 **이름을 못 찾는다** | §1-b 를 안 했다. `nslookup grafana.oneinchmarket.local 192.168.0.103` 으로 가를 것 |
| **연결 거부**(`ERR_CONNECTION_REFUSED`) | `ingress-external` Service 가 없다. `kubectl -n local get svc ingress-external` 과 `cilium-dbg service list | grep ExternalIPs` 로 볼 것 |
| **인증서 경고** | §1-c 를 안 했다. 또는 `a.b.` 같은 2단계 이름을 썼다(와일드카드는 1단계) |
| **`404` 에 `content-length: 0`** | 그 호스트의 HTTPRoute 가 없다 — Envoy 자신의 404 다. 본문이 있으면 **백엔드의** 404 이고 경로가 틀린 것이다(여러 앱의 루트는 입구가 아니다) |
| **`502`** | 백엔드가 HTTPS 인데 DestinationRule 이 없다(또는 반대다) |
| **`403`** | `api.oneinchmarket.local` 은 **JWT 가 필수**다(Gotcha 18). 정상 동작이다 |
| **`406`** | Trino 다. `http-server.process-forwarded=true` 가 빠졌다 — 본문을 읽을 것 |
| **`429`** | `api` 호스트의 쿼터다(분당 10건 · 테넌트가 있으면 60~3000). 다른 호스트에서 나오면 레이트 리밋 범위가 되돌아간 것이다 |
| **`500` 에 `No handler found for port`** | HiveServer2 다. §6 의 남은 것 참조 |
| 특정 호스트만 **리셋·502** | `AuthorizationPolicy` 가 그 백엔드를 선택한다. `authz-external-access.yaml` 에 게이트웨이 신원이 있는지 볼 것 |
| DBeaver **타임아웃** | `db-gateway` 파드와 `authz-external-access.yaml` 을 볼 것. **TCP 는 열리고 프로토콜에서 죽는다** |
| 어제까지 되던 것이 안 된다 | ArgoCD 가 동기화하며 되돌렸을 수 있다 — git 에 들어가 있는지 확인(Gotcha 119·198) |

판정은 **층을 갈라서** 한다 — 아래 값들이 서로 다른 뜻이다(Gotcha 157·185):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --resolve grafana.oneinchmarket.local:443:192.168.0.103 \
  https://grafana.oneinchmarket.local/
#   000 = 닿지 않는다   404 = 라우트 없음   502 = 백엔드   200/302 = 정상
```

> ★ **`-H 'Host: ...'` 로 시험하지 말 것** — 그것은 HTTP 헤더일 뿐 TLS SNI 를
> 바꾸지 않아 게이트웨이가 인증서를 못 고르고 연결을 끊는다(`000`). 반드시
> `--resolve` 를 쓴다(Gotcha 157).
>
> ★★ 전수로 쓸어 볼 때는 **재는 도구가 부하가 되지 않게** 할 것. 첫 전수
> 측정이 레이트 리밋에 걸려 47개를 429 로 보고했고, 그것을 결함으로 읽으면
> 멀쩡한 것을 고치게 된다(Gotcha 192 ①).

---

## 8. 클러스터를 다시 세우면

| 해야 할 것 | 왜 |
|---|---|
| `local/external-access-node.sh` | 와일드카드 DNS·VPN 은 **노드 상태**다(Gotcha 126 과 같은 부류) |
| WireGuard 피어 재발급 | 서버 키가 새로 생기면 기존 피어 설정이 무효다 |
| `local/safeline-bootstrap.sh` | `api` 호스트의 백엔드가 SafeLine 이고 사이트 정의가 mgt 의 DB 에만 있다(Gotcha 159) |
| `local/gravitee-bootstrap.sh` | API 정의가 Mongo 에만 있다 |
| 노드 IP 확인 | `external-ips-service.yaml` 에 주소가 박혀 있다 |

생성물이 뒤처지지 않았는지는 게이트로 본다:

```bash
python3 local/render-external-access.py --check    # 뒤처지면 1
```

---

## 관련 문서

- [ACCESS.md](./ACCESS.md) — `port-forward` 경로(이 문서가 깨졌을 때의 대조군)
- [../docs/LOCAL-DEPLOYMENT.md](../docs/LOCAL-DEPLOYMENT.md) — §8 실배포 기록
- [../CLAUDE.md](../CLAUDE.md) — Gotchas 전체
