# PokeTokenBar 서버 사용량 연동 — 작은 요약 파일 방식

## 서버의 Claude에게 전달할 요청

나는 MacBook에서 PokeTokenBar로 포켓몬을 키운다. Claude Code와 Codex는 서버에서 실행하며 Chrome으로 접속한다. **서버에서 새 로그만 집계하고, Mac이 30분마다 토큰 합계 JSON 하나만 받아 포켓몬 성장에 반영**하도록 설정을 도와줘.

이 문서와 함께 제공한 `collect.py`, `pull.sh`, `install-mac.py`를 사용해줘. 서버의 실제 실행 사용자·로그 경로·SSH 접근 경로를 조사한 뒤 설정해야 한다. 서버에서 가능한 작업은 진행하고, Mac에서만 가능한 작업은 실제 경로를 반영한 명령으로 안내해줘.

이 방식은 PokeTokenBar의 **remote summary 지원을 추가한 수정 빌드**가 필요하다. 기존 배포 앱은 요약 JSON을 자동으로 읽지 않는다. 이 파일을 기존 ‘추가 스캔 폴더’에 넣는 것으로는 연동되지 않는다.

## 무엇을 하는가

```text
Mac의 launchd: 매시 00분 / 30분에 SSH 접속
  → 서버 run.sh 실행
  → collect.py가 SQLite에 저장한 위치 이후의 새 로그만 읽음
  → 토큰 합계만 stdout으로 반환
  → Mac이 임시 파일로 받아 검증 후 remote-usage.json으로 교체
  → 수정된 PokeTokenBar가 사용량과 성장에 반영
```

- 서버에 상주 프로세스나 별도 API 서버를 띄우지 않는다. 서버 cron도 필요 없다.
- 접속 한 번으로 Claude와 Codex의 합계를 함께 가져온다.
- 서버 수집기는 Python 표준 라이브러리만 사용한다. 모델 호출과 추가 LLM 비용은 없다.
- SQLite에는 파일별 읽은 위치·파일 정보·중복 제거용 ID/해시·토큰 숫자·시각을 저장한다. 대화 원문과 API 키를 저장하거나 전송하지 않는다.
- Mac에는 최근 62일의 날짜별 토큰과 전체 누적 토큰, 마지막 사용 시각만 전달한다. 파일 크기 상한은 256 KiB이다.
- 최초 실행만 기존 로그를 한 번 읽는다. 이후에는 파일 목록과 수정 정보를 확인하고, 변경된 파일의 추가분만 읽는다. 로그 파일이 아주 많으면 목록 확인 비용은 남는다.
- 최초 실행이 끝난 후에는 서버와 Mac에 지속적으로 실행되는 수집기가 없다. 실제 부하는 로그 수·증가량에 따라 달라지며, 부하가 0인 것은 아니다.

## 1. 서버 환경 조사

먼저 다음을 확인하고 결과를 요약해줘.

1. Chrome에서 접속하는 프로그램 이름, CLI 실행 방식인지 API 직접 호출 방식인지.
2. Claude Code / Codex를 실행하는 OS 사용자와 홈 디렉터리.
3. Docker 등 컨테이너 여부, 호스트에서 읽을 수 있는 로그 볼륨 경로.
4. 실제 토큰 usage를 담은 JSONL 파일의 위치와 최근 갱신 여부.
5. SSH 로그인 사용자가 로그를 읽을 수 있는지.
6. Python 3.9 이상과 시간대 데이터가 있는지 (`zoneinfo.ZoneInfo('Asia/Seoul')` 확인).
7. Mac에서 사용할 SSH 주소/별칭, 포트, 키 인증 상태.

기본 로그 위치는 다음과 같지만 **실제 서버에서 검증**해야 한다.

| 도구 | 로그 루트 후보 |
|---|---|
| Claude Code | `~/.claude/projects` 또는 실제 설정 폴더의 `projects` |
| Codex | `~/.codex/sessions` |
| Codex 보관 로그 | `~/.codex/archived_sessions` — 존재한다면 함께 등록 |

로그를 확인할 때 프롬프트나 인증정보 전체를 출력하지 말고 사용량 필드와 파일 수정 시각 위주로 확인한다. 실제 사용 후 파일이 갱신되는지 검증한다.

