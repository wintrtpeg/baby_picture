# design/

화면 목업. 각 `.dc.html` 파일이 한 화면이고, `canvas.json`이 캔버스 배치를 정의한다.

디자인 규칙은 저장소 루트의 [`design.md`](../design.md)를 따른다.

| 파일 | 화면 |
|---|---|
| `Login.dc.html` | 로그인 — 이메일로 받은 6자리 숫자 |
| `Onboarding.dc.html` | 아기 등록 |
| `Main.dc.html` | 타임라인 (홈) |
| `MomentDetail.dc.html` | 모먼트 상세 — 사진별 문구 |
| `CaptionFlow.dc.html` | 문구 채우기 |
| `Upload.dc.html` | 업로드 / 새 모먼트 |
| `AlbumExport.dc.html` | 앨범 내보내기 |
| `Family.dc.html` | 가족 초대 |
| `DirectionA.dc.html` | 초기 방향 A — 따뜻한 편집 (보관) |
| `DirectionB.dc.html` | 초기 방향 B — 부드러운 미니멀 (채택, 이후 다듬음) |
| `DirectionC.dc.html` | 초기 방향 C — 사진 우선 (보관) |

각 파일은 390×844(아이폰 기준) 고정 크기의 독립 HTML이라 브라우저로 바로 열어 볼 수 있다.
사진은 전부 자리표시자 그라데이션이다.

빌드 산출물 `baby-album-app-ui.html`은 커밋하지 않는다.
