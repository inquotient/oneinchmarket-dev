# L0 랩 — OPNsense · Suricata · Zeek 검증 환경

`docs/ADR-CANDIDATES.md` ADR-028 의 L0 계층을 **로컬에서 실제 인라인 경로로**
검증하기 위한 Hyper-V 랩이다. 클러스터와 분리되어 있다.

## 왜 클러스터와 분리하는가

`docs/LOCAL-DEPLOYMENT.md §1` 이 WSL2 로는 `OPNsense 경계 통제 · 남–북 IDS` 를
**검증 불가**로 판정한다. 이유는 용량이 아니라 구조다 — WSL2 의
`vEthernet (WSL)` 어댑터는 WSL 서비스가 관리하는 NAT 스위치에 묶여 있어
임의의 vSwitch 에 붙이거나 다른 VM 을 게이트웨이로 끼워 넣을 수 없다.

k3s 를 Hyper-V 로 옮기면(ADR-051 A안) 해결되지만 클러스터 재구축이 따른다.
이 랩은 그 대신 **분리된 인라인 경로**를 만든다. 검증 대상은
"OPNsense 가 트래픽을 실제로 보는가"이지 "k3s 가 그 뒤에 있는가"가 아니다.

## 토폴로지

```
[Windows 호스트]
  L0-WAN (External, 물리 NIC 공유) ──┐
                                     ├─ L0-OPNsense   6 GiB · 2 vCPU
  L0-LAN (Internal, 고립) ───────────┘        │
                                              └─ L0-Target  2 GiB · 2 vCPU
```

`L0-LAN` 이 Internal 이라 **target 은 OPNsense 없이 밖으로 나갈 수 없다.**
Caldera 격리(§8-26)와 같은 발상이다 — 우회 가능한 경로를 아예 두지 않는다.

## 전제

| | 조건 | 확인 |
|---|---|---|
| 1 | Hyper-V 역할 활성화 | `Get-Service vmms` 가 존재해야 한다 |
| 2 | 메모리 8 GiB 여유 | `.wslconfig` `memory=44GB` 적용 후 |

**2번이 선행이다.** `§8-27` 의 requests 정정(예약 80%→67%)으로 WSL 캡을
56GB → 44GB 로 내릴 수 있게 되었고, 그렇게 만든 12 GiB 안에 랩이 든다.

## 실행

```powershell
# 관리자 PowerShell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
# 재부팅 (이때 .wslconfig 도 함께 적용된다)

.\setup-l0-lab.ps1 -IsoPath C:\iso\OPNsense-dvd.iso -TargetIsoPath C:\iso\ubuntu-server.iso
```

OPNsense 설치 프로그램은 콘솔 대화형이라 자동화하지 않는다. 스크립트는 VM·스위치까지
만들고 이후 절차를 출력한다.

## 검증 항목

| 항목 | 이것이 답하는 질문 |
|---|---|
| Suricata 인라인 IPS | 룰이 **차단**하는가, 관측만 하는가 |
| 오탐률 | 정상 트래픽이 끊기지 않는가 — 오탐이 곧 장애다 |
| Zeek 메타데이터 | conn/dns/http/ssl 로그가 기대한 필드를 갖는가 |
| ADR-031 정규화 | EVE JSON · Zeek 로그 → Logstash → Wazuh Indexer |

## 한계

- **k3s 트래픽은 지나지 않는다.** 클러스터는 WSL2 에 그대로 있다
- 물리 NIC 을 공유하는 External 스위치라 실제 경계망과 다르다
- 여기서 검증되는 것은 **룰셋과 로그 파이프라인**이지 용량·성능이 아니다

클라우드 dev 로 옮길 때의 배치 판단은 ADR-028 참조 — Vultr 는 VPC 라우트
테이블이 없어 **VPC-only 인스턴스**(공인 IP 부재)로 강제한다.

## H5 검증 — 이설 전에 먼저 할 것

`verify-h5.sh` 를 **L0-Target(Hyper-V Ubuntu 게스트) 안에서** 실행한다.

```bash
sudo ./verify-h5.sh
```

### 왜 순서가 이런가

ADR-051(A안) 전면 실행 = k3s 를 Hyper-V 다중 노드로 이설이다. 실측 기준으로
**메모리는 들어간다**:

```
                     오버헤드   워크로드    VM 합    Windows 몫
2노드 (master+worker)   9.5      35.16      44.7      18.7 GiB
3노드 (master+2worker) 13.5      35.16      48.7      14.7 GiB
```

`DEPLOYMENT.md §4-3` 의 "64 GB 로는 불가" 판정은 **실제 소요 77.9 GB** 를
전제하는데, 그 산정 방식은 7단계에서 4배 과대로 판명된 것과 같다(§8-26).
실측 requests 는 35.16 GiB 다.

그런데 대가가 메모리가 아닌 곳에 있다.

- **정적 분할** — H1 이 동적 메모리를 금지하므로 VM 간 슬랙이 넘어가지 않는다.
  지금은 43 GiB 한 풀이 어디서 터지든 흡수한다
- **PVC 27개 재생성** — 전부 `WaitForFirstConsumer` + `rancher.io/local-path`
  로 노드 로컬이다. PostgreSQL·GitLab·ES·MinIO·Kafka 데이터가 새로 만들어진다
- **H5 `[UNVERIFIED]`** — Hyper-V 합성 NIC 에서 Cilium eBPF 가 도는지 확인된 바 없다

**앞의 둘은 되돌릴 수 없고, 셋째는 랩 VM 한 대로 미리 확인할 수 있다.**
그래서 H5 를 먼저 본다.

### 무엇을 보는가

| # | 항목 | 실패의 의미 |
|:-:|---|---|
| 0 | `hv_netvsc` · BTF · `xt_TPROXY` | BTF 없으면 Cilium·Tetragon CO-RE 불가 — 그 자체로 중단 사유 |
| 1 | k3s (동일 플래그) | `--flannel-backend=none` 이라 CNI 전까지 NotReady 가 정상 |
| 2 | Cilium (M1·M2 동일) | **H5 의 핵심 질문** |
| 3 | Service 경유 통신 | socketLB 가 `connect()` 훅에서 동작하는가 |
| 4 | NetworkPolicy 강제 | 통과하지 못하면 **조용한 보안 우회**(ADR-043 M1 의 실패 모드) |
| 5 | XDP 상태 | 참고. H5 는 "기능은 정상이나 성능 기준선으로 쓰지 말 것" 이다 |

**4번이 가장 중요하다.** ADR-043 이 지적한 M1 의 실패 모드가 "설정이 틀려도
에러 없이 통신은 정상 동작하고 정책만 적용되지 않는다" 이기 때문이다.
통신이 되는 것만 보고 통과로 판정하면 안 된다.
