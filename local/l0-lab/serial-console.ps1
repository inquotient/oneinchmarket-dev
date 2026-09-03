<#
  Hyper-V 시리얼 콘솔 드라이버 — named pipe 로 게스트 콘솔을 읽고 쓴다

  왜 필요한가
    OPNsense 는 DVD 설치 프로그램이 **VGA 프레임버퍼**에 그린다. 그건 텍스트
    스트림이 아니라 자동화 대상이 되지 못한다 — 관리자 권한과 무관하다.
    반면 nano/serial 이미지는 시리얼 콘솔(115200)로 나오고, Hyper-V 는 VM 의
    COM 포트를 named pipe 에 붙일 수 있다. 그 파이프가 곧 텍스트 스트림이다.

      Set-VMComPort -VMName L0-OPNsense -Number 1 -Path \.\pipe\opnsense-com1

  구조 — 왜 데몬인가
    파이프는 Hyper-V 가 서버이고 **한 번에 한 클라이언트만** 붙는다. 명령마다
    붙었다 떼면 그 사이 출력이 유실된다. 그래서 한 프로세스가 계속 붙어 있고
    파일 두 개로 소통한다.

      LogPath    게스트가 뱉은 것이 계속 append 된다 (tail 로 본다)
      InputPath  여기에 쓰면 게스트로 보내고 파일을 지운다

  주의
    개행은 CR 로 보낸다. 터미널은 LF 를 입력 종료로 보지 않는다 — CRLF 를
    그대로 보내면 명령이 두 번 들어간 것처럼 처리되는 콘솔이 있다.
#>
[CmdletBinding()]
param(
  [string]$Pipe            = 'opnsense-com1',
  [string]$LogPath         = "$env:TEMP\opnsense-console.log",
  [string]$InputPath       = "$env:TEMP\opnsense-console.in",
  [int]   $DurationSeconds = 3600,
  [int]   $ConnectTimeoutMs = 30000
)

$ErrorActionPreference = 'Stop'

$stream = New-Object System.IO.Pipes.NamedPipeClientStream(
  '.', $Pipe,
  [System.IO.Pipes.PipeDirection]::InOut,
  [System.IO.Pipes.PipeOptions]::Asynchronous)

Write-Host "[serial] \.\pipe\$Pipe 연결 대기"
$stream.Connect($ConnectTimeoutMs)
Write-Host "[serial] 연결됨 · 로그 $LogPath · 입력 $InputPath"

if (-not (Test-Path $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }
Remove-Item $InputPath -Force -ErrorAction SilentlyContinue

$buf = New-Object byte[] 8192
$ar  = $null
$deadline = (Get-Date).AddSeconds($DurationSeconds)

try {
  while ((Get-Date) -lt $deadline) {
    # ── 읽기 ──────────────────────────────────────────────
    # BeginRead + WaitOne 으로 폴링한다. NamedPipeClientStream 은
    # ReadTimeout 을 지원하지 않아 동기 Read 를 쓰면 영원히 막힌다.
    if (-not $ar) { $ar = $stream.BeginRead($buf, 0, $buf.Length, $null, $null) }
    if ($ar.AsyncWaitHandle.WaitOne(200)) {
      $n = $stream.EndRead($ar); $ar = $null
      if ($n -gt 0) {
        [IO.File]::AppendAllText($LogPath, [Text.Encoding]::ASCII.GetString($buf, 0, $n))
      }
    }

    # ── 쓰기 ──────────────────────────────────────────────
    if (Test-Path $InputPath) {
      $raw = $null
      try { $raw = [IO.File]::ReadAllText($InputPath) } catch { }
      if ($null -ne $raw) {
        Remove-Item $InputPath -Force -ErrorAction SilentlyContinue
        # CRLF·LF 를 전부 CR 하나로. 터미널 입력 종료는 CR 이다.
        $send = $raw -replace "`r`n", "`r" -replace "`n", "`r"
        $b = [Text.Encoding]::ASCII.GetBytes($send)
        $stream.Write($b, 0, $b.Length)
        $stream.Flush()
      }
    }
  }
} finally {
  $stream.Dispose()
  Write-Host "[serial] 종료"
}
