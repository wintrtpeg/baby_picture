# android.md — 안드로이드 배포

플레이스토어에 올리지 않고 **APK를 직접 설치(사이드로드)** 해서 쓴다.
이 선택이 앱 설계 자체를 몇 군데 바꾼다. 아래 3번이 그 내용이다.

---

## 1. 빌드

```bash
flutter build apk --release --split-per-abi
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`--split-per-abi`를 쓰면 ABI별로 나뉘어 용량이 절반 이하가 된다.
요즘 안드로이드폰은 전부 `arm64-v8a`이므로 그것만 보내면 된다.

설치: 폰으로 파일을 옮기고 → "출처를 알 수 없는 앱 설치" 허용 → 탭해서 설치.

---

## 2. 서명 키

릴리스 키스토어를 한 번 만들고 **절대 잃어버리면 안 된다.**

```bash
keytool -genkey -v -keystore ~/babyalbum-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias babyalbum
```

같은 키로 서명해야 기존 앱 위에 덮어쓰기 업데이트가 된다. 키를 잃어버리면
앱을 지우고 새로 깔아야 한다. 사진과 문구는 서버에 있으니 안전하고, 다시
로그인만 하면 된다 — 하지만 올리는 중이던 대기 큐는 날아간다.

`android/key.properties`와 `*.jks`는 **커밋하지 않는다.** `.gitignore`에 있다.

---

## 3. 설계에 미치는 영향

플레이스토어를 안 쓰고 도메인도 없다는 점 때문에 세 가지가 바뀐다.

### 초대는 링크가 아니라 코드다

App Links(`https://...`를 앱으로 여는 것)를 쓰려면 도메인과 그 위에 올린
`assetlinks.json`이 필요하다. 사이드로드 배포에는 둘 다 없다.

→ **8자리 초대 코드를 직접 입력받는다.** 전화로 불러 주기 좋게 헷갈리는
글자(`0 O 1 I`)를 뺐다. 스키마는 이미 이 방식으로 되어 있다.

> 목업의 가족 화면에는 아직 "링크 복사"로 되어 있다. **"초대 코드"로 고쳐야 한다.**

### 로그인은 이메일 + 6자리 코드

매직링크도 딥링크가 필요해서 같은 문제에 걸린다. 비밀번호는 관리 부담이 있고
조부모님께 설명하기 어렵다.

→ Supabase의 `signInWithOtp` + `verifyOTP`로 **이메일로 받은 6자리 숫자**를
입력하는 방식을 쓴다. 딥링크가 필요 없고 설명하기도 쉽다.

> 아기 등록 화면 앞에 **로그인 화면이 하나 더 필요하다.** 아직 안 그렸다.

### 업데이트를 아무도 안 알려준다

플레이스토어가 챙겨주지 않으므로, 새 APK를 만들어도 폰에서는 알 수가 없다.

→ 앱이 켜질 때 Supabase에서 최신 버전 번호를 읽어 "새 버전이 있어요" 배너를
띄우는 정도면 충분하다. 어차피 설치는 직접 해야 한다. (선택 사항, 나중에)

---

## 4. 권한과 SDK

`AndroidManifest.xml`:

| 권한 | 이유 |
|---|---|
| `INTERNET` | Supabase 통신 |
| `READ_MEDIA_IMAGES` | 사진 선택 (Android 13 / API 33 이상) |
| `READ_EXTERNAL_STORAGE` | 사진 선택 (API 32 이하, `maxSdkVersion="32"`) |

카메라는 `image_picker`가 필요한 시점에 요청한다.

- `minSdk` 23 (Supabase Flutter 안정 동작 기준)
- `targetSdk` 34 이상

---

## 5. 패키지

| 용도 | 패키지 |
|---|---|
| 백엔드 | `supabase_flutter` |
| 상태 관리 | `flutter_riverpod` |
| 라우팅 | `go_router` |
| 사진 선택 | `image_picker` (간단) 또는 `photo_manager` (앨범 단위 선택) |
| 리사이즈 | `flutter_image_compress` — **EXIF 보존 옵션을 명시적으로 켤 것** |
| 썸네일 캐시 | `cached_network_image` |
| 업로드 대기 큐 | `drift` |
| ZIP 만들기 | `archive` |
| 내보내기 공유 | `share_plus` |

---

## 6. 앨범 내보내기의 현실적인 문제

사진 218장 × 장당 2.5MB ≈ **550MB**다. 이걸 한 번에 받아서 ZIP으로 묶으면
기기 저장 공간과 시간 둘 다 부담이다.

대응:

1. 내보내기 전에 **예상 용량과 남은 저장 공간을 보여준다**
2. 기간을 나눠서 내보내도록 유도한다 (3개월 단위 등)
3. 진행률과 취소 버튼은 필수다
4. ZIP을 만들고 나면 원본 캐시는 지운다

> 목업의 앨범 내보내기 화면에 **예상 용량 표시가 빠져 있다.** 추가해야 한다.
