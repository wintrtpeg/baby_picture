# backend.md — Supabase 설계

스키마: [`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql)
권한 테스트: [`supabase/tests/rls_test.sql`](../supabase/tests/rls_test.sql)

---

## 1. 테이블

```
profiles ──┐
           ├─ memberships ─── babies
           │                    ├── moments ─── photos ─── caption (사진 단위 인쇄 원고)
           │                    └── invites
```

| 테이블 | 역할 |
|---|---|
| `profiles` | 사용자. 가입 시 트리거로 자동 생성 |
| `babies` | 아기. 이름, 생일, 성별 |
| `memberships` | 누가 어떤 아기를 어떤 권한으로 보는가 |
| `moments` | 하루의 한 장면. 타임라인은 이 단위로 쌓인다 |
| `photos` | 사진 1장 + **그 사진의 문구** |
| `invites` | 초대 코드 |

**문구는 `photos.caption`에 있다.** 모먼트가 아니라 사진 단위다. 책 한 페이지가
사진 한 장에 글 한 줄이기 때문이다. 댓글 테이블은 없다 — 흘러가는 반응 대신
전부 인쇄될 원고로만 쌓인다.

`photos.baby_id`는 모먼트에서 가져온 비정규화 값이다. 트리거가 항상 일치시키므로
직접 넣을 필요가 없고, 넣어도 무시된다. "문구 대기 중인 사진" 조회를 조인 없이
하기 위한 것이다.

---

## 2. 권한

| | 사진 보기 | 문구 쓰기 | 사진 올리기/고치기 | 가족 관리 | 아기 삭제 |
|---|:--:|:--:|:--:|:--:|:--:|
| `owner` 관리자 | ○ | ○ | ○ | ○ | ○ |
| `editor` 편집 | ○ | ○ | ○ | ✕ | ✕ |
| `caption` 문구 작성 | ○ | ○ | ✕ | ✕ | ✕ |

`caption` 권한이 이 앱의 핵심이다. 조부모님께 드리는 권한으로, 사진을 보고
글만 쓸 수 있다. 그렇게 쓴 문구도 그대로 앨범에 인쇄된다.

RLS는 컬럼 단위 제한을 못 하므로, `caption` 권한이 사진의 다른 필드를 못 건드리게
하는 것은 `guard_photo_update` 트리거가 맡는다. 같은 트리거가 문구가 바뀔 때
`caption_author_id`와 `caption_updated_at`을 자동으로 채운다.

### 권한 헬퍼에서 주의할 점

`member_role()`은 멤버가 아니면 `null`을 돌려준다. `is_owner()`/`can_edit()`는
그 결과를 **반드시 `coalesce(..., false)`로 감싼다.** 안 그러면
`if not is_owner(...)` 같은 검사가 `null`이 되어 통과해 버린다.
(실제로 이 버그가 있었고 `rls_test.sql`의 T3b가 잡았다.)

---

## 3. 초대

링크가 아니라 **코드**다. 앱을 사이드로드로 배포해서 App Links를 쓸 도메인이
없기 때문이다 ([android.md](android.md) 참고).

```
관리자                                받는 사람
  create_invite(baby_id, 'caption')      redeem_invite('KMP7X2QA')
  → 8자리 코드                            → 멤버십 생성, baby_id 반환
```

코드는 헷갈리는 글자(`0 O 1 I`)를 뺀 32자 알파벳에서 8자리를 뽑는다. 전화로 불러
주기 좋게 하기 위해서다. 기본 1회용, 7일 만료.

받는 사람은 아직 멤버가 아니라 `invites`를 직접 읽을 수 없다. `redeem_invite`
RPC로만 들어온다.

---

## 4. 스토리지

버킷 두 개, 둘 다 비공개.

```
photos/<baby_id>/<photo_id>/orig.jpg     긴 변 3200px, JPEG 92, sRGB
photos/<baby_id>/<photo_id>/thumb.jpg    긴 변 400px
avatars/<user_id>/avatar.jpg
```

경로 첫 칸이 `baby_id`이고, 스토리지 정책이 그걸로 권한을 판단한다.
**이 경로 규약을 어기면 접근이 막힌다.**

업로드 순서는 **스토리지 먼저, DB row는 나중**이다. 반대로 하면 업로드가 실패했을 때
파일 없는 row가 남는다. 반대 방향으로 생긴 고아 파일은 나중에 정리할 수 있다.

---

## 5. 조회

### 타임라인

`moment_feed` 뷰가 생후 일수와 문구 진행도까지 계산해서 준다.

```dart
final rows = await supabase
    .from('moment_feed')
    .select()
    .eq('baby_id', babyId)
    .order('taken_on', ascending: false)
    .range(0, 19);
```

돌려주는 것: `day_offset`, `photo_count`, `caption_count`, `cover_thumb_path`

> **생후 일수 표기 주의.** `day_offset`은 생일로부터 경과한 날수다.
> 화면의 "생후 561일"은 태어난 날을 1일로 세므로 **`day_offset + 1`**이다.
> 이 뷰는 `security_invoker = true`로 만들어져 있다. 이게 없으면 뷰가 소유자
> 권한으로 돌아 RLS를 통째로 우회한다.

### 문구를 기다리는 사진

```dart
final pending = await supabase
    .from('photos')
    .select('id, thumb_path, taken_at, moment_id')
    .eq('baby_id', babyId)
    .or('caption.is.null,caption.eq.')
    .order('taken_at');
```

부분 인덱스(`photos_pending_idx`)가 있어서 사진이 수천 장이 돼도 빠르다.

### 앨범 내보내기용

```dart
final rows = await supabase
    .from('photos')
    .select('storage_path, caption, taken_at, position, moments(title, taken_on)')
    .eq('baby_id', babyId)
    .gte('taken_at', from)
    .lte('taken_at', to)
    .order('taken_at');
```

이 결과를 사진 파일 + `captions.csv`로 묶어 ZIP을 만든다. 지면 배치는
포토북 업체 편집기에 맡긴다.

---

## 6. 적용

```bash
# Supabase CLI
supabase db push

# 또는 대시보드 SQL Editor에 0001_init.sql 내용을 붙여넣기
```

`supabase/tests/`는 로컬 검증용이며 실제 프로젝트에 올리지 않는다.
`stub.sql`은 Supabase가 기본 제공하는 `auth`/`storage` 스키마를 흉내 낸 것이다.

```bash
supabase/tests/run.sh    # postgresql-16 서버 바이너리 필요
```

---

## 7. 아직 없는 것

의도적으로 뺐다. 필요해지면 그때 마이그레이션을 추가한다.

- **성장 기록**(키·몸무게·성장곡선) — MVP 범위 밖
- **내보내기 이력 테이블** — ZIP을 앱에서 만들므로 서버 기록이 필요 없다
- **푸시 알림**
- **고아 파일 정리** — 사진 row가 지워져도 스토리지 파일은 남는다.
  주기적으로 청소하는 작업이 언젠가 필요하다
