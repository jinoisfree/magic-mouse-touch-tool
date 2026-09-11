# Magic Tap Click

매직마우스 표면의 한 손가락 탭을 클릭으로 바꾸는 개인용 macOS 메뉴 막대 앱입니다.

## 동작

- 왼쪽 영역 한 손가락 탭 → 좌클릭
- 오른쪽 영역 한 손가락 탭 → 우클릭
- 좌클릭과 우클릭 각각 `터치`, `클릭`, `터치+클릭` 방식 선택 가능
- `터치`는 Magic Mouse의 해당 물리 클릭을 차단하고 터치만 사용
- `클릭`은 터치 인식을 끄고 물리 클릭만 사용
- `터치+클릭`은 터치와 물리 클릭을 모두 사용
- `클릭` 방식은 앱이 터치 이벤트를 만들지 않고 원래 물리 클릭을 사용
- 좌클릭 영역은 마우스 표면의 왼쪽 42%로 제한
- 같은 쪽을 빠르게 두 번 탭 → 더블클릭
- 세 손가락을 터치한 상태에서 움직임 → 왼쪽 버튼 드래그
- 실제 물리 클릭과 스크롤은 그대로 유지
- 입력은 Magic Mouse 장치에서만 읽으며, 내장/외장 트랙패드는 제외
- 메뉴 막대 아이콘에서 기능을 켜고 끌 수 있음
- 메뉴 막대 아이콘에서 터치 감도를 약하게/보통/강하게 조절할 수 있음

빌드는 `MagicTapClick Local Development`라는 고정 코드 서명 인증서와 designated requirement를 사용합니다. 업데이트 전에 설치된 앱의 서명이 같은지 검사하고, 빌드 후에는 TCC 권한을 초기화하지 않고 LaunchAgent 프로세스만 재시작합니다. 따라서 같은 인증서를 유지하는 정상 업데이트에서는 권한을 다시 설정할 필요가 없습니다. 다른 서명 ID를 사용하려면 `MAGIC_TAP_CLICK_SIGNING_IDENTITY` 환경 변수를 지정합니다.

## 요구 사항

- macOS 13 이상
- Apple Magic Mouse
- 손쉬운 사용 권한
- 입력 감시 권한

매직마우스의 원시 터치 좌표는 macOS 공개 API가 아니라 `MultitouchSupport.framework`를 통해 읽습니다. 장치 family ID와 Apple Magic Mouse 제품 ID가 모두 일치할 때만 콜백을 등록하므로 내장 및 외장 트랙패드 입력은 앱의 터치 변환 대상이 아닙니다. 알 수 없는 장치는 작동시키지 않는 실패-폐쇄 방식입니다. 따라서 App Sandbox를 사용하지 않으며, Mac App Store 배포용이 아닌 개인용 유틸리티입니다. macOS 업데이트로 내부 인터페이스가 바뀌면 동작하지 않을 수 있습니다.

## 빌드

```sh
cd /Users/jinoisfree/Documents/ChatGPT/btt
./setup-signing.sh
./build.sh
/Users/jinoisfree/Applications/MagicTapClick.app/Contents/MacOS/MagicTapClick --self-test
```

`setup-signing.sh`는 최초 한 번만 실행합니다. 로그인 키체인에 10년 유효기간의 로컬 코드서명 인증서와 개인 키를 저장하며, 이미 동일한 유효 인증서가 있으면 아무것도 변경하지 않습니다. 개인 키는 Git 저장소에 기록되지 않습니다. 기존 인증서를 잃어 새 인증서를 생성한 경우에만 macOS 권한을 한 번 다시 등록해야 합니다.

빌드 결과는 프로젝트의 `build` 폴더에 생성되고, 실행용 앱은 파일 제공자 메타데이터의 영향을 받지 않도록 `/Users/jinoisfree/Applications/MagicTapClick.app`에 설치됩니다.

`--self-test`의 장치 필터·프레임워크·모드 진리표 결과는 앱 자체 검사입니다. 권한과 이벤트 탭 항목은 실행을 호출한 터미널 앱의 TCC 문맥을 상속할 수 있으므로 `caller-context`로 표시하며, 실제 상주 앱 권한은 메뉴의 런타임 상태를 기준으로 확인합니다.

## 실행

```sh
open /Users/jinoisfree/Applications/MagicTapClick.app
```

첫 실행 때 macOS가 앱을 차단하면 Finder에서 앱을 Control-click한 뒤 `열기`를 선택합니다. 이후 시스템 설정에서 다음 권한을 허용해야 합니다.

- 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → Magic Tap Click
- 시스템 설정 → 개인정보 보호 및 보안 → 입력 감시 → Magic Tap Click

앱은 필요한 권한이 모두 확인된 뒤에만 입력 엔진을 시작합니다. 승인 상태가 실행 중 갱신되면 엔진을 자동으로 시작하며, macOS가 앱 재시작을 요구하는 경우 메뉴의 `권한 승인 후 앱 재시작`을 사용합니다. 정상 업데이트에서는 빌드 스크립트가 동일 서명을 확인한 후 앱을 자동 재시작하므로 권한을 삭제하거나 다시 등록하지 않습니다. 메뉴에서 실제 실행 프로세스의 권한과 입력 엔진 상태를 확인할 수 있습니다.
