#Requires -RunAsAdministrator
<#
  L0 랩 프로비저닝 — OPNsense + Suricata + Zeek 검증 환경 (L-1)

  왜 랩인가
    WSL2 의 vEthernet 어댑터는 WSL 서비스가 관리하는 NAT 스위치에 묶여 있어
    임의의 vSwitch 에 붙이거나 다른 VM 을 게이트웨이로 끼워 넣을 수 없다.
    즉 **k3s 를 WSL2 에 둔 채로는 OPNsense 를 인라인에 놓을 수 없다.**
    ADR-051(A안) 을 전면 실행하면 가능하지만 클러스터 재구축이 따른다.

    이 랩은 그 대신 **k3s 와 분리된 인라인 경로**를 만든다. 검증 대상은
    "OPNsense 가 트래픽을 실제로 보는가"이지 "k3s 가 그 뒤에 있는가"가 아니다.
    여기서 검증한 룰셋을 클라우드 dev 로 그대로 옮긴다.

  토폴로지
      [Windows 호스트]
        L0-WAN (External)   ── OPNsense NIC1 (WAN)
        L0-LAN (Internal)   ── OPNsense NIC2 (LAN) ── target VM

    target 의 모든 외부 통신이 OPNsense LAN→WAN 을 지난다. Suricata 는
    그 경로에 인라인으로 앉고 Zeek 는 같은 지점을 패시브로 본다.

  메모리
    OPNsense 6 GiB (Suricata 룰셋 + Zeek) · target 2 GiB = 8 GiB
    §8-27 의 requests 정정으로 만든 여유(12 GiB) 안에 든다.
    ★ OPNsense 는 동적 메모리를 끈다 — FreeBSD 의 벌루닝 지원이 부실하다.
      (H1 과는 사유가 다르다. H1 은 kubelet 이 기동 시점 총량으로 계산하기
       때문이고, 여기서는 게스트 OS 지원 문제다.)

  사용
    관리자 PowerShell 에서:  .\setup-l0-lab.ps1 -IsoPath C:\iso\OPNsense.iso
#>
[CmdletBinding()]
param(
  [string]$IsoPath,
  [string]$TargetIsoPath,
  [string]$VmRoot        = "$env:USERPROFILE\HyperV\L0Lab",
  [int]   $OpnMemoryGB   = 6,
  [int]   $TargetMemoryGB = 2,
  # ★ OPNsense 는 Gen1 이다. 추측이 아니라 이미지를 열어 확인한 것이다:
  #     Disklabel type: dos       ← MBR
  #     /dev/...4 * 0 49999  a5 FreeBSD
  #   EFI System Partition 이 없다. Gen2(UEFI)로는 부팅하지 못한다.
  #   Gen1 은 IDE 컨트롤러에서 부팅한다 — SCSI 에 붙이면 부팅 장치로 잡히지 않는다.
  [ValidateSet(1,2)][int]$Generation = 1,
  # WAN 으로 쓸 물리 NIC 이름. 미지정 시 활성 NIC 을 자동 선택한다.
  [string]$WanAdapter,
  # prepare-target-vm.sh 가 만든 부팅 디스크. 있으면 이것을 붙이고,
  # 없으면 빈 디스크를 만들어 -TargetIsoPath 로 수동 설치한다.
  [string]$TargetVhdPath = "$env:USERPROFILE\HyperV\L0Lab\L0-Target.vhdx"
)

$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "[l0-lab] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[l0-lab] $m" -ForegroundColor Yellow }

# ── 0. 전제 확인 ─────────────────────────────────────────────
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
  throw "Hyper-V 관리 모듈이 없다. 먼저 활성화할 것:`n" +
        "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All`n" +
        "  그리고 재부팅."
}
if (-not (Get-Service vmms -ErrorAction SilentlyContinue)) {
  throw "vmms 서비스가 없다 — Hyper-V 역할 미설치. 위 명령 후 재부팅할 것."
}

