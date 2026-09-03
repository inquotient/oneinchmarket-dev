<#
  시리얼 콘솔 expect — 패턴을 기다렸다가 보낸다

  serial-console.ps1 이 만든 로그/입력 파일 쌍 위에서 동작한다.
  드라이버는 계속 붙어 있고 이 스크립트는 그 파일만 본다.

  ★ 왜 기다려야 하는가
    프롬프트가 뜨기 전에 보내면 문자가 버려진다. 실측: 사용자명을 보낸 뒤
    3초 자고 비밀번호를 보냈더니 getty 가 아직 password 모드로 바뀌기 전이라
    "Login incorrect" 가 났다. 화면에는 Password: 가 찍혀 있어 성공한 것처럼
    보이므로 **타이밍 문제를 자격 문제로 오진하기 쉽다.**

  ★ 왜 로그 '끝에서부터' 찾는가
    콘솔 로그는 append-only 다. 같은 프롬프트가 앞서 여러 번 나왔을 수 있어
    전체를 훑으면 과거의 매치에 걸린다. 호출 시점 이후에 들어온 부분만 본다.

  사용
    .\serial-expect.ps1 -Expect 'login:' -Send 'root'
    .\serial-expect.ps1 -Expect 'Password:' -Send 'opnsense' -Secret
    .\serial-expect.ps1 -Expect '#\s*$' -TimeoutSeconds 300      # 보내지 않고 대기만
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Expect,
  [string]$Send,
  [string]$LogPath   = "$env:TEMP\opnsense-console.log",
  [string]$InputPath = "$env:TEMP\opnsense-console.in",
  [int]   $TimeoutSeconds = 120,
  # 보내기 전 잠깐 둔다. 프롬프트가 찍힌 직후 입력 모드가 아직 안 잡힌
  # 콘솔이 있다.
  [int]   $SettleMs = 700,
  # 로그에 남기지 않는다(비밀번호 등)
  [switch]$Secret,
  # CR 을 붙이지 않는다(단일 키 입력 등)
  [switch]$NoEnter,
  # ★ 로그를 얼마나 거슬러 올라가 볼 것인가.
  #   기본 0 = 호출 이후에 들어온 출력만 본다. 명령을 보낸 뒤 **새** 프롬프트를
  #   기다릴 때는 이래야 한다 - 안 그러면 방금 지나간 프롬프트에 즉시 걸린다.
  #   반대로 첫 대기에서는 프롬프트가 이미 찍혀 있고 게스트가 조용해 새 출력이
  #   영영 안 온다. 실측: login: 가 화면에 있는데 60s 시간초과했다.
  #   그때는 -Lookback 8192 처럼 거슬러 보게 한다.
  [int]   $Lookback = 0
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogPath)) { throw "콘솔 로그가 없다: $LogPath — serial-console.ps1 이 떠 있는가?" }

# 호출 시점의 길이를 기준으로 삼는다. 이후 들어온 것만 검사 대상이다.
$start = [Math]::Max(0, (Get-Item $LogPath).Length - $Lookback)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ((Get-Date) -lt $deadline) {
  $fs = [IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -gt $start) {
      $fs.Position = $start
      $buf = New-Object byte[] ($fs.Length - $start)
      [void]$fs.Read($buf, 0, $buf.Length)
      $tail = [Text.Encoding]::ASCII.GetString($buf)
      # 색상 이스케이프를 걷어낸다. 부팅 로그가 ANSI 로 덮여 있어
      # 그대로 두면 프롬프트 문자열이 매치되지 않는다.
      $plain = $tail -replace "`e\[[0-9;?]*[a-zA-Z]", ''
      if ($plain -match $Expect) {
        $fs.Dispose()
        Start-Sleep -Milliseconds $SettleMs
        if ($PSBoundParameters.ContainsKey('Send')) {
          $payload = if ($NoEnter) { $Send } else { "$Send`n" }
          Set-Content -Path $InputPath -Value $payload -NoNewline -Encoding Ascii
          $shown = if ($Secret) { '<가려짐>' } else { $Send }
          Write-Host "[expect] '$Expect' 확인 -> '$shown'"
        } else {
          Write-Host "[expect] '$Expect' 확인"
        }
        exit 0
      }
    }
  } finally { $fs.Dispose() }
  Start-Sleep -Milliseconds 400
}

Write-Host "[expect] 시간초과 — '$Expect' 를 ${TimeoutSeconds}s 안에 보지 못했다"
Write-Host "[expect] 최근 출력:"
Get-Content $LogPath -Tail 15 | ForEach-Object { "    $_" }
exit 1
