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