웹 UI가 API를 직접 호출하여 CLI JSONL을 남기지 않는다면 이 수집기를 바로 쓸 수 없다. 그 경우 해당 웹 UI의 usage 저장 구조를 조사하고 어댑터가 필요한 이유를 설명한다. 임의의 로그 형식을 지원된다고 가정하지 않는다.

## 2. 서버 수집기 설치

패키지의 `collect.py`를 서버의 다음 위치에 복사한다.

```text
~/.local/share/poketokenbar-remote/collect.py
```

서버에 실행 래퍼 `run.sh`를 만든다. 아래는 예시이며 Python과 로그 경로를 실제 **절대 경로**로 바꾼다. 없는 로그 루트는 옵션에서 제거한다. 한 도구만 사용해도 된다. 여러 루트는 같은 옵션을 반복해서 등록한다.

```bash
mkdir -p "$HOME/.local/share/poketokenbar-remote"
chmod 700 "$HOME/.local/share/poketokenbar-remote"

cat > "$HOME/.local/share/poketokenbar-remote/run.sh" <<'SH'
#!/bin/sh
set -eu
umask 077
exec /usr/bin/nice -n 10 /usr/bin/python3 \
  "$HOME/.local/share/poketokenbar-remote/collect.py" \
  --state-dir "$HOME/.local/share/poketokenbar-remote/state" \
  --timezone Asia/Seoul \
  --claude-root /ACTUAL/LOG/ROOT/claude/projects \
  --codex-root /ACTUAL/LOG/ROOT/codex/sessions \
  --codex-root /ACTUAL/LOG/ROOT/codex/archived_sessions
SH

chmod 700 "$HOME/.local/share/poketokenbar-remote/run.sh"
```

`--timezone`은 서버 OS의 시간대가 아니라 **Mac에서 사용하는 시간대 식별자**와 일치시킨다. 한국 Mac은 보통 `Asia/Seoul`이다. 앱은 시간대가 다르면 요약 파일을 거부한다. 기존 DB의 시간대는 중간에 바꾸지 말고 변경이 필요하면 별도 상태 디렉터리를 사용한다.

서버에서 두 번 실행해서 검증한다.

```bash
"$HOME/.local/share/poketokenbar-remote/run.sh" > /tmp/poketokenbar-summary.json
python3 -m json.tool /tmp/poketokenbar-summary.json

"$HOME/.local/share/poketokenbar-remote/run.sh" > /tmp/poketokenbar-summary.json
```

첫 실행은 초기 로그 분석이므로 오래 걸릴 수 있다. 그사이 새 로그가 없다면 두 번째 실행의 stderr에는 `read 0 new bytes`가 나와야 한다. 이 숫자는 파싱한 로그 바이트이며 파일 목록·메타데이터·작은 DB 조회 비용까지 0이라는 뜻은 아니다.

stdout에는 JSON만 출력되어야 한다. 진단 메시지는 stderr로 간다. 셸 초기화 스크립트가 접속 안내 문구를 stdout에 출력한다면 비대화형 SSH에서 그 문구가 나오지 않도록 정리한다.

**state 폴더는 계속 유지한다.** 읽은 위치, 중복 제거 정보, 누적 토큰과 서버 고유 ID가 들어 있다. 삭제하면 최초 전체 분석을 다시 수행하고 새로운 ID가 생겨 Mac에서 기준값을 다시 잡는다.

## 3. Mac에서 SSH 준비

기존 SSH 설정과 키를 가능하면 재사용한다. 새 키가 필요하면 기존 키를 덮어쓰지 않는다. 서버에는 공개키만 등록하며, Mac 개인키를 서버에 복사하지 않는다.

Mac의 `~/.ssh/config`에 실제 값을 반영해 별칭을 설정할 수 있다.

```sshconfig
Host poke-usage-server
    HostName SERVER_HOST
    User SERVER_USER
    Port 22
    IdentityFile ~/.ssh/EXISTING_OR_NEW_KEY
    IdentitiesOnly yes
```

Mac에서 처음 직접 접속해 호스트 키를 확인한 뒤, 비대화형 접속을 검증한다. 호스트 키 검증을 끄지 않는다.

```bash
ssh poke-usage-server
# 접속 확인 후 exit

ssh -o BatchMode=yes poke-usage-server 'echo SSH_OK'
ssh -o BatchMode=yes poke-usage-server '.local/share/poketokenbar-remote/run.sh'
```

