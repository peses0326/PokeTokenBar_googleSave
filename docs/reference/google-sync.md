# PokeTokenBar — Google 로그인과 개인 Drive 저장

## 원하는 동작

```text
Google 로그인 → 본인 계정 선택 → Drive 권한 동의
  → 내 드라이브 최상단의 PokeTokenBar_Save 폴더 생성/재사용
  → 현재 세이브 자동 업로드
  → 같은 계정의 다른 Mac에서 이어 키우기
```

세이브는 사용자의 Google Drive와 각 Mac에 저장한다. PokeTokenBar 운영 서버나 별도 게임 데이터베이스를 두지 않는다. 사용자가 Google Drive에서 파일을 직접 확인·다운로드·관리할 수 있다.

## 사용자가 할 일

1. 기존 앱의 세이브 내보내기 파일을 보관한다. 기존 앱은 삭제하지 않는다.
2. PokeTokenBar_gs 앱에서 진행이 정상적으로 불러와졌는지 확인한다. 이미 불러온 진행은 같은 데이터 폴더에 유지된다.
3. 설정 → Google 동기화 → **Google 로그인**을 누른다.
4. 브라우저에서 본인 Google 계정을 선택하고, 앱이 사용하는 Drive 파일 저장 권한에 동의한다.
5. 앱에 계정 이메일·동기화 시각이 나타나는지 확인한다. **내 Drive의 세이브 폴더 열기**로 실제 파일을 볼 수 있다.

일반 사용자는 OAuth JSON을 다운로드하거나 선택하지 않는다. 폴더가 비어 있으면 현재 진행이 자동으로 백업된다. 기존 클라우드 진행과 충돌하면 어느 진행을 이어 쓸지 선택한다. 사용 중인 기기를 바꾸기 전에는 **지금 동기화**를 눌러 완료 시각을 확인한다.

## 개발 설정과 현재 확인 상태

Desktop OAuth 클라이언트 ID는 빌드할 때 Info.plist에 넣는다. Google 동의 화면의 앱 이름은 `PokeTokenBar_gs`다.

일반 사용자는 JSON 파일을 고르지 않고 Google 로그인 버튼을 사용한다. Google Cloud 프로젝트에서 Drive API가 활성화되어 있어야 하며, Testing 상태이면 로그인할 계정을 테스트 사용자에 추가해야 한다. 해당 설정이 이미 되어 있으면 그대로 진행한다.

개발 빌드 예:

```bash
python3 scripts/build-google-save-version.py --google-client-id 'YOUR_CLIENT_ID.apps.googleusercontent.com'
```

Google이 해당 클라이언트에 대해 추가 Desktop 설정을 요구할 경우 개발자가 빌드 시 `--oauth-client-config /PRIVATE/PATH/desktop-client.json`으로 포함할 수 있다. 이 옵션은 개발자용이며 일반 사용자 화면에는 파일 선택이 없다. 클라이언트 ID는 공개 앱 식별자이고, 실제 사용자 로그인 토큰은 앱에 내장하지 않는다.

OAuth 앱이 Testing 상태이면 Drive 권한을 가진 refresh token이 7일 후 만료될 수 있다. 개발자가 테스트 사용자·게시 상태를 확인한다. 장기 운용 전에 Google의 게시·검증 요구사항을 따른다.

## Drive에 생기는 파일

```text
내 드라이브/
└── PokeTokenBar_Save/
    ├── PokeTokenBar-Save-2026-11-10_105400-ab12cd34.json
    └── PokeTokenBar-Save-2026-11-10_112400-ef56ab78.json
```

- 폴더의 최초 생성 위치는 **내 드라이브 최상단**이다. Google Drive의 ‘홈’ 추천 화면과 파일 계층의 ‘내 드라이브’는 다를 수 있다.
- 본인 소유의 비공유 폴더인지 검사한다. 타인 소유·공유 폴더·공유 드라이브에는 저장하지 않는다.
- 앱이 접근할 수 있는 같은 이름의 폴더가 있으면 재사용한다. `drive.file` 권한은 앱이 만든 파일 또는 사용자가 앱에 허용한 파일에 한정된다. 사용자가 웹에서 별도로 만든 폴더가 앱에 보이지 않으면 같은 이름의 앱 폴더가 생길 수 있다.
- 여러 기기가 처음 동시에 연결해 중복 폴더가 생기면, 앱은 접근 가능한 동일 이름의 루트들을 함께 읽고 가장 먼저 만든 폴더에만 새 파일을 쓴다. 사용자 폴더를 임의로 지우지 않는다.
- 각 기기의 최근 세이브 30개를 유지한다. 이미 후속 진행에 반영된 오래된 파일은 **휴지통**으로 옮겨 사용자가 복구할 수 있게 한다. 다른 기기의 파일이나 폴더 자체를 영구 삭제하지 않는다.
- 연결 해제는 로컬 로그인 정보를 지우고 동기화를 중지한다. Drive 폴더와 기존 세이브는 지우지 않는다.
- 동기화가 켜져 있는 동안 폴더를 삭제하면 다음 연결에서 새 폴더를 만들 수 있다. 저장을 중지하려면 먼저 앱에서 연결을 해제한다.