# ★ 경로 검증을 **아무것도 만들기 전에** 한다.
#   이 검사가 VM 생성 뒤에 있었더니(2026-09-04) ISO 가 아직 없는 상태에서
#   -IsoPath 를 주고 돌린 실행이 OPNsense VM 을 만든 직후 throw 했고,
#   **L0-Target 은 만들어지지 않은 채 랩이 반만 남았다.** 스위치·VM 이
#   부분 생성되면 재실행이 "이미 존재 — 건너뜀" 으로 흘러 결손을 덮는다.
foreach ($p in @(
  @{ n = '-IsoPath';       v = $IsoPath },
  @{ n = '-TargetIsoPath'; v = $TargetIsoPath })) {
  if ($p.v -and -not (Test-Path $p.v)) {
    throw "$($p.n) 의 파일을 찾을 수 없다: $($p.v)"
  }
}

$freeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,1)
$needGB = $OpnMemoryGB + $TargetMemoryGB
Log "Windows 가용 메모리 ${freeGB} GiB · 랩 소요 ${needGB} GiB"
if ($freeGB -lt ($needGB + 4)) {
  Warn "여유가 얇다. .wslconfig 의 memory 가 44GB 로 내려간 뒤 재시작했는지 확인할 것."
  Warn "  현재 WSL VM: $((Get-Process vmmemWSL -ErrorAction SilentlyContinue).WorkingSet64/1GB) GiB"
}

New-Item -ItemType Directory -Force -Path $VmRoot | Out-Null

# ── 1. 가상 스위치 ───────────────────────────────────────────
# LAN 은 Internal — 호스트만 붙고 외부로 직접 나가지 못한다.
# 이것이 "target 의 유일한 출구가 OPNsense" 를 보장하는 장치다.
if (-not (Get-VMSwitch -Name 'L0-LAN' -ErrorAction SilentlyContinue)) {
  Log "vSwitch 'L0-LAN' (Internal) 생성"
  New-VMSwitch -Name 'L0-LAN' -SwitchType Internal | Out-Null
} else { Log "vSwitch 'L0-LAN' 이미 존재" }

if (-not (Get-VMSwitch -Name 'L0-WAN' -ErrorAction SilentlyContinue)) {
  if (-not $WanAdapter) {
    $WanAdapter = (Get-NetAdapter -Physical |
      Where-Object Status -eq 'Up' | Sort-Object LinkSpeed -Descending |
      Select-Object -First 1).Name
  }
  if (-not $WanAdapter) { throw "활성 물리 NIC 을 찾지 못했다. -WanAdapter 로 지정할 것." }
  Log "vSwitch 'L0-WAN' (External, NIC='$WanAdapter') 생성"
  # -AllowManagementOS: 호스트가 같은 NIC 을 계속 쓰게 둔다. 끄면 호스트
  # 네트워크가 끊긴다 — 원격 세션이면 복구 불가다.
  New-VMSwitch -Name 'L0-WAN' -NetAdapterName $WanAdapter -AllowManagementOS $true | Out-Null
} else { Log "vSwitch 'L0-WAN' 이미 존재" }

