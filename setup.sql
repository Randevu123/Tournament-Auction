-- =====================================================================
-- 발로란트 내전 경매 — Supabase 설정 파일
-- Supabase 화면 왼쪽 메뉴 [SQL Editor]에 이 파일 내용을 통째로 붙여 넣고 [Run]을 누르세요.
-- 여러 번 실행해도 괜찮습니다. (함수는 새것으로 바뀌고, 저장된 경매는 그대로 남습니다)
--
-- 원칙
--  * 모든 규칙 검사(입찰 금액, 빈자리 몫, 시간)는 여기 서버 쪽 함수가 합니다.
--  * 입찰은 경매 줄(row)을 잠근 뒤 하나씩 처리하므로, 동시에 눌러도 먼저 도착한 하나만 인정됩니다.
--  * 표는 바깥에서 직접 읽거나 쓸 수 없습니다(RLS). 링크 열쇠(key)를 가진 사람만 함수로 조작합니다.
-- =====================================================================

create table if not exists public.auctions (
  id              uuid primary key default gen_random_uuid(),
  status          text not null default 'setup',   -- setup / ready / running / paused / result / done
  config          jsonb not null,                   -- 시작 포인트, 입찰 단위 같은 규칙 숫자
  current_player  int,
  bid_amount      int not null default 0,
  bid_team        int,
  ends_at         timestamptz,
  paused_left_ms  int,
  next_at         timestamptz,
  queue           int[] not null default '{}',
  auto_start      boolean not null default false,
  last_result     jsonb,
  players_version int not null default 1,
  version         bigint not null default 1,
  created_at      timestamptz not null default now()
);

create table if not exists public.auction_keys (
  key        text primary key,
  auction_id uuid not null references public.auctions on delete cascade,
  role       text not null,          -- host / team
  team_idx   int
);

create table if not exists public.teams (
  auction_id uuid not null references public.auctions on delete cascade,
  idx        int not null,
  name       text not null,
  color      text not null,
  points     int not null,
  primary key (auction_id, idx)
);

create table if not exists public.players (
  auction_id   uuid not null references public.auctions on delete cascade,
  id           int not null,
  name         text not null,
  peak         text not null,
  current_tier text not null,
  pos          text not null,
  captain      boolean not null default false,
  motto        text not null default '',
  photo        text not null default '',
  unsold       int not null default 0,
  team_idx     int,
  price        int,
  how          text,                  -- captain / bid / random
  primary key (auction_id, id)
);

create table if not exists public.events (
  id         bigserial primary key,
  auction_id uuid not null references public.auctions on delete cascade,
  kind       text not null,
  body       text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat (
  id         bigserial primary key,
  auction_id uuid not null references public.auctions on delete cascade,
  sender     text not null,
  color      text not null,
  body       text not null,
  created_at timestamptz not null default now()
);

-- 3단계: 참가 신청 (디스코드 로그인)
-- 신청 링크에는 경매 번호 대신 신청 전용 코드를 씀 (신청 링크는 공개되므로 경매 번호를 숨김)
alter table public.auctions add column if not exists signup_code text not null default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists auctions_signup_code_idx on public.auctions (signup_code);

create table if not exists public.signups (
  id               bigserial primary key,
  auction_id       uuid not null references public.auctions on delete cascade,
  user_id          uuid not null,          -- Supabase 로그인 계정 (디스코드 계정 1개 = 1개)
  discord_id       text not null default '',
  discord_name     text not null default '',
  discord_username text not null default '',
  discord_avatar   text not null default '',
  nick             text not null,
  peak             text not null,
  current_tier     text not null,
  pos              text not null,
  created_at       timestamptz not null default now(),
  unique (auction_id, user_id)            -- 같은 계정은 한 경매에 한 번만
);
alter table public.signups enable row level security;
revoke all on public.signups from anon, authenticated;

-- 운영진 콘솔: 운영진 명단, 회차 일정, 신청 마감, 검수, 할 일
create table if not exists public.staff (
  user_id          uuid primary key,        -- 디스코드로 로그인한 계정
  role             text not null check (role in ('owner', 'staff', 'pending')),   -- 진행자 / 운영진 / 승인 대기
  discord_name     text not null default '',
  discord_username text not null default '',
  discord_avatar   text not null default '',
  created_at       timestamptz not null default now(),
  approved_at      timestamptz
);
create unique index if not exists staff_one_owner on public.staff (role) where role = 'owner';

create table if not exists public.site_settings (
  id          int primary key default 1 check (id = 1),
  invite_code text not null default replace(gen_random_uuid()::text, '-', '')   -- 운영진 초대 링크 코드
);
insert into public.site_settings (id) values (1) on conflict do nothing;

alter table public.auctions add column if not exists title            text not null default '';
alter table public.auctions add column if not exists signup_opens_at  timestamptz;
alter table public.auctions add column if not exists signup_closes_at timestamptz;
alter table public.auctions add column if not exists signup_mode      text not null default 'auto';  -- auto(일정대로) / open / closed
alter table public.auctions add column if not exists auction_at       timestamptz;
alter table public.auctions add column if not exists match_at         timestamptz;

alter table public.signups add column if not exists captain    boolean not null default false;  -- 팀장 배정
alter table public.signups add column if not exists memo       text not null default '';        -- 운영진끼리만 보는 메모
alter table public.signups add column if not exists updated_at timestamptz;
alter table public.signups add column if not exists updated_by text not null default '';

create table if not exists public.signup_checks (          -- 교차검수: 서로 다른 운영진 2명이 확인하면 확정
  signup_id  bigint not null references public.signups on delete cascade,
  kind       text not null check (kind in ('tier', 'score')),   -- 티어 확인 / 티어 점수 계산 재확인
  user_id    uuid not null,
  staff_name text not null default '',
  at         timestamptz not null default now(),
  primary key (signup_id, kind, user_id)
);

create table if not exists public.tasks (                  -- 회차별 운영진 할 일
  id         bigserial primary key,
  auction_id uuid not null references public.auctions on delete cascade,
  title      text not null,
  assignee   uuid,
  due_at     timestamptz,
  done       boolean not null default false,
  done_at    timestamptz,
  created_by text not null default '',
  created_at timestamptz not null default now()
);

alter table public.staff         enable row level security;
alter table public.site_settings enable row level security;
alter table public.signup_checks enable row level security;
alter table public.tasks         enable row level security;
revoke all on public.staff, public.site_settings, public.signup_checks, public.tasks from anon, authenticated;

-- 시각을 화면용 숫자(밀리초)로
create or replace function public._ms(t timestamptz) returns bigint
language sql immutable as $$ select (extract(epoch from t) * 1000)::bigint $$;

-- 지금 신청을 받는 중인지: 버튼(open/closed)이 우선, auto면 신청 시작~마감 시각으로 판단
create or replace function public._signup_open(a public.auctions) returns boolean
language sql stable as $$
  select case a.signup_mode
    when 'open' then true
    when 'closed' then false
    else (a.signup_opens_at is null or now() >= a.signup_opens_at)
     and (a.signup_closes_at is null or now() < a.signup_closes_at) end
$$;

create index if not exists events_auction_idx on public.events (auction_id, id desc);
create index if not exists chat_auction_idx on public.chat (auction_id, id);

-- 바깥에서 표를 직접 읽고 쓰지 못하게 잠금 (정책을 하나도 만들지 않음 = 전부 막힘)
alter table public.auctions     enable row level security;
alter table public.auction_keys enable row level security;
alter table public.teams        enable row level security;
alter table public.players      enable row level security;
alter table public.events       enable row level security;
alter table public.chat         enable row level security;
revoke all on public.auctions, public.auction_keys, public.teams, public.players, public.events, public.chat from anon, authenticated;

-- =====================================================================
-- 내부용 도우미 함수 (바깥에서 호출 불가)
-- =====================================================================

create or replace function public._cfg_int(a public.auctions, k text) returns int
language sql immutable as $$ select (a.config ->> k)::int $$;

create or replace function public._auth(p_id uuid, p_key text, out role text, out team_idx int)
language sql stable security definer set search_path = public as $$
  select k.role, k.team_idx from auction_keys k where k.key = p_key and k.auction_id = p_id
$$;

create or replace function public._log(p_id uuid, p_kind text, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into events (auction_id, kind, body) values (p_id, p_kind, p_body)
$$;

create or replace function public._open_slots(p_id uuid, p_team int) returns int
language sql stable security definer set search_path = public as $$
  select (select (config ->> 'teamSize')::int from auctions where id = p_id)
       - (select count(*)::int from players where auction_id = p_id and team_idx = p_team)
$$;

create or replace function public._state(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', a.id, 'status', a.status, 'config', a.config,
    'current', a.current_player, 'bid_amount', a.bid_amount, 'bid_team', a.bid_team,
    'ends_at', (extract(epoch from a.ends_at) * 1000)::bigint,
    'next_at', (extract(epoch from a.next_at) * 1000)::bigint,
    'paused_left_ms', a.paused_left_ms,
    'queue', to_jsonb(a.queue), 'auto_start', a.auto_start, 'last_result', a.last_result,
    'players_version', a.players_version, 'version', a.version,
    'server_now', (extract(epoch from clock_timestamp()) * 1000)::bigint,
    'teams', (select coalesce(jsonb_agg(jsonb_build_object('idx', t.idx, 'name', t.name, 'color', t.color, 'points', t.points) order by t.idx), '[]')
              from teams t where t.auction_id = a.id),
    'players', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', p.id, 'name', p.name, 'peak', p.peak, 'current', p.current_tier, 'pos', p.pos,
                  'captain', p.captain, 'motto', p.motto, 'unsold', p.unsold,
                  'team', p.team_idx, 'price', p.price, 'how', p.how) order by p.id), '[]')
                from players p where p.auction_id = a.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'body', e.body) order by e.id desc), '[]')
               from (select * from events where auction_id = a.id order by id desc limit 40) e)
  ) from auctions a where a.id = p_id
