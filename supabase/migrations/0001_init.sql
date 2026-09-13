-- 0001_init.sql
-- 아기 사진첩 앱 초기 스키마
--
-- 설계 전제
--   * Baby가 중심이다. 부모·조부모가 같은 아기를 공유하므로 memberships로 다대다 연결한다.
--   * 문구(caption)는 사진 단위로 붙는 인쇄 원고다. 댓글 기능은 없다.
--   * 권한 3단계: owner(관리자) / editor(편집) / caption(문구 작성)
--   * 모든 접근은 RLS로 막는다. 앱 코드에 버그가 나도 남의 아기 사진은 보이지 않는다.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------------

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_path text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.babies (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  birth_date    date not null,
  gender        text not null default 'unspecified'
                check (gender in ('female', 'male', 'unspecified')),
  cover_photo_id uuid,              -- photos 생성 후 아래에서 FK를 건다
  created_by    uuid not null references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.memberships (
  id         uuid primary key default gen_random_uuid(),
  baby_id    uuid not null references public.babies(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null check (role in ('owner', 'editor', 'caption')),
  created_at timestamptz not null default now(),
  unique (baby_id, user_id)
);

-- 하루의 한 장면. 타임라인은 이 단위로 쌓인다.
create table public.moments (
  id         uuid primary key default gen_random_uuid(),
  baby_id    uuid not null references public.babies(id) on delete cascade,
  title      text not null default '',
  -- 촬영일. 업로드일이 아니다. 지난 사진을 몰아 올려도 타임라인이 어긋나지 않게 한다.
  taken_on   date not null,
  note       text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.photos (
  id           uuid primary key default gen_random_uuid(),
  moment_id    uuid not null references public.moments(id) on delete cascade,
  -- RLS와 "문구 대기" 조회를 모먼트 조인 없이 하기 위한 비정규화 컬럼.
  -- 트리거가 moment의 baby_id와 항상 일치시킨다.
  baby_id      uuid not null references public.babies(id) on delete cascade,

  storage_path text not null,        -- photos/<baby_id>/<photo_id>/orig.jpg
  thumb_path   text not null,        -- photos/<baby_id>/<photo_id>/thumb.jpg
  width        int  not null,
  height       int  not null,
  byte_size    bigint,
  taken_at     timestamptz,          -- EXIF DateTimeOriginal
  position     int  not null default 0,
  -- 원본을 자르지 않고 좌표만 저장한다. 인쇄 판형이 바뀌면 다시 잘라야 하기 때문이다.
  -- {"x":0.0,"y":0.1,"w":1.0,"h":0.8} 형태의 정규화 좌표. null이면 원본 전체.
  crop         jsonb,

  -- 앨범에 인쇄될 원고
  caption             text,
  caption_author_id   uuid references public.profiles(id),
  caption_updated_at  timestamptz,

  created_by   uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint caption_length check (caption is null or char_length(caption) <= 500)
);

alter table public.babies
  add constraint babies_cover_photo_fk
  foreign key (cover_photo_id) references public.photos(id) on delete set null;

-- 초대. 도메인 없이 사이드로드로 배포하므로 링크가 아니라 코드를 직접 입력받는다.
create table public.invites (
  id         uuid primary key default gen_random_uuid(),
  baby_id    uuid not null references public.babies(id) on delete cascade,
  code       text not null unique,
  role       text not null check (role in ('editor', 'caption')),
  max_uses   int  not null default 1 check (max_uses between 1 and 20),
  use_count  int  not null default 0,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. 인덱스
-- ---------------------------------------------------------------------------

create index memberships_user_idx    on public.memberships (user_id);
create index moments_feed_idx        on public.moments (baby_id, taken_on desc, created_at desc);
create index photos_moment_idx       on public.photos (moment_id, position);
create index photos_taken_idx        on public.photos (baby_id, taken_at desc);
-- "문구를 기다리는 사진" 큐. 부분 인덱스라 전체 사진이 늘어도 조회가 느려지지 않는다.
create index photos_pending_idx      on public.photos (baby_id, taken_at)
  where caption is null or caption = '';
create index invites_code_idx        on public.invites (code);

-- ---------------------------------------------------------------------------
-- 3. 권한 헬퍼
--
-- security definer 이므로 함수 안에서는 RLS가 적용되지 않는다.
-- memberships 정책이 memberships를 조회할 때 생기는 무한 재귀를 이걸로 피한다.
-- ---------------------------------------------------------------------------

create or replace function public.member_role(b uuid)
returns text language sql stable security definer set search_path = public as $$
  select m.role from public.memberships m
   where m.baby_id = b and m.user_id = auth.uid();
$$;

create or replace function public.is_member(b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.memberships m
     where m.baby_id = b and m.user_id = auth.uid()
  );
$$;

-- coalesce가 핵심이다. 멤버가 아니면 member_role이 null을 돌려주는데,
-- 그대로 두면 `if not can_edit(...)` 같은 검사가 null이 되어 통과해 버린다.
create or replace function public.can_edit(b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.member_role(b) in ('owner', 'editor'), false);
$$;

create or replace function public.is_owner(b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.member_role(b) = 'owner', false);
$$;

-- 스토리지 경로에서 baby_id를 뽑을 때 쓴다. 형식이 어긋난 경로로 쿼리 전체가
-- 에러 나지 않도록 null을 돌려준다.
create or replace function public.safe_uuid(t text)
returns uuid language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. 트리거
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_touch   before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger babies_touch     before update on public.babies
  for each row execute function public.touch_updated_at();
create trigger moments_touch    before update on public.moments
  for each row execute function public.touch_updated_at();
create trigger photos_touch     before update on public.photos
  for each row execute function public.touch_updated_at();

-- 가입하면 프로필을 만든다.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 아기를 만든 사람은 자동으로 관리자가 된다.
create or replace function public.handle_new_baby()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.memberships (baby_id, user_id, role)
  values (new.id, new.created_by, 'owner')
  on conflict (baby_id, user_id) do nothing;
  return new;
end $$;

create trigger on_baby_created
  after insert on public.babies
  for each row execute function public.handle_new_baby();

-- photos.baby_id를 moment의 것과 항상 일치시킨다.
create or replace function public.sync_photo_baby_id()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select m.baby_id into new.baby_id
    from public.moments m where m.id = new.moment_id;
  if new.baby_id is null then
    raise exception '모먼트를 찾을 수 없습니다';
  end if;
  return new;
end $$;

create trigger photos_sync_baby
  before insert or update of moment_id on public.photos
  for each row execute function public.sync_photo_baby_id();

-- 문구가 바뀌면 작성자와 시각을 자동으로 기록한다.
-- 동시에, 문구 작성 권한(caption)만 가진 사람은 문구 외에 아무것도 못 바꾸게 막는다.
-- RLS는 컬럼 단위 제한을 못 하므로 트리거로 강제한다.
create or replace function public.guard_photo_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.caption is distinct from old.caption then
    new.caption_author_id  := auth.uid();
    new.caption_updated_at := now();
  end if;

  if public.member_role(old.baby_id) = 'caption' then
    if (new.moment_id, new.storage_path, new.thumb_path,
        new.width, new.height, new.position, new.crop)
       is distinct from
       (old.moment_id, old.storage_path, old.thumb_path,
        old.width, old.height, old.position, old.crop)
    then
      raise exception '문구 작성 권한으로는 문구만 수정할 수 있습니다';
    end if;
  end if;

  return new;
end $$;

create trigger photos_guard_update
  before update on public.photos
  for each row execute function public.guard_photo_update();

-- ---------------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------------

alter table public.profiles    enable row level security;
alter table public.babies      enable row level security;
alter table public.memberships enable row level security;
alter table public.moments     enable row level security;
alter table public.photos      enable row level security;
alter table public.invites     enable row level security;

-- profiles: 내 프로필과, 같은 아기를 공유하는 사람의 프로필만 보인다.
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.memberships mine
      join public.memberships theirs on theirs.baby_id = mine.baby_id
      where mine.user_id = auth.uid() and theirs.user_id = profiles.id
    )
  );
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- babies
create policy babies_select on public.babies for select to authenticated
  using (public.is_member(id));
create policy babies_insert on public.babies for insert to authenticated
  with check (created_by = auth.uid());
create policy babies_update on public.babies for update to authenticated
  using (public.can_edit(id)) with check (public.can_edit(id));
create policy babies_delete on public.babies for delete to authenticated
  using (public.is_owner(id));

-- memberships
create policy memberships_select on public.memberships for select to authenticated
  using (public.is_member(baby_id));
create policy memberships_insert on public.memberships for insert to authenticated
  with check (public.is_owner(baby_id));
create policy memberships_update on public.memberships for update to authenticated
  using (public.is_owner(baby_id)) with check (public.is_owner(baby_id));
-- 관리자는 누구든 내보낼 수 있고, 누구나 스스로 나갈 수 있다.
create policy memberships_delete on public.memberships for delete to authenticated
  using (public.is_owner(baby_id) or user_id = auth.uid());

-- moments
create policy moments_select on public.moments for select to authenticated
  using (public.is_member(baby_id));
create policy moments_insert on public.moments for insert to authenticated
  with check (public.can_edit(baby_id) and created_by = auth.uid());
create policy moments_update on public.moments for update to authenticated
  using (public.can_edit(baby_id)) with check (public.can_edit(baby_id));
create policy moments_delete on public.moments for delete to authenticated
  using (public.can_edit(baby_id));

-- photos
-- update는 문구 작성 권한까지 열어 두고, 어디까지 바꿀 수 있는지는 위의 트리거가 막는다.
create policy photos_select on public.photos for select to authenticated
  using (public.is_member(baby_id));
create policy photos_insert on public.photos for insert to authenticated
  with check (public.can_edit(baby_id) and created_by = auth.uid());
create policy photos_update on public.photos for update to authenticated
  using (public.is_member(baby_id)) with check (public.is_member(baby_id));
create policy photos_delete on public.photos for delete to authenticated
  using (public.can_edit(baby_id));

-- invites: 관리자만 보고 만든다. 받는 쪽은 아래 redeem_invite RPC로만 접근한다.
create policy invites_select on public.invites for select to authenticated
  using (public.is_owner(baby_id));
create policy invites_insert on public.invites for insert to authenticated
  with check (public.is_owner(baby_id) and created_by = auth.uid());
create policy invites_update on public.invites for update to authenticated
  using (public.is_owner(baby_id)) with check (public.is_owner(baby_id));
create policy invites_delete on public.invites for delete to authenticated
  using (public.is_owner(baby_id));

-- ---------------------------------------------------------------------------
-- 6. RPC
-- ---------------------------------------------------------------------------

-- 초대 코드 발급. 사람이 불러 줄 수 있게 헷갈리는 글자(0/O/1/I)를 뺀 8자리.
create or replace function public.create_invite(
  b uuid,
  invite_role text default 'caption',
  valid_days int default 7,
  uses int default 1
) returns public.invites
language plpgsql security definer set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  new_code text;
  row_out public.invites;
  i int;
begin
  if not public.is_owner(b) then
    raise exception '초대는 관리자만 만들 수 있습니다';
  end if;
  if invite_role not in ('editor', 'caption') then
    raise exception '권한 값이 올바르지 않습니다';
  end if;

  loop
    new_code := '';
    for i in 1..8 loop
      new_code := new_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.invites where code = new_code);
  end loop;

  insert into public.invites (baby_id, code, role, max_uses, expires_at, created_by)
  values (b, new_code, invite_role, uses,
          now() + make_interval(days => valid_days), auth.uid())
  returning * into row_out;

  return row_out;
end $$;

-- 초대 코드 사용. 아직 멤버가 아니므로 invites를 직접 못 읽는다. 이 함수로만 들어온다.
create or replace function public.redeem_invite(invite_code text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare inv public.invites;
begin
  select * into inv from public.invites
   where code = upper(trim(invite_code))
     and revoked_at is null
     and expires_at > now()
     and use_count < max_uses
   for update;

  if not found then
    raise exception '초대 코드가 유효하지 않거나 만료되었습니다';
  end if;

  insert into public.memberships (baby_id, user_id, role)
  values (inv.baby_id, auth.uid(), inv.role)
  on conflict (baby_id, user_id) do nothing;

  if found then
    update public.invites set use_count = use_count + 1 where id = inv.id;
  end if;

  return inv.baby_id;
end $$;

revoke execute on function public.create_invite(uuid, text, int, int) from anon;
revoke execute on function public.redeem_invite(text) from anon;

-- ---------------------------------------------------------------------------
-- 7. 뷰
--
-- security_invoker = true 가 핵심이다. 이게 없으면 뷰가 소유자 권한으로 돌아
-- RLS를 우회한다.
-- ---------------------------------------------------------------------------

create view public.moment_feed with (security_invoker = true) as
select
  m.id,
  m.baby_id,
  m.title,
  m.taken_on,
  m.note,
  m.created_by,
  m.created_at,
  b.birth_date,
  (m.taken_on - b.birth_date)                                    as day_offset,
  count(p.id)                                                    as photo_count,
  count(p.id) filter (where p.caption is not null and p.caption <> '') as caption_count,
  min(p.storage_path)   filter (where p.position = 0)            as cover_path,
  min(p.thumb_path)     filter (where p.position = 0)            as cover_thumb_path
from public.moments m
join public.babies b on b.id = m.baby_id
left join public.photos p on p.moment_id = m.id
group by m.id, b.birth_date;

-- ---------------------------------------------------------------------------
-- 8. 스토리지
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('photos', 'photos', false), ('avatars', 'avatars', false)
on conflict (id) do nothing;

-- photos 버킷 경로: <baby_id>/<photo_id>/orig.jpg, <baby_id>/<photo_id>/thumb.jpg
create policy photos_object_select on storage.objects for select to authenticated
  using (bucket_id = 'photos'
         and public.is_member(public.safe_uuid((storage.foldername(name))[1])));

create policy photos_object_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'photos'
              and public.can_edit(public.safe_uuid((storage.foldername(name))[1])));

create policy photos_object_delete on storage.objects for delete to authenticated
  using (bucket_id = 'photos'
         and public.can_edit(public.safe_uuid((storage.foldername(name))[1])));

-- avatars 버킷 경로: <user_id>/avatar.jpg
create policy avatars_object_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars');

create policy avatars_object_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars'
              and (storage.foldername(name))[1] = auth.uid()::text);

create policy avatars_object_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = auth.uid()::text);

create policy avatars_object_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = auth.uid()::text);
