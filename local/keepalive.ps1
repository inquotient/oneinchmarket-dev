<#
  WSL 배포판 상주 프로세스 — 클러스터가 조용히 죽는 것을 막는다

  ★ 무엇을 막는가
    WSL 은 배포판에 붙은 프로세스가 없으면 인스턴스를 종료한다. 실측 로그:

      WSL (2 - init-systemd(Ubuntu)) ERROR: InitTerminateInstanceInternal:2763:
      systemctl poweroff did not terminate...

    systemd 가 poweroff 를 타면 k3s 가 정지하고, 다음 wsl 명령에서 배포판이
    새로 뜨며 **파드 110여 개가 전부 재시작**한다. 증상은 "k3s 가 10~12분마다
    크래시" 처럼 보이지만 원인은 k3s 가 아니다.

  ★ .wslconfig 의 vmIdleTimeout 으로는 부족하다
    그것은 **VM 유휴 타임아웃**이고, 여기서 일어나는 것은 **배포판 종료**다.
    별개 메커니즘이라 vmIdleTimeout=-1 을 넣어도 이 현상은 남는다.
    (그 키 자체는 [wsl2] 섹션이 맞다 — [experimental] 에 두면 WSL 이
     "unknown key" 로 조용히 무시한다. 2026-09-03 에 정정했다.)

  ★ 왜 터미널을 열어 두는 것으로 충분했나
    사람이 WSL 터미널을 띄워 두면 그 셸이 상주 프로세스 역할을 한다.
    그래서 평소에는 드러나지 않다가, 재부팅 후 터미널 없이 짧은
    `wsl.exe -- <명령>` 만 돌리는 상황에서 표면화됐다.

  사용
    powershell -File local\keepalive.ps1          # 시작(중복 방지)
    powershell -File local\keepalive.ps1 -Stop    # 중지
    powershell -File local\keepalive.ps1 -Status  # 확인
#>
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [switch]$Stop,
  [switch]$Status
)

function Get-Keepalive {
  Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*sleep infinity*' }
}

if ($Status) {
  $p = @(Get-Keepalive)
  if ($p.Count) { "keepalive 실행 중 — $($p.Count) 프로세스: $($p.ProcessId -join ', ')" }
  else { "keepalive 없음 — 배포판이 유휴 시 종료될 수 있다" }
  return
}

if ($Stop) {
  $p = @(Get-Keepalive)
  if (-not $p.Count) { "keepalive 없음"; return }
  $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  "keepalive 중지 — $($p.Count) 프로세스"
  return
}

if (@(Get-Keepalive).Count) { "이미 실행 중 — 건너뜀"; return }

# ★ Start-Process 로 **분리**해야 한다. 호출한 셸에 매달아 두면 그 셸이
#   끝날 때 함께 죽어 같은 문제가 재발한다.
Start-Process -FilePath 'wsl.exe' `
  -ArgumentList '-d', $Distro, '--', 'sleep', 'infinity' `
  -WindowStyle Hidden
Start-Sleep -Seconds 5
$p = @(Get-Keepalive)
if ($p.Count) { "keepalive 시작 — $($p.Count) 프로세스: $($p.ProcessId -join ', ')" }
else { Write-Error "keepalive 기동 실패" }