$$;

-- 선수 명단을 통째로 다시 넣기 (준비 단계에서만)
create or replace function public._load_players(p_id uuid, p_players jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  a auctions; v_colors jsonb; v_idx int := 0; r record;
begin
  select * into a from auctions where id = p_id;
  v_colors := a.config -> 'teamColors';
  delete from players where auction_id = p_id;
  delete from teams where auction_id = p_id;
  insert into players (auction_id, id, name, peak, current_tier, pos, captain, motto, photo)
  select p_id, (e.ordinality - 1)::int,
         left(trim(e.value ->> 'name'), 16), e.value ->> 'peak', e.value ->> 'current', e.value ->> 'pos',
         coalesce((e.value ->> 'captain')::boolean, false),
         left(coalesce(trim(e.value ->> 'motto'), ''), 60),
         case when coalesce(e.value ->> 'photo', '') like 'data:image/%' and length(e.value ->> 'photo') <= 400000
              then e.value ->> 'photo' else '' end
  from jsonb_array_elements(p_players) with ordinality e;
  for r in select id, name from players where auction_id = p_id and captain order by id loop
    insert into teams (auction_id, idx, name, color, points)
    values (p_id, v_idx, r.name || ' 팀', coalesce(v_colors ->> (v_idx % greatest(jsonb_array_length(v_colors), 1)), '#ff4655'),
            _cfg_int(a, 'startPoints'));
    update players set team_idx = v_idx, price = 0, how = 'captain' where auction_id = p_id and id = r.id;
    v_idx := v_idx + 1;
  end loop;
  update auctions set queue = (select coalesce(array_agg(id order by id), '{}') from players where auction_id = p_id and not captain)
  where id = p_id;
end $$;

-- 명단 검사 (문제가 있으면 이유 글자를 돌려줌)
create or replace function public._check_players(p_config jsonb, p_players jsonb) returns text
language plpgsql immutable as $$
declare v_caps int; v_n int; v_names int;
begin
  if jsonb_typeof(p_players) <> 'array' then return '선수 명단 형식이 잘못됐어요.'; end if;
  v_n := jsonb_array_length(p_players);
  if v_n < 2 or v_n > 80 then return '선수는 2명에서 80명 사이여야 해요.'; end if;
  select count(*) filter (where coalesce((e ->> 'captain')::boolean, false)),
         count(distinct trim(e ->> 'name'))
    into v_caps, v_names from jsonb_array_elements(p_players) e;
  if v_caps <> (p_config ->> 'teamCount')::int then
    return format('팀장은 %s명이어야 해요. 지금 %s명입니다.', p_config ->> 'teamCount', v_caps);
  end if;
  if v_names <> v_n then return '같은 닉네임이 있거나 비어 있는 닉네임이 있어요.'; end if;
  if exists (select 1 from jsonb_array_elements(p_players) e where coalesce(trim(e ->> 'name'), '') = '') then
    return '닉네임이 비어 있는 선수가 있어요.';
  end if;
  return null;
end $$;

-- 한 선수의 경매를 마무리 (낙찰 / 유찰 / 무작위 배정)
create or replace function public._finish(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  a auctions; p players; t teams; v_team int; v_result jsonb;
begin
  select * into a from auctions where id = p_id;
  select * into p from players where auction_id = p_id and id = a.current_player;
  if a.bid_team is not null then
    select * into t from teams where auction_id = p_id and idx = a.bid_team;
    update teams set points = points - a.bid_amount where auction_id = p_id and idx = a.bid_team;
    update players set team_idx = a.bid_team, price = a.bid_amount, how = 'bid' where auction_id = p_id and id = p.id;
    perform _log(p_id, 'sold', format('낙찰! %s → %s (%sP)', p.name, t.name, a.bid_amount));
    v_result := jsonb_build_object('kind', 'sold', 'player', p.id, 'team', a.bid_team, 'price', a.bid_amount);
  else
    update players set unsold = unsold + 1 where auction_id = p_id and id = p.id;
    if p.unsold + 1 >= _cfg_int(a, 'maxUnsold') then
      select tm.idx into v_team from teams tm
       where tm.auction_id = p_id and _open_slots(p_id, tm.idx) > 0
       order by random() limit 1;
      if v_team is not null then
        select * into t from teams where auction_id = p_id and idx = v_team;
        update players set team_idx = v_team, price = 0, how = 'random' where auction_id = p_id and id = p.id;
        perform _log(p_id, 'unsold', format('%s %s번째 유찰 → %s에 무작위 배정 (0P)', p.name, p.unsold + 1, t.name));
        v_result := jsonb_build_object('kind', 'random', 'player', p.id, 'team', v_team);
      else
        perform _log(p_id, 'unsold', format('%s 유찰 — 빈자리가 있는 팀이 없어요', p.name));
        v_result := jsonb_build_object('kind', 'unsold', 'player', p.id);
      end if;
    else
      update auctions set queue = queue || p.id where id = p_id;
      perform _log(p_id, 'unsold', format('유찰 — %s 순서 맨 뒤로 (%s번째 유찰)', p.name, p.unsold + 1));
      v_result := jsonb_build_object('kind', 'unsold', 'player', p.id);
    end if;
  end if;
  update auctions set status = 'result', ends_at = null, paused_left_ms = null,
         next_at = clock_timestamp() + make_interval(secs => _cfg_int(a, 'resultShowMs') / 1000.0),
         last_result = v_result || jsonb_build_object('seq', a.version + 1)
   where id = p_id;
end $$;

-- 다음 선수 올리기
create or replace function public._next(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a auctions; v_open boolean;
begin
  select * into a from auctions where id = p_id;
  select exists (select 1 from teams tm where tm.auction_id = p_id and _open_slots(p_id, tm.idx) > 0) into v_open;
  if not v_open or coalesce(cardinality(a.queue), 0) = 0 then
    update auctions set status = 'done', current_player = null, bid_amount = 0, bid_team = null,
           ends_at = null, next_at = null where id = p_id;
    perform _log(p_id, 'sold', case when cardinality(a.queue) > 0
      then format('모든 팀이 꽉 찼습니다. 남은 선수 %s명.', cardinality(a.queue)) else '모든 선수의 경매가 끝났습니다.' end);
    return;
  end if;
  update auctions set current_player = a.queue[1], queue = a.queue[2:], bid_amount = 0, bid_team = null,
         next_at = null, paused_left_ms = null,
         status = case when a.auto_start then 'running' else 'ready' end,
         ends_at = case when a.auto_start then clock_timestamp() + make_interval(secs => _cfg_int(a, 'startSeconds')) end
   where id = p_id;
  if a.auto_start then
    perform _log(p_id, '', format('%s 경매 시작 (%s초)', (select name from players where auction_id = p_id and id = a.queue[1]), _cfg_int(a, 'startSeconds')));
  end if;
end $$;

create or replace function public._bump(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update auctions set version = version + 1 where id = p_id
$$;

-- =====================================================================
-- 바깥에서 부르는 함수 (화면이 사용)
-- =====================================================================

-- 새 경매 만들기: 진행자 열쇠 1개 + 팀장 열쇠를 팀 수만큼 만들어 돌려줌
create or replace function public.create_auction(p_config jsonb, p_players jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_err text; v_host text; v_keys jsonb := '[]'; v_k text; i int;
begin
  if exists (select 1 from staff where role = 'owner') then
    return jsonb_build_object('ok', false, 'reason', '진행자가 등록된 뒤에는 운영진 콘솔(admin.html)에서 회차를 만들어 주세요.');
  end if;
  v_err := _check_players(p_config, p_players);
  if v_err is not null then return jsonb_build_object('ok', false, 'reason', v_err); end if;
  insert into auctions (config) values (p_config) returning id into v_id;
  perform _load_players(v_id, p_players);
  v_host := replace(gen_random_uuid()::text, '-', '');
  insert into auction_keys (key, auction_id, role) values (v_host, v_id, 'host');
  for i in 0 .. (p_config ->> 'teamCount')::int - 1 loop
    v_k := replace(gen_random_uuid()::text, '-', '');
    insert into auction_keys (key, auction_id, role, team_idx) values (v_k, v_id, 'team', i);
    v_keys := v_keys || to_jsonb(v_k);
  end loop;
  perform _log(v_id, '', '온라인 경매를 만들었습니다.');
  return jsonb_build_object('ok', true, 'id', v_id, 'host_key', v_host, 'team_keys', v_keys);
end $$;

-- 이 열쇠가 누구 것인지 (진행자 / 몇 번 팀)
create or replace function public.whoami(p_id uuid, p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when w.role is null then null else jsonb_build_object('role', w.role, 'team', w.team_idx) end
  from _auth(p_id, p_key) w
$$;

-- 진행자가 팀장 링크를 다시 볼 때
create or replace function public.get_links(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return null; end if;
  return jsonb_build_object(
    'teams', (select jsonb_agg(key order by team_idx) from auction_keys where auction_id = p_id and role = 'team'),
    'signup_code', (select signup_code from auctions where id = p_id));
end $$;

create or replace function public.get_state(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is null then return null; end if;
  return _state(p_id);
end $$;

create or replace function public.get_photos(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is null then return null; end if;
  return (select coalesce(jsonb_object_agg(id::text, photo), '{}') from players where auction_id = p_id and photo <> '');
end $$;

create or replace function public.get_chat(p_id uuid, p_key text, p_after bigint default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is null then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'sender', c.sender, 'color', c.color, 'body', c.body,
            'at', (extract(epoch from c.created_at) * 1000)::bigint) order by c.id), '[]')
          from (select * from chat where auction_id = p_id and id > coalesce(p_after, 0) order by id desc limit 100) c);
end $$;

create or replace function public.send_chat(p_id uuid, p_key text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; v_body text := left(trim(coalesce(p_body, '')), 200); v_name text; v_color text; v_row chat;
begin
  select * into w from _auth(p_id, p_key);
  if w.role is null then return jsonb_build_object('ok', false, 'reason', '링크가 올바르지 않아요.'); end if;
  if v_body = '' then return jsonb_build_object('ok', false, 'reason', '빈 메시지는 보낼 수 없어요.'); end if;
  if w.role = 'host' then v_name := '진행자'; v_color := '#ffffff';
  else select name, color into v_name, v_color from teams where auction_id = p_id and idx = w.team_idx; end if;
  insert into chat (auction_id, sender, color, body) values (p_id, v_name, v_color, v_body) returning * into v_row;
  return jsonb_build_object('ok', true, 'msg', jsonb_build_object('id', v_row.id, 'sender', v_row.sender, 'color', v_row.color,
           'body', v_row.body, 'at', (extract(epoch from v_row.created_at) * 1000)::bigint));
end $$;

-- 팀장 입찰: 경매 줄을 잠그고(for update) 검사하므로 동시에 와도 하나씩 처리됨
create or replace function public.place_bid(p_id uuid, p_key text, p_amount int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  w record; a auctions; t teams; v_now timestamptz; v_open int; v_step int; v_reserve int; v_reason text;
  v_before numeric; v_after numeric;
begin
  select * into w from _auth(p_id, p_key);
  if w.role is distinct from 'team' then return jsonb_build_object('ok', false, 'reason', '팀장 링크가 아니에요.'); end if;
  select * into a from auctions where id = p_id for update;          -- ← 여기서 한 줄로 세움
  v_now := clock_timestamp();
  select * into t from teams where auction_id = p_id and idx = w.team_idx;
  v_step := _cfg_int(a, 'bidStep');
  v_open := _open_slots(p_id, t.idx);
  v_reserve := _cfg_int(a, 'reservePerSlot') * greatest(v_open - 1, 0);

  if a.status <> 'running' then v_reason := '경매 진행 중이 아니에요.';
  elsif v_now >= a.ends_at then v_reason := '시간이 끝났어요.';
  elsif a.bid_team = t.idx then v_reason := '이미 우리 팀이 최고가예요.';
  elsif p_amount is null or p_amount < a.bid_amount + v_step then
    v_reason := case when a.bid_team is not null
      then format('%s의 %sP 입찰이 먼저 도착했어요.', (select name from teams where auction_id = p_id and idx = a.bid_team), a.bid_amount)
      else format('최소 %sP부터 입찰할 수 있어요.', v_step) end;
  elsif p_amount % v_step <> 0 then v_reason := format('%sP 단위로만 입찰할 수 있어요.', v_step);
  elsif v_open <= 0 then v_reason := '팀 인원이 꽉 찼어요.';
  elsif p_amount > t.points then v_reason := '포인트가 부족해요.';
  elsif p_amount > t.points - v_reserve then
    v_reason := format('빈자리 %s칸 몫 %sP는 남겨야 해요.', v_open - 1, v_reserve);
  end if;

  if v_reason is not null then
    if a.status = 'running' then
      perform _log(p_id, 'reject', format('%s %sP 입찰 거절 — %s', t.name, coalesce(p_amount, 0), v_reason));
      perform _bump(p_id);
    end if;
    return jsonb_build_object('ok', false, 'reason', v_reason, 'state', _state(p_id));
  end if;

  v_before := greatest(extract(epoch from a.ends_at - v_now), 0);
  v_after := least(v_before + _cfg_int(a, 'bidAddSeconds'), _cfg_int(a, 'maxSeconds'));
  update auctions set bid_amount = p_amount, bid_team = t.idx,
         ends_at = v_now + make_interval(secs => v_after::double precision), version = version + 1
   where id = p_id;
  perform _log(p_id, 'bid', format('%s %sP 입찰 · 시간 %s초 → %s초', t.name, p_amount, round(v_before, 1), round(v_after, 1)));
  return jsonb_build_object('ok', true, 'state', _state(p_id));
end $$;

-- 시간이 다 됐는지 확인하고 다음으로 넘기기 (진행자·팀장 누구 화면이 불러도 한 번만 처리됨)
create or replace function public.tick(p_id uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; v_now timestamptz; v_changed boolean := false;
begin
  if (select role from _auth(p_id, p_key)) is null then return jsonb_build_object('ok', false, 'reason', '링크가 올바르지 않아요.'); end if;
  select * into a from auctions where id = p_id for update;
  v_now := clock_timestamp();
  if a.status = 'running' and v_now >= a.ends_at then
    perform _finish(p_id); v_changed := true;
  elsif a.status = 'result' and v_now >= a.next_at then
    perform _next(p_id); v_changed := true;
  end if;
  if v_changed then perform _bump(p_id); end if;
  return jsonb_build_object('ok', true, 'changed', v_changed, 'state', _state(p_id));
end $$;

-- 진행자 조작: set_players / set_order / start / pause / resume / hammer / next / auto / reset
create or replace function public.host_action(p_id uuid, p_key text, p_action text, p_arg jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; v_reason text; v_ids int[]; v_pool int[]; v_left numeric;
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then
    return jsonb_build_object('ok', false, 'reason', '진행자 링크가 아니에요.');
  end if;
  select * into a from auctions where id = p_id for update;

  if p_action = 'set_players' then
    if a.status <> 'setup' then v_reason := '경매 준비 단계에서만 고칠 수 있어요.';
    else
      v_reason := _check_players(a.config, p_arg);
      if v_reason is null then
        perform _load_players(p_id, p_arg);
        update auctions set players_version = players_version + 1 where id = p_id;
        perform _log(p_id, '', '선수 정보를 저장했습니다.');
      end if;
    end if;

  elsif p_action = 'set_order' then
    select array_agg(x::int order by o) into v_ids from jsonb_array_elements_text(p_arg) with ordinality as j(x, o);
    select coalesce(array_agg(id order by id), '{}') into v_pool from players where auction_id = p_id and team_idx is null;
    if a.status <> 'setup' then v_reason := '이미 순서를 뽑았어요.';
    elsif v_ids is null or cardinality(v_ids) <> cardinality(v_pool)
       or (select array_agg(x order by x) from unnest(v_ids) x) <> v_pool then
      v_reason := '순서 목록이 선수 명단과 맞지 않아요.';
    else
      update auctions set queue = v_ids where id = p_id;
      perform _log(p_id, '', format('경매 순서 추첨 완료 — 1번 %s', (select name from players where auction_id = p_id and id = v_ids[1])));
      perform _next(p_id);
    end if;

  elsif p_action = 'start' then
    if a.status <> 'ready' then v_reason := '시작할 수 있는 상태가 아니에요.';
    else
      update auctions set status = 'running', ends_at = clock_timestamp() + make_interval(secs => _cfg_int(a, 'startSeconds')) where id = p_id;
      perform _log(p_id, '', format('%s 경매 시작 (%s초)', (select name from players where auction_id = p_id and id = a.current_player), _cfg_int(a, 'startSeconds')));
    end if;

  elsif p_action = 'pause' then
    if a.status <> 'running' then v_reason := '진행 중이 아니에요.';
    else
      v_left := greatest(extract(epoch from a.ends_at - clock_timestamp()) * 1000, 0);
      update auctions set status = 'paused', paused_left_ms = v_left::int, ends_at = null where id = p_id;
      perform _log(p_id, '', '일시정지');
    end if;

  elsif p_action = 'resume' then
    if a.status <> 'paused' then v_reason := '일시정지 상태가 아니에요.';
    else
      update auctions set status = 'running', ends_at = clock_timestamp() + make_interval(secs => a.paused_left_ms / 1000.0), paused_left_ms = null where id = p_id;
      perform _log(p_id, '', '다시 진행');
    end if;

  elsif p_action = 'hammer' then
    if a.status not in ('running', 'paused') then v_reason := '마감할 경매가 없어요.';
    else perform _finish(p_id); end if;

  elsif p_action = 'next' then
    if a.status <> 'result' then v_reason := '결과 발표 중에만 넘길 수 있어요.';
    else perform _next(p_id); end if;

  elsif p_action = 'auto' then
    update auctions set auto_start = coalesce((p_arg #>> '{}')::boolean, false) where id = p_id;

  elsif p_action = 'reset' then
    update teams set points = _cfg_int(a, 'startPoints') where auction_id = p_id;
    update players set unsold = 0, team_idx = null, price = null, how = null where auction_id = p_id and not captain;
    update auctions set status = 'setup', current_player = null, bid_amount = 0, bid_team = null, ends_at = null,
           paused_left_ms = null, next_at = null, last_result = null,
           queue = (select coalesce(array_agg(id order by id), '{}') from players where auction_id = p_id and not captain)
     where id = p_id;
    perform _log(p_id, '', '처음부터 다시 — 경매 결과를 지웠습니다.');

  else v_reason := '알 수 없는 조작이에요.';
  end if;

  if v_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_reason, 'state', _state(p_id));
  end if;
  perform _bump(p_id);
  return jsonb_build_object('ok', true, 'state', _state(p_id));
end $$;

-- =====================================================================
-- 권한: 도우미 함수는 막고, 화면용 함수만 열어 둠
-- =====================================================================
revoke execute on function public._cfg_int(public.auctions, text), public._auth(uuid, text), public._log(uuid, text, text),
  public._open_slots(uuid, int), public._state(uuid), public._load_players(uuid, jsonb), public._check_players(jsonb, jsonb),
  public._finish(uuid), public._next(uuid), public._bump(uuid)
  from public, anon, authenticated;

revoke execute on function public.create_auction(jsonb, jsonb), public.whoami(uuid, text), public.get_links(uuid, text),
  public.get_state(uuid, text), public.get_photos(uuid, text), public.get_chat(uuid, text, bigint),
  public.send_chat(uuid, text, text), public.place_bid(uuid, text, int), public.tick(uuid, text),
  public.host_action(uuid, text, text, jsonb)
  from public;
grant execute on function public.create_auction(jsonb, jsonb), public.whoami(uuid, text), public.get_links(uuid, text),
  public.get_state(uuid, text), public.get_photos(uuid, text), public.get_chat(uuid, text, bigint),
  public.send_chat(uuid, text, text), public.place_bid(uuid, text, int), public.tick(uuid, text),
  public.host_action(uuid, text, text, jsonb)
  to anon, authenticated;

-- =====================================================================
-- 3단계: 디스코드 로그인 참가 신청
-- =====================================================================

-- 티어와 포지션 목록 (화면의 점수표와 같은 이름)
create or replace function public._valid_tier(t text) returns boolean
language sql immutable as $$
  select t = any (array[
    '아이언 1','아이언 2','아이언 3','브론즈 1','브론즈 2','브론즈 3','실버 1','실버 2','실버 3',
    '골드 1','골드 2','골드 3','플래티넘 1','플래티넘 2','플래티넘 3','다이아몬드 1','다이아몬드 2','다이아몬드 3',
    '초월자 1','초월자 2','초월자 3','불멸 1','불멸 2','불멸 3','레디언트'])
$$;
create or replace function public._valid_pos(t text) returns boolean
language sql immutable as $$ select t = any (array['타격대','척후대','감시자','전략가']) $$;

create or replace function public._signup_json(s public.signups) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', s.id, 'discord_name', s.discord_name, 'discord_username', s.discord_username,
    'discord_avatar', s.discord_avatar, 'nick', s.nick, 'peak', s.peak, 'current', s.current_tier, 'pos', s.pos,
    'at', (extract(epoch from s.created_at) * 1000)::bigint)
$$;

-- 신청 링크가 살아 있는지 (로그인 전에도 확인 가능)
create or replace function public.signup_info(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a auctions;
begin
  select * into a from auctions where signup_code = p_code;
  if a.id is null then return null; end if;
  return jsonb_build_object('ok', true, 'count', (select count(*) from signups where auction_id = a.id),
    'title', a.title, 'open', _signup_open(a),
    'opens_at', _ms(a.signup_opens_at), 'closes_at', _ms(a.signup_closes_at),
    'auction_at', _ms(a.auction_at), 'match_at', _ms(a.match_at));
end $$;

-- 로그인한 사람이 이미 신청했는지
create or replace function public.my_signup(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_auction uuid; s signups;
begin
  if auth.uid() is null then return null; end if;
  select id into v_auction from auctions where signup_code = p_code;
  select * into s from signups where auction_id = v_auction and user_id = auth.uid();
  if s.id is null then return null; end if;
  return _signup_json(s);
end $$;

-- 신청하기: 디스코드 이름은 브라우저가 보낸 값이 아니라 로그인 정보에서 서버가 직접 꺼냄
create or replace function public.submit_signup(p_code text, p_nick text, p_peak text, p_current text, p_pos text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_auction uuid; v_meta jsonb; v_nick text := left(trim(coalesce(p_nick, '')), 16);
  v_name text; v_user text; s signups;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 로그인해야 신청할 수 있어요.'); end if;
  select id into v_auction from auctions where signup_code = p_code;
  if v_auction is null then return jsonb_build_object('ok', false, 'reason', '신청 링크가 올바르지 않아요.'); end if;
  if not _signup_open((select x from auctions x where x.id = v_auction)) then
    return jsonb_build_object('ok', false, 'reason', '지금은 신청 기간이 아니에요.');
  end if;
  select * into s from signups where auction_id = v_auction and user_id = v_uid;
  if s.id is not null then
    return jsonb_build_object('ok', false, 'reason', '이미 이 디스코드 계정으로 신청했어요.', 'signup', _signup_json(s));
  end if;
  if v_nick = '' then return jsonb_build_object('ok', false, 'reason', '게임 닉네임을 적어 주세요.'); end if;
  if not coalesce(_valid_tier(p_peak), false) then return jsonb_build_object('ok', false, 'reason', '최고 티어를 골라 주세요.'); end if;
  if not coalesce(_valid_tier(p_current), false) then return jsonb_build_object('ok', false, 'reason', '현재 티어를 골라 주세요.'); end if;
  if not coalesce(_valid_pos(p_pos), false) then return jsonb_build_object('ok', false, 'reason', '포지션을 골라 주세요.'); end if;

  select coalesce(raw_user_meta_data, '{}') into v_meta from auth.users where id = v_uid;
  v_user := regexp_replace(coalesce(v_meta ->> 'full_name', v_meta ->> 'name', ''), '#0$', '');
  v_name := coalesce(nullif(v_meta #>> '{custom_claims,global_name}', ''), nullif(v_user, ''), '이름 없음');

  insert into signups (auction_id, user_id, discord_id, discord_name, discord_username, discord_avatar, nick, peak, current_tier, pos)
  values (v_auction, v_uid, coalesce(v_meta ->> 'provider_id', v_meta ->> 'sub', ''), left(v_name, 40), left(v_user, 40),
          left(coalesce(v_meta ->> 'avatar_url', ''), 300), v_nick, p_peak, p_current, p_pos)
  on conflict (auction_id, user_id) do nothing
  returning * into s;
  if s.id is null then       -- 거의 동시에 두 번 눌렀을 때
    select * into s from signups where auction_id = v_auction and user_id = v_uid;
    return jsonb_build_object('ok', false, 'reason', '이미 이 디스코드 계정으로 신청했어요.', 'signup', _signup_json(s));
  end if;
  return jsonb_build_object('ok', true, 'signup', _signup_json(s));
end $$;

-- 진행자 화면의 신청 명단
create or replace function public.get_signups(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return null; end if;
  return (select coalesce(jsonb_agg(_signup_json(s) order by s.id), '[]') from signups s where s.auction_id = p_id);
end $$;

revoke execute on function public._valid_tier(text), public._valid_pos(text), public._signup_json(public.signups)
  from public, anon, authenticated;
revoke execute on function public.signup_info(text), public.my_signup(text),
  public.submit_signup(text, text, text, text, text), public.get_signups(uuid, text) from public;
grant execute on function public.signup_info(text), public.my_signup(text),
  public.submit_signup(text, text, text, text, text), public.get_signups(uuid, text) to anon, authenticated;

-- =====================================================================
-- 운영진 콘솔 (admin.html) — 디스코드로 로그인한 진행자·운영진만
-- =====================================================================

-- 로그인한 계정의 디스코드 이름 (서버가 로그인 정보에서 직접 꺼냄)
create or replace function public._discord_of(p_uid uuid, out name text, out username text, out avatar text)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(x.m #>> '{custom_claims,global_name}', ''), nullif(x.u, ''), '이름 없음'), x.u, coalesce(x.m ->> 'avatar_url', '')
  from (select coalesce(raw_user_meta_data, '{}') m,
               regexp_replace(coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', ''), '#0$', '') u
        from auth.users where id = p_uid) x
$$;

create or replace function public._my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from staff where user_id = auth.uid()
$$;

create or replace function public._is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(_my_role() in ('owner', 'staff'), false)
$$;

create or replace function public._no() returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'reason', '운영진만 할 수 있어요. 디스코드로 로그인했는지 확인해 주세요.') $$;

-- 내 상태: 로그인 여부, 역할, 진행자 등록 여부
create or replace function public.my_role() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record;
begin
  if auth.uid() is null then
    return jsonb_build_object('logged_in', false, 'owner_exists', exists (select 1 from staff where role = 'owner'));
  end if;
  select * into d from _discord_of(auth.uid());
  return jsonb_build_object('logged_in', true, 'role', _my_role(), 'user_id', auth.uid(),
    'owner_exists', exists (select 1 from staff where role = 'owner'),
    'name', d.name, 'username', d.username, 'avatar', d.avatar);
end $$;

-- 진행자(주인) 등록: 아직 진행자가 없을 때, 진행자 링크(경매 진행자 열쇠)를 가진 사람만
create or replace function public.claim_owner(p_id uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 먼저 로그인해 주세요.'); end if;
  if exists (select 1 from staff where role = 'owner') then return jsonb_build_object('ok', false, 'reason', '이미 진행자가 등록돼 있어요.'); end if;
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return jsonb_build_object('ok', false, 'reason', '진행자 링크가 올바르지 않아요.'); end if;
  select * into d from _discord_of(auth.uid());
  insert into staff (user_id, role, discord_name, discord_username, discord_avatar, approved_at)
  values (auth.uid(), 'owner', d.name, d.username, d.avatar, now())
  on conflict (user_id) do update set role = 'owner', approved_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- 운영진 요청 (초대 링크 + 디스코드 로그인) → 진행자가 승인해야 운영진이 됨
create or replace function public.request_staff(p_invite text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record; v_role text := _my_role();
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 먼저 로그인해 주세요.'); end if;
  if v_role is not null then return jsonb_build_object('ok', true, 'role', v_role); end if;
  if p_invite is distinct from (select invite_code from site_settings where id = 1) then
    return jsonb_build_object('ok', false, 'reason', '초대 링크가 올바르지 않거나 새로 바뀌었어요. 진행자에게 다시 받아 주세요.');
  end if;
  select * into d from _discord_of(auth.uid());
  insert into staff (user_id, role, discord_name, discord_username, discord_avatar)
  values (auth.uid(), 'pending', d.name, d.username, d.avatar) on conflict (user_id) do nothing;
  return jsonb_build_object('ok', true, 'role', 'pending');
end $$;

create or replace function public.staff_members() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not _is_staff() then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'role', role, 'name', discord_name,
            'username', discord_username, 'avatar', discord_avatar, 'at', _ms(created_at))
            order by case role when 'owner' then 0 when 'staff' then 1 else 2 end, created_at), '[]')
          from staff where role <> 'pending' or _my_role() = 'owner');
end $$;

-- 진행자만: 승인 / 거절 / 운영진에서 빼기
create or replace function public.staff_decide(p_user uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if _my_role() is distinct from 'owner' then return jsonb_build_object('ok', false, 'reason', '진행자만 할 수 있어요.'); end if;
  if p_action = 'approve' then
    update staff set role = 'staff', approved_at = now() where user_id = p_user and role = 'pending';
  elsif p_action in ('reject', 'remove') then
    delete from staff where user_id = p_user and role <> 'owner';
  else return jsonb_build_object('ok', false, 'reason', '알 수 없는 조작이에요.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_invite(p_reset boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if _my_role() is distinct from 'owner' then return null; end if;
  if p_reset then update site_settings set invite_code = replace(gen_random_uuid()::text, '-', '') where id = 1; end if;
  return jsonb_build_object('code', (select invite_code from site_settings where id = 1));
end $$;

-- 회차 목록
create or replace function public.list_events() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not _is_staff() then return null; end if;
  return (select coalesce(jsonb_agg(e order by (e ->> 'sort')::bigint desc), '[]') from (
    select jsonb_build_object('id', a.id, 'title', a.title, 'status', a.status, 'open', _signup_open(a),
      'signup_mode', a.signup_mode, 'opens_at', _ms(a.signup_opens_at), 'closes_at', _ms(a.signup_closes_at),
      'auction_at', _ms(a.auction_at), 'match_at', _ms(a.match_at), 'created_at', _ms(a.created_at),
      'sort', _ms(coalesce(a.auction_at, a.created_at)),
      'signups', (select count(*) from signups s where s.auction_id = a.id),
      'captains', (select count(*) from signups s where s.auction_id = a.id and s.captain),
      'team_count', (a.config ->> 'teamCount')::int,
      'tasks_open', (select count(*) from tasks t where t.auction_id = a.id and not t.done)) e
    from auctions a) x);
end $$;

-- 새 회차 만들기 (선수는 아직 없음 — 신청 명단으로 채움)
create or replace function public.create_event(p_title text, p_config jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; i int; d record;
begin
  if not _is_staff() then return _no(); end if;
  if coalesce((p_config ->> 'teamCount')::int, 0) not between 2 and 8 then return jsonb_build_object('ok', false, 'reason', '팀 수 설정이 잘못됐어요.'); end if;
  select * into d from _discord_of(auth.uid());
  insert into auctions (config, title, signup_mode) values (p_config, left(coalesce(trim(p_title), ''), 60), 'closed') returning id into v_id;
  insert into auction_keys (key, auction_id, role) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'host');
  for i in 0 .. (p_config ->> 'teamCount')::int - 1 loop
    insert into auction_keys (key, auction_id, role, team_idx) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'team', i);
  end loop;
  perform _log(v_id, '', format('%s 님이 회차를 만들었습니다.', d.name));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 회차 이름·일정·신청 마감 바꾸기
create or replace function public.update_event(p_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_staff() then return _no(); end if;
  if p_patch ? 'signup_mode' and not (p_patch ->> 'signup_mode' = any (array['auto', 'open', 'closed'])) then
    return jsonb_build_object('ok', false, 'reason', '신청 상태 값이 잘못됐어요.');
  end if;
  update auctions set
    title            = case when p_patch ? 'title' then left(coalesce(trim(p_patch ->> 'title'), ''), 60) else title end,
    signup_opens_at  = case when p_patch ? 'opens_at' then (p_patch ->> 'opens_at')::timestamptz else signup_opens_at end,
    signup_closes_at = case when p_patch ? 'closes_at' then (p_patch ->> 'closes_at')::timestamptz else signup_closes_at end,
    auction_at       = case when p_patch ? 'auction_at' then (p_patch ->> 'auction_at')::timestamptz else auction_at end,
    match_at         = case when p_patch ? 'match_at' then (p_patch ->> 'match_at')::timestamptz else match_at end,
    signup_mode      = case when p_patch ? 'signup_mode' then p_patch ->> 'signup_mode' else signup_mode end
  where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'reason', '회차를 찾지 못했어요.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 회차 한 개의 모든 정보 (명단, 검수, 메모, 할 일, 링크)
create or replace function public.event_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a auctions;
begin
  if not _is_staff() then return null; end if;
  select * into a from auctions where id = p_id;
  if a.id is null then return null; end if;
  return jsonb_build_object(
    'event', jsonb_build_object('id', a.id, 'title', a.title, 'status', a.status, 'open', _signup_open(a),
      'signup_mode', a.signup_mode, 'opens_at', _ms(a.signup_opens_at), 'closes_at', _ms(a.signup_closes_at),
      'auction_at', _ms(a.auction_at), 'match_at', _ms(a.match_at), 'created_at', _ms(a.created_at),
      'signup_code', a.signup_code, 'team_count', (a.config ->> 'teamCount')::int),
    'signups', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'user_id', s.user_id,
        'discord_name', s.discord_name, 'discord_username', s.discord_username, 'discord_avatar', s.discord_avatar,
        'nick', s.nick, 'peak', s.peak, 'current', s.current_tier, 'pos', s.pos, 'captain', s.captain, 'memo', s.memo,
        'at', _ms(s.created_at), 'updated_by', s.updated_by, 'updated_at', _ms(s.updated_at),
        'checks', (select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'user_id', c.user_id, 'name', c.staff_name) order by c.at), '[]')
                   from signup_checks c where c.signup_id = s.id)) order by s.id), '[]')
      from signups s where s.auction_id = a.id),
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'assignee', t.assignee,
        'due_at', _ms(t.due_at), 'done', t.done, 'created_by', t.created_by) order by t.done, t.due_at nulls last, t.id), '[]')
      from tasks t where t.auction_id = a.id),
    'links', case when _my_role() = 'owner' then jsonb_build_object(
        'host_key', (select key from auction_keys where auction_id = a.id and role = 'host'),
        'team_keys', (select jsonb_agg(key order by team_idx) from auction_keys where auction_id = a.id and role = 'team')) end);
end $$;

-- 신청 고치기: 닉네임·티어·포지션·메모·팀장. 티어를 고치면 그 사람의 검수는 처음부터 다시
create or replace function public.signup_update(p_signup bigint, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s signups; d record; v_peak text; v_cur text; v_teams int;
begin
  if not _is_staff() then return _no(); end if;
  select * into s from signups where id = p_signup for update;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', '신청을 찾지 못했어요.'); end if;
  v_peak := coalesce(p_patch ->> 'peak', s.peak);
  v_cur := coalesce(p_patch ->> 'current', s.current_tier);
  if not _valid_tier(v_peak) or not _valid_tier(v_cur) then return jsonb_build_object('ok', false, 'reason', '티어 이름이 잘못됐어요.'); end if;
  if p_patch ? 'pos' and not _valid_pos(p_patch ->> 'pos') then return jsonb_build_object('ok', false, 'reason', '포지션이 잘못됐어요.'); end if;
  if p_patch ? 'nick' and coalesce(trim(p_patch ->> 'nick'), '') = '' then return jsonb_build_object('ok', false, 'reason', '닉네임이 비어 있어요.'); end if;
  if coalesce((p_patch ->> 'captain')::boolean, false) and not s.captain then
    select (config ->> 'teamCount')::int into v_teams from auctions where id = s.auction_id;
    if (select count(*) from signups where auction_id = s.auction_id and captain) >= v_teams then
      return jsonb_build_object('ok', false, 'reason', format('팀장은 %s명까지예요. 다른 팀장을 먼저 빼 주세요.', v_teams));
    end if;
  end if;
  select * into d from _discord_of(auth.uid());
  if v_peak <> s.peak or v_cur <> s.current_tier then delete from signup_checks where signup_id = s.id; end if;
  update signups set
    nick         = case when p_patch ? 'nick' then left(trim(p_patch ->> 'nick'), 16) else nick end,
    peak         = v_peak, current_tier = v_cur,
    pos          = coalesce(p_patch ->> 'pos', pos),
    memo         = case when p_patch ? 'memo' then left(coalesce(p_patch ->> 'memo', ''), 200) else memo end,
    captain      = coalesce((p_patch ->> 'captain')::boolean, captain),
    updated_at   = now(), updated_by = d.name
  where id = s.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.signup_delete(p_signup bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_staff() then return _no(); end if;
  delete from signups where id = p_signup;
  return jsonb_build_object('ok', true);
end $$;

-- 교차검수 표시 켜기/끄기 (내 이름으로)
create or replace function public.signup_check(p_signup bigint, p_kind text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if not _is_staff() then return _no(); end if;
  if p_kind not in ('tier', 'score') then return jsonb_build_object('ok', false, 'reason', '검수 종류가 잘못됐어요.'); end if;
  if not exists (select 1 from signups where id = p_signup) then return jsonb_build_object('ok', false, 'reason', '신청을 찾지 못했어요.'); end if;
  if p_on then
    select * into d from _discord_of(auth.uid());
    insert into signup_checks (signup_id, kind, user_id, staff_name) values (p_signup, p_kind, auth.uid(), d.name)
    on conflict do nothing;
  else
    delete from signup_checks where signup_id = p_signup and kind = p_kind and user_id = auth.uid();
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 할 일
create or replace function public.task_add(p_id uuid, p_title text, p_assignee uuid default null, p_due timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if not _is_staff() then return _no(); end if;
  if coalesce(trim(p_title), '') = '' then return jsonb_build_object('ok', false, 'reason', '할 일 내용을 적어 주세요.'); end if;
  select * into d from _discord_of(auth.uid());
  insert into tasks (auction_id, title, assignee, due_at, created_by) values (p_id, left(trim(p_title), 100), p_assignee, p_due, d.name);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.task_update(p_task bigint, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_staff() then return _no(); end if;
  update tasks set
    title    = case when p_patch ? 'title' and coalesce(trim(p_patch ->> 'title'), '') <> '' then left(trim(p_patch ->> 'title'), 100) else title end,
    assignee = case when p_patch ? 'assignee' then (p_patch ->> 'assignee')::uuid else assignee end,
    due_at   = case when p_patch ? 'due_at' then (p_patch ->> 'due_at')::timestamptz else due_at end,
    done     = coalesce((p_patch ->> 'done')::boolean, done),
    done_at  = case when (p_patch ->> 'done')::boolean then now() when p_patch ? 'done' then null else done_at end
  where id = p_task;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.task_delete(p_task bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_staff() then return _no(); end if;
  delete from tasks where id = p_task;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public._ms(timestamptz), public._signup_open(public.auctions), public._discord_of(uuid),
  public._my_role(), public._is_staff(), public._no() from public, anon, authenticated;
revoke execute on function public.my_role(), public.claim_owner(uuid, text), public.request_staff(text), public.staff_members(),
  public.staff_decide(uuid, text), public.get_invite(boolean), public.list_events(), public.create_event(text, jsonb),
  public.update_event(uuid, jsonb), public.event_detail(uuid), public.signup_update(bigint, jsonb), public.signup_delete(bigint),
  public.signup_check(bigint, text, boolean), public.task_add(uuid, text, uuid, timestamptz), public.task_update(bigint, jsonb),
  public.task_delete(bigint) from public;
grant execute on function public.my_role(), public.claim_owner(uuid, text), public.request_staff(text), public.staff_members(),
  public.staff_decide(uuid, text), public.get_invite(boolean), public.list_events(), public.create_event(text, jsonb),
  public.update_event(uuid, jsonb), public.event_detail(uuid), public.signup_update(bigint, jsonb), public.signup_delete(bigint),
  public.signup_check(bigint, text, boolean), public.task_add(uuid, text, uuid, timestamptz), public.task_update(bigint, jsonb),
  public.task_delete(bigint) to anon, authenticated;