## 자동 동기화와 데이터 보호

앱이 실행되고 새로고침이 동작할 때 약 30분 간격으로 확인한다. 진행이 바뀐 경우에만 새 세이브를 업로드한다. 앱이 종료·잠자기 상태거나 새로고침이 수동이면 지연될 수 있다.

세이브는 불변 revision과 기기별 revision clock으로 관리한다. 다른 기기의 진행을 무조건 마지막 수정 시각으로 덮어쓰지 않는다. 동시 편집을 발견하면 선택 화면을 띄운다. 선택 전에는 기존 진행을 자동으로 교체하지 않는다.

로컬 세이브 교체 전에는 백업을 만들고, 내려받은 진행을 디스크에 저장한 뒤에만 가져오기 완료를 확인한다. 업로드 도중 연결이 끊기거나 가져오기 도중 앱이 종료되면 다음 실행에서 미완료 작업을 복구한다.

## 기존 앱과 데이터

기존 PokeTokenBar 앱은 교체하지 않는다. 이 빌드는 원본 코드에 Google 동기화와 알 30% 할인만 더한 것이고, 메뉴바·팝오버·로그인 실행 등 나머지 동작은 원본과 같다. 원본 앱과 따로 설치되므로 업데이트 확인만 끈다(원본 릴리스로 덮어쓰지 않게). 이 앱은 별도 앱 식별자와 데이터 폴더를 사용한다.

- 기존: `~/Library/Application Support/PokeTokenBar/`
- PokeTokenBar_gs: `~/Library/Application Support/PokeTokenBar_gs/` (번들 ID `io.github.peses0326.poketokenbar-gs`). Google 동의 화면의 앱 이름도 `PokeTokenBar_gs` 이다.

원본 앱의 데이터는 **자동으로 가져오지 않는다**. 진행은 원본 앱에서 내보낸 세이브 JSON을 설정의 세이브 불러오기로 가져온다. 원본 앱과 그 데이터 폴더는 지우지 않는다.

빌드 결과는 `build/google-save-version/PokeTokenBar_gs.app`이다. `/Applications`로 옮겨 쓰면 된다.

## 보안 확인

[보안 점검 보고서](google-sync-security.md)를 함께 확인한다. 주요 보호 장치는 다음과 같다.

- Google 공식 브라우저 로그인, PKCE·state·루프백 Host 검증.
- Drive 전체 권한을 요청하지 않는 `drive.file` 사용.
- 본인 소유·비공유 폴더 검사, 폴더 내부 파일만 조회·저장.
- Google API HTTPS 목적지 제한, 인증 헤더가 다른 곳으로 전달되는 리디렉션 차단.
- 로그인 비밀번호를 앱에서 수집하지 않음. 로그인 토큰을 Drive 세이브에 넣지 않음.
- 로컬 토큰 파일은 본인만 읽는 0600 권한. 다른 사용자 소유·공유 읽기·심볼릭 링크 파일은 거부.

이것은 코드 검토와 회귀 테스트 결과이며 독립 보안 감사나 실제 계정 연결 완료를 의미하지 않는다. 클라이언트 ID 등록과 실제 Google 계정 선택 화면 진입을 확인했다. 권한 동의 이후 실제 폴더 생성·업로드는 아직 완료 확인 전이다.

## 제한

동기화 대상은 포켓몬 진행·도감·아이템·지갑·성장 및 상점 난이도다. 언어와 표시 설정 등은 각 기기에서 유지한다. 로컬 사용량의 성장 결과는 세이브로 공유되지만 각 Mac의 원본 로그·모든 로컬 사용량 그래프를 업로드하지는 않는다.

세이브는 읽을 수 있는 JSON이며 앱 자체의 종단 간 암호화는 없다. 개인 Drive의 파일을 다른 사람에게 직접 공유하면 그 사람도 내용을 볼 수 있다. 현재 Mac의 토큰 저장은 Keychain 대신 권한 제한 파일을 쓰므로 같은 OS 사용자 권한의 악성 프로그램까지 막는다고 보장하지 않는다.

## 공식 참고

- [Google Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Drive 파일 단위 권한](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [Drive 루트 폴더 생성](https://developers.google.com/workspace/drive/api/guides/folder)
- [Drive API 요금·할당량](https://developers.google.com/workspace/drive/api/guides/limits#pricing)