# ── 2. OPNsense VM ───────────────────────────────────────────
$opnName = 'L0-OPNsense'
if (Get-VM -Name $opnName -ErrorAction SilentlyContinue) {
  Warn "$opnName 이미 존재 — 건너뜀"
} else {
  # ★★ NIC 순서가 중요하다 — 첫 NIC 이 LAN 이다.
  #
  #   OPNsense 의 기본 설정은 **첫 번째 NIC 을 LAN 에, 두 번째를 WAN 에** 배정하고
  #   LAN 에 192.168.1.1/24 + DHCP 서버를 올린다. 처음에 첫 NIC 을 L0-WAN
  #   (External, 물리 NIC 공유)에 붙였더니 이런 일이 벌어졌다(2026-09-04 실측):
  #
  #     LAN (hn0) -> v4: 192.168.1.1/24     ← 물리망에 붙은 쪽
  #     호스트 실제 주소   192.168.1.222
  #     호스트 기본 게이트웨이 192.168.1.1   ← **같은 주소다**
  #
  #   즉 부팅 직후 약 1분간 **공유기의 IP 를 물리망에서 주장하고 DHCP 서버까지
  #   띄운 상태**였다. 다행히 게이트웨이 ARP 는 실제 공유기 MAC 을 유지했고
  #   호스트 연결도 끊기지 않았지만, 우연에 기댄 결과다.
  #
  #   그래서 첫 NIC 을 L0-LAN(Internal)에 붙인다. 잘못 배정되더라도 격리된
  #   스위치라 물리망에 영향이 없다. 이름도 실제와 맞춰 둔다 — Hyper-V 에서
  #   'LAN' 이라 붙여 놓고 실제로는 WAN 인 상태가 이 사고를 키웠다.
  Log "$opnName 생성 (Gen$Generation · ${OpnMemoryGB}GiB · 첫 NIC=LAN(격리))"
  $vhd = Join-Path $VmRoot "$opnName.vhdx"
  $opnArgs = @{
    Name = $opnName; Generation = $Generation
    MemoryStartupBytes = ($OpnMemoryGB * 1GB)
    SwitchName = 'L0-LAN'
  }
  if (Test-Path $vhd) { $opnArgs.VHDPath = $vhd }        # prepare-opnsense-vm.sh 산출물
  else { $opnArgs.NewVHDPath = $vhd; $opnArgs.NewVHDSizeBytes = 32GB }
  New-VM @opnArgs | Out-Null
  Rename-VMNetworkAdapter -VMName $opnName -Name 'Network Adapter' -NewName 'LAN'
  # ★ 동적 메모리 비활성 — FreeBSD 벌루닝 지원 부실
  Set-VMMemory -VMName $opnName -DynamicMemoryEnabled $false
  Set-VMProcessor -VMName $opnName -Count 2
  # WAN 쪽 두 번째 NIC
  Add-VMNetworkAdapter -VMName $opnName -SwitchName 'L0-WAN' -Name 'WAN'
  # ★ 시리얼 콘솔. 이것이 무인 구성의 전제다 — serial-console.ps1 참조.
  #   nano 이미지는 시리얼로 나오므로 이 파이프가 곧 조작 경로가 된다.
  Set-VMComPort -VMName $opnName -Number 1 -Path '\\.\pipe\opnsense-com1'
  if ($Generation -eq 2) {
    # FreeBSD 는 MS UEFI CA 로 서명되어 있지 않다
    Set-VMFirmware -VMName $opnName -EnableSecureBoot Off
  }
  if ($IsoPath) {
    if (-not (Test-Path $IsoPath)) { throw "ISO 를 찾을 수 없다: $IsoPath" }
    Add-VMDvdDrive -VMName $opnName -Path $IsoPath
    if ($Generation -eq 2) {
      $dvd = Get-VMDvdDrive -VMName $opnName
      Set-VMFirmware -VMName $opnName -FirstBootDevice $dvd
    }
  } else {
    Warn "-IsoPath 미지정 — OPNsense ISO 를 나중에 붙일 것"
  }
}

