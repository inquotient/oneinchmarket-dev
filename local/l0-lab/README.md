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

### 2. OPNsense 디스크 준비 (WSL, 관리자 불필요)

```bash
./prepare-opnsense-vm.sh        # nano 이미지 → VHDX
```

**`nano` 를 쓴다. DVD 가 아니다.** DVD 는 설치 프로그램이고 **VGA 프레임버퍼**에
그려서 자동화 대상이 되지 못한다 — 관리자 권한과 무관하다. nano 는 이미 설치된
시스템이라 설치 대화가 없고, 임베디드용이라 **시리얼 콘솔이 기본**이다.

미러 속도를 재고 고를 것. 실측(2026-09-04):

| 미러 | 속도 |
|---|--:|
| `pkg.opnsense.org` | 63 KB/s |
| `mirrors.dotsrc.org` | 101 KB/s |
| `opnsense.c0urier.net` | 168 KB/s |
| **`mirror.ams1.nl.leaseweb.net`** | **381 KB/s** |

468 MB 에 20~70분이다. 국내 미러는 없다(kakao·naver·harukasan 모두 미보유).

### 3. VM 생성 (관리자 PowerShell)

```powershell
.\setup-l0-lab.ps1
```

`prepare-*.sh` 산출물이 있으면 그 디스크를 붙인다. OPNsense 는 **Gen1** 로 만든다 —
nano 이미지는 MBR 이고 EFI 파티션이 없어 Gen2(UEFI)로는 부팅하지 못한다.

### 4. OPNsense 구성 (시리얼 콘솔, 무인)

```powershell
# 데몬을 띄운다. ★ VM 이 실행 중이어야 한다 — named pipe 는 VM 이 돌 때만 존재한다
.\serial-console.ps1 -Pipe opnsense-com1 `
  -LogPath $env:TEMP\opnsense-console.log -InputPath $env:TEMP\opnsense-console.in

# 패턴을 기다렸다 보낸다
.\serial-expect.ps1 -Expect 'login:' -Send 'root' -Lookback 4096
.\serial-expect.ps1 -Expect '[Pp]assword:' -Send 'opnsense' -Secret
```

콘솔 메뉴 전체를 이렇게 몬다. 실측으로 **사람 개입 없이** 부팅 → 로그인 →
주소 변경 → SSH 활성화까지 갔다. 자세한 것은 `docs/LOCAL-DEPLOYMENT.md §8-32`.

> ★ **LAN 대역을 기본값 192.168.1.0/24 로 두지 말 것.** OPNsense 는 첫 NIC 을
> LAN 에 배정하고 거기에 192.168.1.1 + DHCP 서버를 올린다. 이 호스트의 실제
> 대역·게이트웨이와 같아서, 첫 NIC 이 External 스위치에 붙어 있으면
> **물리망에서 공유기의 IP 를 주장하게 된다.** 실제로 그런 일이 있었다(§8-32).
> 그래서 스크립트는 첫 NIC 을 `L0-LAN`(Internal)에 붙이고 대역은 10.77.0.0/24 를 쓴다.

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


## 디스크 확장 — ET Open 을 넣기 전에 반드시 먼저

nano 이미지는 루트가 **2.8 GB** 다. 기본 설치만으로 82% 가 차서 여유가
**482 MB** 밖에 없다. ET Open 은 그 자체로 60 MB 남짓이지만 다운로드 중간
파일과 로그를 감안하면 이 여유로는 안전하지 않다.

가상 디스크는 이미 16 GB 다(`prepare-opnsense-vm.sh` 가 그렇게 만든다).
파티션과 파일시스템만 따라가지 않은 상태이므로 **게스트 안에서만 늘리면 된다.**
Hyper-V 쪽 `Resize-VHD` 는 필요 없고 VM 을 끌 필요도 없다.

```sh
# 되돌릴 수 있게 체크포인트를 먼저 만든다 (호스트에서)
#   Checkpoint-VM -Name L0-OPNsense -SnapshotName before-disk-grow

gpart show da0                    # 3.0G 파티션 + 13G free 확인
gpart resize -i 1 da0             # 파티션을 디스크 끝까지
growfs -y /dev/ufs/OPNsense_Nano  # ★ /dev/da0a 로 하면 실패한다
mount -u -o rw /                  # 슈퍼블록 재적재
df -h /                           # 15G / 12G avail
```

★ `growfs /dev/da0a` 는 `Operation not permitted` 로 거부된다.
`kern.geom.debugflags=16` 을 켜도 마찬가지다. 루트가 **레이블**
(`/dev/ufs/OPNsense_Nano`)로 마운트되어 있어 GEOM 의 배타적 쓰기 권한이 그
provider 에 걸려 있기 때문이다. **레이블 경로로 호출해야 통과한다.**

★ `growfs` 직후 `WARNING: /: reload pending error` 가 나오는 것은 정상이다.
`mount -u` 로 슈퍼블록을 다시 읽으면 `df` 가 새 크기를 보고한다.

## SSH 접속 — 시리얼 콘솔보다 이쪽을 쓸 것

호스트는 `vEthernet (L0-LAN)` 으로 **10.77.0.190** 에 있고 OPNsense LAN 은
10.77.0.1 이다. SSH 가 열려 있다.

```powershell
# 키 권한이 느슨하면 ssh 가 키를 무시한다. 한 번만 정리하면 된다.
$k = "$env:USERPROFILE\.ssh\L0-OPNsense-key"
Copy-Item C:\Users\darka\HyperV\L0Lab\L0-OPNsense-key $k -Force
icacls $k /inheritance:r
icacls $k /grant:r "$($env:USERNAME):R"

