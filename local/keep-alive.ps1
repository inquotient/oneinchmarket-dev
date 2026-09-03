# WSL2 VM 유지 (Windows PowerShell)
#
# ★ 왜 필요한가 —
#   WSL2 는 VM 에 붙은 프로세스가 없으면 잠시 뒤 VM 을 내린다. systemd 로
#   k3s 가 돌고 있어도 마찬가지다. 매니페스트 편집처럼 Windows 쪽에서만
#   작업하는 동안 WSL 을 건드리지 않으면 VM 이 clean poweroff 되고,
#   다음 wsl 명령에 새로 부팅되면서 **40개 파드가 전부 재시작**한다.
#
#   노드 이벤트에는 아무 압박도 남지 않아(MemoryPressure=False) 원인이
#   드러나지 않는다. 재시작 횟수만 조용히 쌓인다.
#
#   .wslconfig 의 [experimental] vmIdleTimeout 도 넣어 두었으나 WSL 버전에
#   따라 무시된다(2.7.12 에서 경고가 났다). 이 스크립트가 확실한 방법이다.
#
# 사용:
#   powershell -ExecutionPolicy Bypass -File local\keep-alive.ps1
#
# 로그온 시 자동 실행하려면 작업 스케줄러에 등록한다:
#   schtasks /Create /TN "WSL keep-alive" /SC ONLOGON /RL HIGHEST ^
#     /TR "wsl.exe -d Ubuntu -- sleep infinity"

$running = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -like '*sleep infinity*' }

if ($running) {
    Write-Output "keep-alive 이미 실행 중 (PID $($running.ProcessId -join ', '))"
    exit 0
}

Start-Process -FilePath "wsl.exe" `
              -ArgumentList "-d","Ubuntu","--","sleep","infinity" `
              -WindowStyle Hidden
Start-Sleep -Seconds 3
Write-Output "keep-alive 시작. 중지하려면 해당 wsl.exe 프로세스를 종료할 것."