# ── 3. target VM ─────────────────────────────────────────────
# LAN 에만 붙는다. 공인 경로가 없으므로 **OPNsense 없이는 밖으로 못 나간다.**
# Caldera 격리 정책과 같은 발상이다 — 우회 가능한 경로를 아예 두지 않는다.
$tgtName = 'L0-Target'
if (Get-VM -Name $tgtName -ErrorAction SilentlyContinue) {
  Warn "$tgtName 이미 존재 — 건너뜀"
} else {
  $prepared = Test-Path $TargetVhdPath
  if ($prepared) {
    Log "$tgtName 생성 (Gen2 · ${TargetMemoryGB}GiB · 준비된 디스크 부착 · L0-LAN 전용)"
    New-VM -Name $tgtName -Generation 2 -MemoryStartupBytes ($TargetMemoryGB * 1GB) `
           -VHDPath $TargetVhdPath -SwitchName 'L0-LAN' | Out-Null
  } else {
    Warn "준비된 디스크가 없다($TargetVhdPath) — 빈 디스크로 만든다."
    Warn "  먼저 WSL 에서 ./prepare-target-vm.sh 를 돌리는 편이 낫다."
    Log "$tgtName 생성 (Gen2 · ${TargetMemoryGB}GiB · 빈 디스크 16GB)"
    New-VM -Name $tgtName -Generation 2 -MemoryStartupBytes ($TargetMemoryGB * 1GB) `
           -NewVHDPath (Join-Path $VmRoot "$tgtName.vhdx") -NewVHDSizeBytes 16GB `
           -SwitchName 'L0-LAN' | Out-Null
  }
  Set-VMMemory -VMName $tgtName -DynamicMemoryEnabled $true `
               -MinimumBytes 512MB -MaximumBytes ($TargetMemoryGB * 1GB)
  Set-VMProcessor -VMName $tgtName -Count 2

  # ★ Secure Boot 템플릿을 바꾼다. Gen2 의 기본값은 'MicrosoftWindows' 이고
  #   그 상태로는 shim 서명을 신뢰하지 않아 **Ubuntu 가 부팅하지 않는다.**
  #   끄지 않고 CA 템플릿으로 바꾼다 — 서명 검증은 유지된다.
  Set-VMFirmware -VMName $tgtName -EnableSecureBoot On `
                 -SecureBootTemplate MicrosoftUEFICertificateAuthority

  # cloud-init 시드. NoCloud 데이터소스가 볼륨 레이블 cidata 를 찾는다.
  # 없으면 로그인 계정이 만들어지지 않아 콘솔에 들어갈 수 없다.
  $seed = if ($TargetIsoPath) { $TargetIsoPath }
          else { Join-Path (Split-Path $TargetVhdPath) 'L0-Target-seed.iso' }
  if (Test-Path $seed) {
    Log "cloud-init 시드 부착: $seed"
    Add-VMDvdDrive -VMName $tgtName -Path $seed
  } else {
    Warn "시드 ISO 가 없다($seed) — 로그인 계정 없이 부팅한다"
  }

  if ($prepared) {
    # 디스크 우선 부팅. 시드는 데이터소스일 뿐 부팅 매체가 아니다.
    Set-VMFirmware -VMName $tgtName `
      -FirstBootDevice (Get-VMHardDiskDrive -VMName $tgtName)
  } elseif (Test-Path $seed) {
    Set-VMFirmware -VMName $tgtName -FirstBootDevice (Get-VMDvdDrive -VMName $tgtName)
  }
}

# ── 4. 결과 ──────────────────────────────────────────────────
Log "완료. 현재 상태:"
Get-VM -Name 'L0-*' | Format-Table Name, State, @{n='Mem(GiB)';e={[math]::Round($_.MemoryStartup/1GB,1)}}, ProcessorCount -AutoSize
Get-VMSwitch -Name 'L0-*' | Format-Table Name, SwitchType, NetAdapterInterfaceDescription -AutoSize

@"

다음 (수동 — OPNsense 설치 프로그램이 콘솔 대화형이다)
  1. Hyper-V 관리자에서 L0-OPNsense 연결 후 시작
  2. 설치 후 **DVD 를 떼고** 재부팅한다 — 안 떼면 설치 프로그램으로 다시 부팅한다
  3. 인터페이스 배정: 첫 NIC = WAN(L0-WAN), 'LAN' 이름의 NIC = LAN(L0-LAN)
  4. LAN 에 대역 지정 후 target VM 을 DHCP 로 받게 한다
  5. 플러그인 설치: os-suricata (IDS/IPS), Zeek 는 os-zeek 또는 패키지
  6. Suricata 를 **LAN 인터페이스에 IPS 모드로** 건다 — WAN 에만 걸면
     인라인 차단이 아니라 관측만 된다

로그를 클러스터로 보내기 (ADR-031)
  Suricata EVE JSON · Zeek conn/dns/http/ssl 을 Logstash 로 보낸다.
  WSL2 의 k3s 는 Hyper-V VM 에서 직접 보이지 않으므로 Windows 를 경유한다:
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=5044 ^
      connectaddress=127.0.0.1 connectport=5044
  그리고 WSL 쪽에서: kubectl -n local port-forward svc/logstash 5044:5044
  ★ 이 경로는 검증용이다. 상시 운용 구성이 아니다.
"@ | Write-Host
