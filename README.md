# Magic Tap Click

매직마우스 표면의 한 손가락 탭을 클릭으로 바꾸는 개인용 macOS 메뉴 막대 앱입니다.

## 동작

- 왼쪽 영역 한 손가락 탭 → 좌클릭
- 오른쪽 영역 한 손가락 탭 → 우클릭
- 같은 쪽을 빠르게 두 번 탭 → 더블클릭
- 실제 물리 클릭과 스크롤은 그대로 유지
- 메뉴 막대 아이콘에서 기능을 켜고 끌 수 있음

## 요구 사항

- macOS 13 이상
- Apple Magic Mouse
- 손쉬운 사용 권한
- 입력 감시 권한

매직마우스의 원시 터치 좌표는 macOS 공개 API가 아니라 `MultitouchSupport.framework`를 통해 읽습니다. 따라서 App Sandbox를 사용하지 않으며, Mac App Store 배포용이 아닌 개인용 유틸리티입니다. macOS 업데이트로 내부 인터페이스가 바뀌면 동작하지 않을 수 있습니다.

## 빌드

```sh
cd /Users/jinoisfree/Documents/ChatGPT/btt
./build.sh
./build/MagicTapClick.app/Contents/MacOS/MagicTapClick --self-test
```

## 실행

```sh
open /Users/jinoisfree/Documents/ChatGPT/btt/build/MagicTapClick.app
```

첫 실행 때 macOS가 앱을 차단하면 Finder에서 앱을 Control-click한 뒤 `열기`를 선택합니다. 이후 시스템 설정에서 다음 권한을 허용해야 합니다.

- 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → Magic Tap Click
- 시스템 설정 → 개인정보 보호 및 보안 → 입력 감시 → Magic Tap Click

앱 시작 시 두 권한 요청을 시도하며, 권한을 변경한 뒤에는 앱을 먼저 메뉴 막대에서 정상적으로 종료한 다음 다시 실행합니다. 메뉴에서 두 권한 상태를 확인할 수 있습니다.
