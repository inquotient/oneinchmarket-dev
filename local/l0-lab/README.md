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

### 1. 이미지 준비 (WSL, 관리자 불필요)

```bash
./prepare-target-vm.sh          # Ubuntu 클라우드 이미지 → VHDX + cloud-init 시드
```

`verify-h5.sh` 가 게스트의 `/usr/local/bin/` 에 심어진다. 콘솔에서 바로 돌릴 수 있다.

랩 전용 SSH 키(`$OUT/L0-Target-key`)를 만들어 시드에 심는다. 콘솔 비밀번호만으로는
호스트에서 자동 실행을 할 수 없기 때문이다 — Windows OpenSSH 클라이언트는 비밀번호를
표준입력으로 받지 않는다. **개인키는 `$OUT`(레포 밖)에 남는다. 커밋 대상이 아니다.**

`instance-id` 는 `user-data` 의 해시다. cloud-init 은 per-instance 모듈을 instance-id 가
바뀔 때만 다시 도므로, 고정값이면 시드를 고쳐 붙여도 조용히 무시된다.

OPNsense ISO 는 `https://pkg.opnsense.org/releases/<버전>/` 에서 받아 `bunzip2` 로 푼다.
**국내 미러가 없다** — kakao·naver·harukasan 모두 미보유를 확인했다(2026-09-03).
해외 미러는 20~25 KB/s 대라 471 MB 에 수 시간이 걸린다. `curl -C -` 로 이어받을 것.

### 2. VM 생성 (관리자 PowerShell)

```powershell
.\setup-l0-lab.ps1 -IsoPath C:\Users\<user>\iso\OPNsense-26.7-dvd-amd64.iso
```

OPNsense 설치 프로그램은 콘솔 대화형이라 자동화하지 않는다. 스크립트는 VM·스위치까지
만들고 이후 절차를 출력한다.

**Hyper-V 는 관리자 권한이 필요하다.** 사용자가 `Hyper-V Administrators` 그룹에
없으면 일반 세션에서 `Get-VMSwitch` 조차 거부된다.

`prepare-target-vm.sh` 를 먼저 돌렸으면 스크립트가 **그 VHDX 를 붙인다**(빈 디스크를
만들지 않는다). Secure Boot 는 끄지 않고 템플릿만 `MicrosoftUEFICertificateAuthority`
로 바꾼다 — Gen2 의 기본값 `MicrosoftWindows` 로는 shim 서명을 신뢰하지 않아
**Ubuntu 가 부팅하지 않는다.**

> ★ `.ps1` 은 **BOM 이 있어야 한다.** 없으면 PowerShell 5.1 이 CP949 로 읽어
> 한글 주석이 따옴표 짝을 깨뜨리고, 뒤따르는 코드가 문자열로 흡수된 채
> **파싱 오류 없이** 실행된다. 실제로 이 스크립트가 target VM 생성부를 통째로
> 잃은 적이 있다 — `docs/LOCAL-DEPLOYMENT.md §8-30`.

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

### 검증 중에는 NIC 을 옮긴다

H5 검증은 k3s·Cilium 을 내려받으므로 **인터넷이 필요하다.** 그런데 `L0-LAN` 은
Internal 이고 OPNsense 가 아직 게이트웨이 역할을 하기 전이라 출구가 없다.
그래서 검증 동안만 NIC 을 Hyper-V 내장 `Default Switch` 로 옮긴다.

```powershell
Connect-VMNetworkAdapter -VMName L0-Target -SwitchName 'Default Switch'
```

**`L0-WAN`(External)이 아니라 `Default Switch`(NAT)를 쓴다.** External 은 물리
LAN 에 그대로 노출되는데, 이 VM 에는 랩 전용 약한 자격(`ubuntu`/`l0lab`,
비밀번호 인증 허용)이 들어 있다. NAT 스위치는 나가는 통신만 되고 물리망에서
접근되지 않는다.

검증이 끝나면 `L0-LAN` 으로 되돌린다 — **되돌리지 않으면 "target 의 유일한
출구가 OPNsense" 라는 랩의 전제가 깨진다.**

```powershell
Connect-VMNetworkAdapter -VMName L0-Target -SwitchName 'L0-LAN'
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
