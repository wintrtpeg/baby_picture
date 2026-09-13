-- rls_test.sql — 권한 규칙 검증
--
-- 로컬 Postgres에서 Supabase 환경(auth/storage 스키마, authenticated 롤)을
-- 흉내 낸 뒤 실행한다. 실패하면 예외를 던지고 멈춘다.
--
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql

\set mom      '11111111-1111-1111-1111-111111111111'
\set dad      '22222222-2222-2222-2222-222222222222'
\set grandma  '33333333-3333-3333-3333-333333333333'
\set stranger '44444444-4444-4444-4444-444444444444'

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

insert into auth.users (id, email) values
  (:'mom', 'mom@test'), (:'dad', 'dad@test'),
  (:'grandma', 'grandma@test'), (:'stranger', 'stranger@test');

-- ===========================================================================
-- T1  아기를 만들면 만든 사람이 자동으로 관리자가 된다
-- ===========================================================================
select set_config('request.jwt.claim.sub', :'mom', false) \g /dev/null
set role authenticated;

insert into public.babies (id, name, birth_date, gender, created_by)
values ('aaaaaaaa-0000-0000-0000-000000000001', '서아', '2025-03-02', 'female', :'mom');

do $$ begin
  if (select count(*) from public.memberships
      where baby_id = 'aaaaaaaa-0000-0000-0000-000000000001' and role = 'owner') <> 1
  then raise exception 'T1 실패: 관리자 멤버십이 자동 생성되지 않음'; end if;
end $$;

-- ===========================================================================
-- T2  모먼트와 사진 등록. photos.baby_id가 트리거로 자동 채워진다
-- ===========================================================================
insert into public.moments (id, baby_id, title, taken_on, created_by)
values ('bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001', '첫 신발 신은 날', '2026-09-13', :'mom');

insert into public.photos (id, moment_id, baby_id, storage_path, thumb_path,
                           width, height, position, created_by)
values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000',  -- 일부러 틀린 값을 넣는다
   'x/orig.jpg', 'x/thumb.jpg', 3200, 2400, 0, :'mom'),
  ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000',
   'y/orig.jpg', 'y/thumb.jpg', 3200, 2400, 1, :'mom');

do $$ begin
  if (select count(*) from public.photos
      where baby_id = 'aaaaaaaa-0000-0000-0000-000000000001') <> 2
  then raise exception 'T2 실패: photos.baby_id가 모먼트와 동기화되지 않음'; end if;
end $$;

-- ===========================================================================
-- T3  남은 아무것도 못 본다
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'stranger', false) \g /dev/null
set role authenticated;

do $$
declare b int; m int; p int; f int;
begin
  select count(*) into b from public.babies;
  select count(*) into m from public.moments;
  select count(*) into p from public.photos;
  select count(*) into f from public.moment_feed;
  if (b, m, p, f) is distinct from (0, 0, 0, 0) then
    raise exception 'T3 실패: 남에게 데이터가 보인다 (babies=% moments=% photos=% feed=%)', b, m, p, f;
  end if;
end $$;

-- T3b  남은 초대를 만들 수 없다
do $$ begin
  begin
    perform public.create_invite('aaaaaaaa-0000-0000-0000-000000000001', 'caption', 7, 1);
    raise exception 'T3b 실패: 남이 초대를 만들 수 있었다';
  exception when others then
    if sqlerrm like 'T3b 실패%' then raise; end if;
  end;
end $$;

-- ===========================================================================
-- T4  초대 코드로 할머니가 문구 작성 권한으로 들어온다
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'mom', false) \g /dev/null
set role authenticated;

create temp table t_code as
select code from public.create_invite('aaaaaaaa-0000-0000-0000-000000000001', 'caption', 7, 1);

reset role;
select set_config('request.jwt.claim.sub', :'grandma', false) \g /dev/null
set role authenticated;

do $$
declare c text; b uuid;
begin
  select code into c from t_code;
  b := public.redeem_invite(c);
  if b <> 'aaaaaaaa-0000-0000-0000-000000000001' then
    raise exception 'T4 실패: 잘못된 아기에 연결됨';
  end if;
  if public.member_role(b) <> 'caption' then
    raise exception 'T4 실패: 권한이 caption이 아님 (%)', public.member_role(b);
  end if;
end $$;

-- T4b  같은 코드를 또 쓸 수 없다 (max_uses = 1)
reset role;
select set_config('request.jwt.claim.sub', :'stranger', false) \g /dev/null
set role authenticated;

do $$
declare c text;
begin
  select code into c from t_code;
  begin
    perform public.redeem_invite(c);
    raise exception 'T4b 실패: 다 쓴 초대 코드가 또 통했다';
  exception when others then
    if sqlerrm like 'T4b 실패%' then raise; end if;
  end;
end $$;

-- ===========================================================================
-- T5  할머니가 문구를 쓰면 작성자가 자동으로 기록된다
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'grandma', false) \g /dev/null
set role authenticated;

update public.photos set caption = '신발이 무거운지 자꾸 제 발끝만 본다.'
 where id = 'cccccccc-0000-0000-0000-000000000001';