ssh -i $k root@10.77.0.1
scp -i $k .\suricata\enable-et-open.py root@10.77.0.1:/tmp/
```

★ **시리얼 콘솔은 대량 입력에서 바이트를 잃는다.** 여러 줄짜리 heredoc 을
입력 파일로 밀어 넣었더니 중간에서 끊겨 셸이 heredoc 을 연 채로 멈췄다.
짧은 명령 확인용으로만 쓰고, 파일 전송은 `scp` 로 할 것.

★ OPNsense 의 root 셸은 **csh** 다. `"...$|..."` 같은 것이 `Illegal variable
name` 으로 죽는다. `sh` 로 바꾸거나 작은따옴표를 쓸 것.

## ET Open 룰셋

```sh
scp enable-et-open.py root@10.77.0.1:/tmp/
ssh root@10.77.0.1 'python3 /tmp/enable-et-open.py'
ssh root@10.77.0.1 'configctl template reload OPNsense/IDS'   # ★ 빼먹지 말 것
ssh root@10.77.0.1 'configctl ids update'
ssh root@10.77.0.1 'configctl ids restart'
```

실측 결과:

```
룰셋 23종 · 규칙 36,818개 · 디스크 62 MB · Suricata RSS 약 1.2 GB
디스크 여유 12 G 유지
```

### 동작 확인 — HOME_NET 안에서는 대부분 걸리지 않는다

ET Open 규칙의 다수(16,564개)가 `$HOME_NET any -> $EXTERNAL_NET any` 다.
호스트(10.77.0.190)에서 방화벽(10.77.0.1)으로 보내는 트래픽은 HOME_NET 안이라
**아무것도 매칭되지 않는다.** 처음에 sqlmap/Nikto User-Agent 로 HTTP 를
쐈지만 알림이 0 이었던 이유가 이것이다.

목적지가 `any` 인 DNS 규칙을 쓰면 라우팅을 건드리지 않고 검증할 수 있다:

```sh
nslookup sqlmapff.com 10.77.0.1
#  -> ET MALWARE Possible Winnti-related DNS Lookup  (10.77.0.190 -> 10.77.0.1)
```

DNS 질의만 보내고 그 도메인에 접속하지는 않는다.

### 알림이 클러스터까지 가는지 — 포트포워드가 조용히 끊긴다

경로는 `Suricata EVE -> syslog(10.77.0.190:5140) -> netsh portproxy ->
WSL localhostForwarding -> kubectl port-forward -> logstash:5140` 이다.

★ **맨 끝의 `kubectl port-forward` 는 logstash 파드를 재생성하면 죽는다.**
방화벽 쪽에는 아무 오류도 나지 않고 alert 는 eve.json 에 정상적으로 쌓인다.
Elasticsearch 의 `suricata` 인덱스만 조용히 멈춘다 — 실제로 14시간을 놓쳤다.

```bash
# WSL 에서 다시 띄운다
nohup sudo k3s kubectl -n local port-forward --address 0.0.0.0 \
      logstash-0 5140:5140 > /tmp/pf.log 2>&1 &
```

확인은 인덱스의 **최신 문서 시각**으로 한다. 건수만 보면 과거 데이터 때문에
멈춘 것을 알 수 없다.

## Zeek — OPNsense 26.7 에는 패키지가 없다

`pkg search zeek` 결과 0건, 플러그인 210종 중에도 없다(`os-ntopng` 이
그나마 인접하다). 선택지는 셋이다:

| 안 | 내용 |
|---|---|
| 도입하지 않는다 | Suricata EVE 가 이미 flow·http·dns·tls 이벤트를 낸다. L0 랩 목적에는 중복이 크다 |
| L0-Target 에서 돌린다 | Ubuntu 이므로 패키지가 있다. 다만 트래픽을 미러링해 줘야 한다 |
| `os-ntopng` | 플로우 가시성은 얻지만 Zeek 의 프로토콜 로그와는 다른 물건이다 |

**미결정 — 사용자 판단이 필요하다.** 이 문서의 제목이 "OPNsense · Suricata ·
Zeek" 인 것은 초기 계획이며, Zeek 부분은 아직 근거가 채워지지 않았다.

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