자동 작업은 비밀번호나 키 암호를 입력받을 수 없다. 키 암호가 있다면 Mac의 SSH agent / Keychain을 통해 로그인된 사용자 환경에서 인증되도록 설정한다. 서버 접속 계정의 홈과 수집기를 설치한 홈이 다르면 원격 명령을 실제 절대 경로로 변경한다.

## 4. 기존 전체 로그 동기화를 설정했다면 중지

이전에 안내한 rsync 방식을 이미 적용했다면 먼저 그 작업을 중지한다. 등록하지 않았다면 건너뛴다.

```bash
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/local.poketokenbar.remote-sync.plist"
```

그 plist 파일을 제거하거나 LaunchAgents 밖으로 옮겨 다음 로그인 때 재등록되지 않게 한다. PokeTokenBar의 추가 스캔 폴더에서도 **서버 로그 복사본 경로만** 제거한다.

같은 서버 로그를 로컬 파서와 remote summary 양쪽으로 읽으면 중복 집계된다. 요약 파일에는 원본 이벤트 ID가 없어서 원문과 요약 사이의 자동 중복 제거는 불가능하다. 다른 프로그램이 같은 서버 로그를 Mac의 기본 로그 경로로 동기화하는 경우도 함께 정리한다. 정상적인 별도 로컬 세션은 계속 추적해도 된다.

## 5. Mac의 30분 주기 가져오기 설치

Mac에서 Python 3이 필요하다. 패키지에서 `pull.sh`와 `install-mac.py`가 같은 폴더에 있도록 한 다음 실행한다.

```bash
python3 install-mac.py poke-usage-server
```

원격 래퍼 경로가 다르다면 다음처럼 지정한다. `--command`는 원격 셸이 실행하는 신뢰할 수 있는 고정 명령이다.

```bash
python3 install-mac.py poke-usage-server \
  --command '/ACTUAL/SERVER/HOME/.local/share/poketokenbar-remote/run.sh'
```

설치기는 다음을 수행한다.

1. Mac의 앱 상태 폴더 아래에 `remote-sync/pull.sh`를 복사한다.
2. 실제 SSH 수집을 한 번 실행한다. 실패하면 새 자동 실행 작업을 등록하지 않는다.
3. 사용자 LaunchAgent `local.poketokenbar.remote-summary`를 설치한다.
4. 매시 00분 / 30분 및 등록·로그인 시 실행한다. 낮은 CPU·디스크 우선순위를 사용한다.

요약 파일 위치:

```text
~/Library/Application Support/PokeTokenBar/remote-usage.json
```

앱을 개발용 `PTB_STATE_DIR`로 실행한다면 설치기도 같은 환경변수로 실행해야 한다. 기본 설정에서는 필요 없다.

전송은 임시 파일에 받고, SSH 성공·크기 상한·JSON/plist 문법 검증 후 원자적으로 교체한다. 실패하면 이전 파일을 유지한다. 앱이 추가로 버전, 시간대, 숫자 범위, 일별 합계와 누적값의 일관성을 검증한다. 잘못된 요약은 오류로 표시하며 이전 정상 스냅샷을 유지한다.

## 6. Mac 앱 적용과 동작

이 기능을 추가한 PokeTokenBar 빌드를 사용해야 한다. 함께 전달받은 로컬 개발용 `.app`이 있다면 기존 앱을 종료하고 그 빌드를 실행한다. 소스로 빌드한다면 수정된 Mac 저장소에서 기존 빌드 절차를 따른다. 서버에서 macOS 앱을 실행하거나 빌드할 필요는 없다.

함께 제공하는 `.app`은 이 작업 공간의 소스로 만든 Apple Silicon용 로컬 개발 빌드이며 정식 릴리스가 아니다. 기존 `/Applications` 앱은 자동으로 교체하지 않는다. 기존 배포 앱으로 돌아가거나 자동 업데이트하면 이 기능이 없을 수 있다. 설치 전에는 앱의 세이브 내보내기로 현재 진행을 보관할 수 있다.

앱을 새로고침하면 `Server Claude`, `Server Codex` 소스가 나타난다. 추가 스캔 폴더에 JSON을 등록할 필요는 없다. 추적할 프로바이더 설정에서 각 서버 소스를 끌 수 있다.