do $$
declare a uuid; t timestamptz;
begin
  select caption_author_id, caption_updated_at into a, t
    from public.photos where id = 'cccccccc-0000-0000-0000-000000000001';
  if a <> '33333333-3333-3333-3333-333333333333' then
    raise exception 'T5 실패: 문구 작성자가 기록되지 않음 (%)', a;
  end if;
  if t is null then raise exception 'T5 실패: 문구 수정 시각이 비어 있음'; end if;
end $$;

-- ===========================================================================
-- T6  문구 작성 권한으로는 문구 외에 아무것도 못 바꾼다
-- ===========================================================================
do $$ begin
  begin
    update public.photos set position = 99
     where id = 'cccccccc-0000-0000-0000-000000000001';
    raise exception 'T6 실패: 문구 작성 권한으로 사진 순서를 바꿀 수 있었다';
  exception when others then
    if sqlerrm like 'T6 실패%' then raise; end if;
  end;
end $$;

-- T6b  사진을 지울 수도 없다
do $$
declare n int;
begin
  delete from public.photos where id = 'cccccccc-0000-0000-0000-000000000002';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'T6b 실패: 문구 작성 권한으로 사진이 삭제됐다'; end if;
end $$;

-- T6c  모먼트를 새로 만들 수도 없다
do $$ begin
  begin
    insert into public.moments (baby_id, title, taken_on, created_by)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '몰래', '2026-09-14',
            '33333333-3333-3333-3333-333333333333');
    raise exception 'T6c 실패: 문구 작성 권한으로 모먼트가 만들어졌다';
  exception when others then
    if sqlerrm like 'T6c 실패%' then raise; end if;
  end;
end $$;

-- ===========================================================================
-- T7  편집 권한은 사진을 올리고 고칠 수 있다
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'mom', false) \g /dev/null
set role authenticated;
create temp table t_code2 as
select code from public.create_invite('aaaaaaaa-0000-0000-0000-000000000001', 'editor', 7, 1);

reset role;
select set_config('request.jwt.claim.sub', :'dad', false) \g /dev/null
set role authenticated;

do $$
declare c text;
begin
  select code into c from t_code2;
  perform public.redeem_invite(c);
end $$;

insert into public.moments (id, baby_id, title, taken_on, created_by)
values ('bbbbbbbb-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000001', '할머니 댁에서', '2026-09-08',
        '22222222-2222-2222-2222-222222222222');

update public.photos set position = 5
 where id = 'cccccccc-0000-0000-0000-000000000002';

do $$ begin
  if (select position from public.photos
      where id = 'cccccccc-0000-0000-0000-000000000002') <> 5
  then raise exception 'T7 실패: 편집 권한으로 사진을 못 고쳤다'; end if;
end $$;

-- ===========================================================================
-- T8  moment_feed 뷰: 생후 일수와 문구 진행도가 맞는지
-- ===========================================================================
do $$
declare d int; pc bigint; cc bigint;
begin
  select day_offset, photo_count, caption_count into d, pc, cc
    from public.moment_feed where id = 'bbbbbbbb-0000-0000-0000-000000000001';
  -- 2025-03-02 출생, 2026-09-13 촬영 → 560일 경과 (화면 표기 "생후 561일"은 +1)
  if d <> 560 then raise exception 'T8 실패: day_offset이 %여야 하는데 %', 560, d; end if;
  if pc <> 2 then raise exception 'T8 실패: 사진 수가 2여야 하는데 %', pc; end if;
  if cc <> 1 then raise exception 'T8 실패: 문구 수가 1이어야 하는데 %', cc; end if;
end $$;

-- ===========================================================================
-- T9  만료된 초대는 통하지 않는다
-- ===========================================================================
reset role;
update public.invites set expires_at = now() - interval '1 day', use_count = 0
 where role = 'caption';

select set_config('request.jwt.claim.sub', :'stranger', false) \g /dev/null
set role authenticated;

do $$
declare c text;
begin
  select code into c from t_code;
  begin
    perform public.redeem_invite(c);
    raise exception 'T9 실패: 만료된 초대가 통했다';
  exception when others then
    if sqlerrm like 'T9 실패%' then raise; end if;
  end;
end $$;

-- ===========================================================================
-- T10  "문구를 기다리는 사진" 큐
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'mom', false) \g /dev/null
set role authenticated;

do $$
declare n bigint;
begin
  select count(*) into n from public.photos
   where baby_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and (caption is null or caption = '');
  if n <> 1 then raise exception 'T10 실패: 문구 대기 사진이 1장이어야 하는데 %', n; end if;
end $$;

-- ===========================================================================
-- T11  누구나 스스로 나갈 수 있고, 나가면 아무것도 안 보인다
-- ===========================================================================
reset role;
select set_config('request.jwt.claim.sub', :'grandma', false) \g /dev/null
set role authenticated;

delete from public.memberships where user_id = '33333333-3333-3333-3333-333333333333';

do $$
declare n int;
begin
  select count(*) into n from public.photos;
  if n <> 0 then raise exception 'T11 실패: 나간 뒤에도 사진이 보인다 (%)', n; end if;
end $$;

reset role;
\echo '=== RLS 테스트 전부 통과 ==='
