# L0 랩 — Suricata 인라인 IPS

## 설정 위치가 함정이다

OPNsense 26.x 의 IDS 모드는 `config.xml` 의 **`OPNsense/IDS/general/mode`** 가
결정한다. 값은 셋뿐이고 기본은 관측 모드다.

| mode | 의미 |
|---|---|
| `pcap` | PCAP live (IDS) — **관측만 한다.** 기본값 |
| `netmap` | Netmap (IPS) — 인라인 |
| `divert` | Divert (IPS) — 인라인, ipfw divert 경유 |

**`<ips>1</ips>` 은 아무 일도 하지 않는다.** 모델(`IDS.xml`)에 그 필드가 없다.
이 레포의 첫 시도가 그것이었고, 조용히 무시됐다.

## 왜 위험한가

잘못 두어도 **suricata 는 정상 기동하고 경보도 뜬다.** 서비스 상태는 running 이고
`eve.json` 에 alert 가 쌓인다. 그런데 아무것도 차단되지 않는다.

구분하는 방법은 하나다 — **프로세스 인자를 본다.**

```
suricata -D --pcap=hn0 ...    ← 관측만 한다
suricata -D --netmap ...      ← 인라인
```

`eve.json` 에서는 `event_type` 으로 구분한다. `alert` 만 있으면 탐지고,
`drop` 이 함께 나와야 실제로 떨어뜨린 것이다.

```json
{"event_type":"drop", "drop":{"reason":"rules"},
 "alert":{"action":"blocked","signature":"L0LAB TEST ICMP DROP"}}
```

## 검증 결과 (2026-09-04)

Hyper-V 합성 NIC(`hn0`, Hyper-V Network Interface)에서 netmap 인라인이 동작한다.

| 단계 | ICMP | DNS(UDP) | HTTP(TCP) |
|---|---|---|---|
| 기준선 | 0% 손실 | — | — |
| 룰 적용 | **100% 손실** | 정상 | 301 |
| 룰 제거 | 0% 손실 | — | — |

**DNS·TCP 를 함께 본 것이 핵심이다.** 전부 막혔다면 룰이 아니라 데이터패스가
깨진 것이고, ICMP 만 보면 그 둘을 구분하지 못한다.

관리 경로(SSH over LAN)는 netmap 전환 후에도 유지됐다. 다만 끊길 수 있는
작업이므로 **시리얼 콘솔을 복구 경로로 먼저 확보하고** 전환할 것 —
`serial-console.ps1` 참조.

## 룰 파일을 손으로 넣을 때

`configctl ids reload` 를 쓰지 말 것. `installRules.py` 가 `opnsense.rules/`
에서 config 에 등록되지 않은 파일을 **지운다**. 손으로 넣은 룰은
`/usr/local/etc/rc.d/suricata restart` 로 반영한다.

`installed_rules.yaml` 은 suricata 가 include 하는 YAML 이라 **반드시**
아래 두 줄로 시작해야 한다. 없으면 기동 자체가 실패한다.

```yaml
%YAML 1.1
---
rule-files:
  - l0lab-inline-test.rules
```