- 사용량 통계: 실제 사용 날짜의 합계에 반영한다. 비용과 실시간 burn rate는 요약에 없으므로 추정하지 않는다.
- 성장: 서버·도구별 전체 누적 토큰에서 **이 Mac이 이미 적립한 값 이후의 증가분**을 적립한다.
- 처음 연결했을 때의 기존 사용량은 기준값으로만 저장하고 소급 지급하지 않는다. 첫 파일을 받은 뒤 앱을 새로고침해 기준값을 잡은 다음부터 새 사용량을 확인한다.
- 이후에는 자정을 넘겨 받거나 Mac을 며칠 꺼 두어도, 같은 서버 상태 DB를 유지하면 다음 동기화 때 증가분이 적립된다.
- 앱을 재시작하거나 동일 파일을 다시 받아도 중복 적립하지 않는다. 더 오래된 파일이 들어와 누적값이 줄어도 적립 기준값을 낮추지 않는다.
- 기존 로컬 사용량은 기존 방식으로 함께 반영된다. 서버 사용량은 일별 합계와 누적값 양쪽에서 이중 적립하지 않는다.

Mac이 잠들면 동기화하지 않으며, 깨어난 뒤 밀린 캘린더 작업이 한 번 실행된다. 이후 앱 새로고침 때 반영된다. 이 방식은 자정 직전 추가 동기화가 필요 없다.

현재 연결 파일 하나는 **서버 한 대**를 대상으로 한다. 여러 서버의 요약으로 같은 파일을 번갈아 덮어쓰면 안 된다. 여러 서버 지원은 별도 확장이 필요하다.

## 7. 검증과 오류 확인

Mac에서 수동 실행을 요청한다.

```bash
launchctl kickstart "gui/$(id -u)/local.poketokenbar.remote-summary"
```

실행이 끝난 뒤 로그를 확인한다.

```bash
tail -n 20 "$HOME/Library/Application Support/PokeTokenBar/remote-sync.log"
tail -n 20 "$HOME/Library/Application Support/PokeTokenBar/remote-sync-error.log"
launchctl print "gui/$(id -u)/local.poketokenbar.remote-summary"
```

stderr에는 정상 수집 바이트 수 메시지도 기록되므로 stderr 파일이 비어 있어야만 성공인 것은 아니다. 최종 종료 코드, `Remote usage synced` 시각, 요약의 `generatedAt`을 함께 확인한다.

완료 조건:

1. 서버에서 초기 수집과 변경 없는 두 번째 수집이 성공한다.
2. Mac의 비대화형 SSH와 launchd 실행이 모두 성공한다.
3. 요약에는 토큰 숫자·날짜·고유 ID만 있고 대화 원문·키·프로젝트 경로가 없다.
4. 앱에서 첫 기준값을 잡은 후, 서버에서 새로 쓴 사용량이 통계와 성장에 반영된다.
5. 같은 요약으로 다시 새로고침해도 성장이 추가 적립되지 않는다.

수집기는 손상된 usage 줄, 누락된 로그 루트, 수치 오류를 성공한 0 사용량으로 처리하지 않는다. 실패하면 원인을 확인한다. Codex의 수동 fork는 부모의 활성/보관 로그 또는 이전에 수집해 둔 부모 상태가 필요하다. 없는 부모 로그는 경로를 추가해 해결한다. 실제 서브에이전트는 별도 사용량으로 집계한다.

## 8. 중지

Mac 자동 작업 중지:

```bash
launchctl bootout "gui/$(id -u)/local.poketokenbar.remote-summary"
```

다음 로그인 때도 실행하지 않으려면 해당 plist를 제거한다.

```bash
rm "$HOME/Library/LaunchAgents/local.poketokenbar.remote-summary.plist"
```

앱에서 서버 프로바이더 추적을 끄면 마지막 요약의 통계도 표시하지 않는다. 포켓몬 세이브와 서버 state 폴더는 자동으로 삭제하지 않는다.

## Claude가 마지막으로 정리할 내용

- 실제 CLI 실행 구조와 로그 경로, 이 수집기로 연결 가능한지.
- 서버에서 설치한 파일과 사용한 상태 디렉터리.
- 실제 SSH 정보와 경로를 반영한 Mac 실행 명령.
- 서버 수집, Mac 자동 실행, 앱 성장 확인 중 어디까지 검증했는지.
- 아직 확인하지 못한 부분은 완료됐다고 표현하지 말 것.

## 참고

- [Apple launchd 캘린더 작업 문서](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5)
- 수집기 테스트: `python3 -m unittest discover -s scripts/remote-usage -p 'test_*.py' -v`
- 앱 테스트: `swift test --filter RemoteSummaryTests`
