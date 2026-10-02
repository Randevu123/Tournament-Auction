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
  role       text not null,          -- host / team / screen(방송 화면: 보기만)
  team_idx   int
);
-- 7단계 전에 만든 회차에도 방송 화면 열쇠를 하나씩 만들어 둠
insert into public.auction_keys (key, auction_id, role)
  select replace(gen_random_uuid()::text, '-', ''), a.id, 'screen' from public.auctions a
  where not exists (select 1 from public.auction_keys k where k.auction_id = a.id and k.role = 'screen');

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
alter table public.chat add column if not exists hidden boolean not null default false;   -- 진행자가 방송 화면에서 숨긴 메시지

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

-- 운영자 콘솔: 운영자 명단, 회차 일정, 신청 마감, 검수, 할 일
create table if not exists public.staff (
  user_id          uuid primary key,        -- 디스코드로 로그인한 계정
  role             text not null check (role in ('owner', 'staff', 'pending')),   -- 진행자 / 운영자 / 승인 대기
  discord_name     text not null default '',
  discord_username text not null default '',
  discord_avatar   text not null default '',
  created_at       timestamptz not null default now(),
  approved_at      timestamptz
);
create unique index if not exists staff_one_owner on public.staff (role) where role = 'owner';

create table if not exists public.site_settings (
  id          int primary key default 1 check (id = 1),
  invite_code text not null default replace(gen_random_uuid()::text, '-', '')   -- 운영자 초대 링크 코드
);
insert into public.site_settings (id) values (1) on conflict do nothing;
alter table public.site_settings add column if not exists last_ping timestamptz;   -- 운영자 콘솔을 열 때마다 기록 (무료 요금제 7일 정지 방지)
alter table public.site_settings add column if not exists last_auto_ping timestamptz;  -- GitHub 자동 깨우기가 마지막으로 온 시각

alter table public.auctions add column if not exists title            text not null default '';
alter table public.auctions add column if not exists signup_opens_at  timestamptz;
alter table public.auctions add column if not exists signup_closes_at timestamptz;
alter table public.auctions add column if not exists signup_mode      text not null default 'auto';  -- auto(일정대로) / open / closed
alter table public.auctions add column if not exists auction_at       timestamptz;
alter table public.auctions add column if not exists match_at         timestamptz;
alter table public.auctions add column if not exists host_user        uuid;          -- 이 회차의 진행자 (운영자 중 한 명, 넘길 수 있음)
alter table public.auctions add column if not exists unlocked         boolean not null default false;  -- 지난 회차 잠금을 제작자가 풀었는지

alter table public.signups add column if not exists captain    boolean not null default false;  -- 팀장 배정
alter table public.signups add column if not exists score_override numeric(5,1);                 -- 운영자가 직접 정한 티어 점수 (비우면 자동 계산)
alter table public.players add column if not exists signup_id bigint;                            -- 신청 명단에서 온 선수면 그 신청 번호
alter table public.players add column if not exists score_override numeric(5,1);
alter table public.teams   add column if not exists handicap int not null default 0;
alter table public.signups add column if not exists agents text[] not null default '{}';          -- 주 요원 (최대 3개, 고른 순서대로)
alter table public.players add column if not exists agents text[] not null default '{}';
-- 경매 티어 A/B/C/D (팀마다 한 명씩). 게임 랭크 티어와 다른 것. 5명 단위로 못 들어간 신청자는 대기(대타)
alter table public.signups add column if not exists grade text check (grade in ('A', 'B', 'C', 'D'));
alter table public.signups add column if not exists bench boolean not null default false;
alter table public.players add column if not exists grade text check (grade in ('A', 'B', 'C', 'D'));
alter table public.auctions add column if not exists chat_epoch int not null default 0;   -- 채팅을 비울 때마다 1씩 늘어남 (화면들이 보고 채팅 창을 비움)
alter table public.auctions add column if not exists undo jsonb;                         -- 결과 되돌리기용: 결과마다 그 직전 상태 (최근 30개, 쌓임)
update public.auctions set undo = jsonb_build_array(undo) where jsonb_typeof(undo) = 'object';   -- 예전(하나만) 형식을 목록으로
alter table public.signups add column if not exists motto text not null default '';       -- 신청할 때 적는 각오 한마디
alter table public.signups add column if not exists consented_at timestamptz;
alter table public.staff add column if not exists all_host boolean not null default false;
alter table public.signups add column if not exists photo text not null default '';          -- 디스코드 사진 대신 본인이 올린 사진 (작게 줄인 이미지)   -- 모든 회차에서 진행 권한 (제작자가 지정)              -- 개인정보 안내에 동의한 시각
alter table public.signups add column if not exists show_avatar boolean not null default false;  -- 경매·방송 화면에 디스코드 프로필 사진을 써도 되는지 (본인이 고름)             -- 시작 포인트에서 깎는 핸디캡
alter table public.signups add column if not exists memo       text not null default '';        -- 운영자끼리만 보는 메모
alter table public.signups add column if not exists updated_at timestamptz;
alter table public.signups add column if not exists updated_by text not null default '';

create table if not exists public.signup_checks (          -- 교차검수: 서로 다른 운영자 2명이 확인하면 확정
  signup_id  bigint not null references public.signups on delete cascade,
  kind       text not null check (kind in ('tier', 'score')),   -- 티어 확인 / 티어 점수 계산 재확인
  user_id    uuid not null,
  staff_name text not null default '',
  at         timestamptz not null default now(),
  primary key (signup_id, kind, user_id)
);

create table if not exists public.tasks (                  -- 회차별 운영자 할 일
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

create table if not exists public.staff_log (             -- 진행 기록: 누가 언제 무엇을 고쳤는지
  id         bigserial primary key,
  auction_id uuid references public.auctions on delete cascade,   -- 비어 있으면 사이트 전체 일(운영자 승인 등)
  user_id    uuid,
  who        text not null default '',
  action     text not null,
  detail     text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists staff_log_auction_idx on public.staff_log (auction_id, id desc);
alter table public.staff_log add column if not exists event_title text not null default '';   -- 회차가 지워져도 기록에 이름이 남도록
-- 회차를 지워도 진행 기록은 남김 (회차 칸만 비움)
alter table public.staff_log drop constraint if exists staff_log_auction_id_fkey;
alter table public.staff_log add constraint staff_log_auction_id_fkey foreign key (auction_id) references public.auctions on delete set null;
alter table public.staff_log     enable row level security;
revoke all on public.staff_log from anon, authenticated;

alter table public.staff         enable row level security;
alter table public.site_settings enable row level security;
alter table public.signup_checks enable row level security;
alter table public.tasks         enable row level security;
revoke all on public.staff, public.site_settings, public.signup_checks, public.tasks from anon, authenticated;

-- 시각을 화면용 숫자(밀리초)로
create or replace function public._ms(t timestamptz) returns bigint
language sql immutable as $$ select (extract(epoch from t) * 1000)::bigint $$;

-- 지난 회차(경매가 끝났거나 경기 일시가 지남)는 잠김. 제작자가 풀면(unlocked) 고칠 수 있음
create or replace function public._locked(a public.auctions) returns boolean
language sql stable as $$
  select not coalesce(a.unlocked, false) and (a.status = 'done' or (a.match_at is not null and a.match_at < now()))
$$;
create or replace function public._locked_id(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select _locked(a) from auctions a where a.id = p_id), false)
$$;
create or replace function public._lock_msg() returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'reason', '지난 회차라 잠겨 있어요. 고쳐야 하면 제작자가 ‘잠금 풀기’를 눌러 주세요.') $$;

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
    'teams', (select coalesce(jsonb_agg(jsonb_build_object('idx', t.idx, 'name', t.name, 'color', t.color, 'points', t.points, 'handicap', t.handicap) order by t.idx), '[]')
              from teams t where t.auction_id = a.id),
    'players', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', p.id, 'name', p.name, 'peak', p.peak, 'current', p.current_tier, 'pos', p.pos,
                  'captain', p.captain, 'motto', p.motto, 'unsold', p.unsold, 'agents', to_jsonb(p.agents), 'grade', p.grade,
                  'team', p.team_idx, 'price', p.price, 'how', p.how, 'score', p.score_override, 'signup_id', p.signup_id,
                  'discord', (select s.discord_name from signups s where s.id = p.signup_id),
                  'dc_avatar', (select s.discord_avatar from signups s where s.id = p.signup_id and s.show_avatar)) order by p.id), '[]')
                from players p where p.auction_id = a.id),
    'title', a.title, 'locked', _locked(a),
    'chat_epoch', a.chat_epoch,
    'undo_count', case when jsonb_typeof(a.undo) = 'array' then jsonb_array_length(a.undo) else 0 end,
    'undo_player', case when jsonb_typeof(a.undo) = 'array' then (a.undo -> -1 ->> 'player')::int end,
    'can_undo', (jsonb_typeof(a.undo) = 'array' and jsonb_array_length(a.undo) > 0 and a.status <> 'setup'),
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
  insert into players (auction_id, id, name, peak, current_tier, pos, captain, motto, photo, signup_id, score_override, agents, grade)
  select p_id, (e.ordinality - 1)::int,
         left(trim(e.value ->> 'name'), 16), e.value ->> 'peak', e.value ->> 'current', coalesce(_norm_pos(e.value ->> 'pos'), '타격대'),
         coalesce((e.value ->> 'captain')::boolean, false),
         left(coalesce(trim(e.value ->> 'motto'), ''), 60),
         case when coalesce(e.value ->> 'photo', '') like 'data:image/%' and length(e.value ->> 'photo') <= 400000
              then e.value ->> 'photo' else '' end,
         (select id from signups where id = (e.value ->> 'signup_id')::bigint and auction_id = p_id),   -- 신청 명단과의 연결 유지
         case when (e.value ->> 'score') ~ '^[0-9]+(\.[0-9]+)?$' then round(least((e.value ->> 'score')::numeric, 1000), 1) end,
         _clean_agents(e.value -> 'agents'),
         case when not coalesce((e.value ->> 'captain')::boolean, false) and e.value ->> 'grade' in ('A', 'B', 'C', 'D') then e.value ->> 'grade' end
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

-- 되돌리기 목록에 직전 상태 하나 쌓기 (최근 30개만)
create or replace function public._push_undo(p_id uuid, p_snap jsonb) returns void
language sql security definer set search_path = public as $$
  update auctions set undo = (
    select coalesce(jsonb_agg(e order by o), '[]') from (
      select e, o from jsonb_array_elements(coalesce(case when jsonb_typeof(undo) = 'array' then undo end, '[]') || jsonb_build_array(p_snap))
             with ordinality x(e, o) order by o desc limit 30) y)
  where id = p_id
$$;

-- 한 선수의 경매를 마무리 (낙찰 / 유찰 / 무작위 배정)
create or replace function public._finish(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  a auctions; p players; t teams; v_team int; v_result jsonb;
begin
  select * into a from auctions where id = p_id;
  select * into p from players where auction_id = p_id and id = a.current_player;
  -- 되돌리기용: 이 선수를 다시 경매할 수 있게 직전 상태를 적어 둠
  perform _push_undo(p_id, jsonb_build_object('player', p.id, 'unsold', p.unsold, 'queue', to_jsonb(a.queue),
         'points', (select jsonb_object_agg(idx::text, points) from teams where auction_id = p_id)));
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
         and not (p.grade is not null and exists (select 1 from players q where q.auction_id = p_id and q.team_idx = tm.idx and q.grade = p.grade))
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
declare a auctions; v_open boolean; p players; v_cnt int; v_team int;
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
  -- 경매 티어의 마지막 선수처럼 받을 수 있는 팀이 한 팀뿐이면 경매 없이 0P로 자동 배정
  select * into p from players where auction_id = p_id and id = a.queue[1];
  if p.grade is not null then
    select count(*), min(tm.idx) into v_cnt, v_team from teams tm
     where tm.auction_id = p_id and _open_slots(p_id, tm.idx) > 0
       and not exists (select 1 from players q where q.auction_id = p_id and q.team_idx = tm.idx and q.grade = p.grade);
    if v_cnt = 1 then
      perform _push_undo(p_id, jsonb_build_object('player', p.id, 'unsold', p.unsold, 'queue', to_jsonb(a.queue[2:]),
             'points', (select jsonb_object_agg(idx::text, points) from teams where auction_id = p_id)));
      update players set team_idx = v_team, price = 0, how = 'auto' where auction_id = p_id and id = p.id;
      update auctions set current_player = p.id, queue = a.queue[2:], bid_amount = 0, bid_team = null, ends_at = null, paused_left_ms = null,
             status = 'result', next_at = clock_timestamp() + make_interval(secs => _cfg_int(a, 'resultShowMs') / 1000.0),
             last_result = jsonb_build_object('kind', 'auto', 'player', p.id, 'team', v_team, 'seq', a.version + 1)
       where id = p_id;
      perform _log(p_id, 'sold', format('%s → %s 자동 배정 (%s티어를 받을 수 있는 팀이 하나뿐, 0P)', p.name,
        (select name from teams where auction_id = p_id and idx = v_team), p.grade));
      return;
    end if;
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
    return jsonb_build_object('ok', false, 'reason', '제작자가 등록된 뒤에는 운영자 콘솔(admin.html)에서 회차를 만들어 주세요.');
  end if;
  v_err := _check_players(p_config, p_players);
  if v_err is not null then return jsonb_build_object('ok', false, 'reason', v_err); end if;
  insert into auctions (config) values (p_config) returning id into v_id;
  perform _load_players(v_id, p_players);
  v_host := replace(gen_random_uuid()::text, '-', '');
  insert into auction_keys (key, auction_id, role) values (v_host, v_id, 'host');
  insert into auction_keys (key, auction_id, role) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'screen');
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
    'signup_code', (select signup_code from auctions where id = p_id),
    'screen', (select key from auction_keys where auction_id = p_id and role = 'screen' limit 1));
end $$;

-- 방송 화면 열쇠로 볼 때는 디스코드 이름을 빼고 줌 (방송에 안 나가는 정보는 아예 안 보냄)
create or replace function public._state_for(p_id uuid, p_role text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := _state(p_id);
begin
  if p_role = 'screen' then
    v := jsonb_set(v, '{players}', (select coalesce(jsonb_agg(e - 'discord' order by o), '[]') from jsonb_array_elements(v -> 'players') with ordinality x(e, o)));
  end if;
  return v;
end $$;

create or replace function public.get_state(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := (select role from _auth(p_id, p_key));
begin
  if v_role is null then return null; end if;
  return _state_for(p_id, v_role);
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
  -- 채팅은 진행자와 팀장이 쓰고, 방송 화면은 읽기만 함 (보내기는 send_chat이 진행자·팀장만 허용)
  -- 진행자가 숨긴 메시지는 방송 화면에 내용을 보내지 않음 (진행자·팀장에게는 "숨김" 표시와 함께 보임)
  if (select role from _auth(p_id, p_key)) is null or (select role from _auth(p_id, p_key)) not in ('host', 'team', 'screen') then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'sender', c.sender, 'color', c.color, 'hidden', c.hidden,
            'body', case when c.hidden and (select role from _auth(p_id, p_key)) = 'screen' then '' else c.body end,
            'at', (extract(epoch from c.created_at) * 1000)::bigint) order by c.id), '[]')
          from (select * from chat where auction_id = p_id and id > coalesce(p_after, 0) order by id desc limit 100) c);
end $$;

create or replace function public.send_chat(p_id uuid, p_key text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; v_body text := left(trim(coalesce(p_body, '')), 200); v_name text; v_color text; v_row chat;
begin
  select * into w from _auth(p_id, p_key);
  if w.role is null or w.role not in ('host', 'team') then return jsonb_build_object('ok', false, 'reason', '링크가 올바르지 않아요.'); end if;
  if v_body = '' then return jsonb_build_object('ok', false, 'reason', '빈 메시지는 보낼 수 없어요.'); end if;
  if w.role = 'host' then v_name := '진행자'; v_color := '#ffffff';
  else select name, color into v_name, v_color from teams where auction_id = p_id and idx = w.team_idx; end if;
  insert into chat (auction_id, sender, color, body) values (p_id, v_name, v_color, v_body) returning * into v_row;
  return jsonb_build_object('ok', true, 'msg', jsonb_build_object('id', v_row.id, 'sender', v_row.sender, 'color', v_row.color, 'hidden', false,
           'body', v_row.body, 'at', (extract(epoch from v_row.created_at) * 1000)::bigint));
end $$;

-- 채팅 비우기 (진행자 화면 링크만): 이 경매의 채팅을 모두 지움. 팀장·방송 화면은 chat_epoch가 바뀐 걸 보고 채팅 창을 비움
create or replace function public.clear_chat(p_id uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return jsonb_build_object('ok', false, 'reason', '진행자만 채팅을 비울 수 있어요.'); end if;
  delete from chat where auction_id = p_id;
  get diagnostics v_n = row_count;
  update auctions set chat_epoch = chat_epoch + 1 where id = p_id;
  perform _log(p_id, '', format('채팅을 비웠습니다 (메시지 %s개)', v_n));
  perform _bump(p_id);
  return jsonb_build_object('ok', true, 'cleared', v_n, 'state', _state(p_id));
end $$;

-- 채팅 메시지를 방송 화면에서 숨기기 / 다시 보이기 (진행자만)
create or replace function public.hide_chat(p_id uuid, p_key text, p_msg bigint, p_hidden boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row chat;
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return jsonb_build_object('ok', false, 'reason', '진행자만 채팅을 숨길 수 있어요.'); end if;
  update chat set hidden = coalesce(p_hidden, true) where auction_id = p_id and id = p_msg returning * into v_row;
  if v_row.id is null then return jsonb_build_object('ok', false, 'reason', '메시지를 찾지 못했어요.'); end if;
  return jsonb_build_object('ok', true, 'msg', jsonb_build_object('id', v_row.id, 'sender', v_row.sender, 'color', v_row.color, 'hidden', v_row.hidden,
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
  elsif exists (select 1 from players q join players c on c.auction_id = q.auction_id and c.id = a.current_player
                where q.auction_id = p_id and q.team_idx = t.idx and c.grade is not null and q.grade = c.grade) then
    v_reason := format('이미 우리 팀에 %s티어 선수가 있어요.', (select grade from players where auction_id = p_id and id = a.current_player));
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
declare a auctions; v_now timestamptz; v_changed boolean := false; v_role text := (select role from _auth(p_id, p_key));
begin
  if v_role is null then return jsonb_build_object('ok', false, 'reason', '링크가 올바르지 않아요.'); end if;
  select * into a from auctions where id = p_id for update;
  v_now := clock_timestamp();
  if a.status = 'running' and v_now >= a.ends_at then
    perform _finish(p_id); v_changed := true;
  elsif a.status = 'result' and v_now >= a.next_at then
    perform _next(p_id); v_changed := true;
  end if;
  if v_changed then perform _bump(p_id); end if;
  return jsonb_build_object('ok', true, 'changed', v_changed, 'state', _state_for(p_id, v_role));
end $$;

-- 진행자 조작: set_players / set_order / start / pause / resume / hammer / next / auto / reset
create or replace function public.host_action(p_id uuid, p_key text, p_action text, p_arg jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; v_reason text; v_ids int[]; v_pool int[]; v_left numeric; v_n int; v_cfg jsonb; r record; i int; v_team int; v_amt int; v_score numeric;
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then
    return jsonb_build_object('ok', false, 'reason', '진행자 링크가 아니에요.');
  end if;
  select * into a from auctions where id = p_id for update;
  if _locked(a) and p_action in ('set_players', 'set_order', 'reset', 'load_signups', 'set_config', 'set_handicap', 'set_player', 'undo') then
    return _lock_msg() || jsonb_build_object('state', _state(p_id));
  end if;

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

  -- 4단계: 신청 명단으로 선수 채우기. arg = {captains: [신청 번호, 팀 순서대로], exclude: [뺄 신청 번호], handicaps: {"신청 번호": 깎을 포인트}}
  elsif p_action = 'load_signups' then
    v_n := coalesce(jsonb_array_length(p_arg -> 'captains'), 0);
    if a.status <> 'setup' then v_reason := '경매 준비 단계에서만 명단을 채울 수 있어요.';
    elsif v_n < 1 or v_n > 8 then v_reason := '팀장은 1명에서 8명 사이로 골라 주세요.';
    elsif exists (select 1 from jsonb_array_elements_text(p_arg -> 'captains') c(x)
                  where not exists (select 1 from signups s where s.id = c.x::bigint and s.auction_id = p_id)) then
      v_reason := '이 회차의 신청자만 팀장으로 고를 수 있어요.';
    elsif (select count(distinct x) from jsonb_array_elements_text(p_arg -> 'captains') c(x)) <> v_n then
      v_reason := '같은 사람을 팀장으로 두 번 고를 수 없어요.';
    elsif exists (select 1 from jsonb_each_text(coalesce(p_arg -> 'handicaps', '{}')) h(k, v)
                  where v::numeric < 0 or v::numeric >= _cfg_int(a, 'startPoints')) then
      v_reason := '핸디캡은 0 이상, 시작 포인트보다 작아야 해요.';
    elsif exists (select 1 from jsonb_each_text(coalesce(p_arg -> 'grades', '{}')) g(k, v) where v not in ('A', 'B', 'C', 'D', '')) then
      v_reason := '경매 티어는 A, B, C, D 중 하나예요.';
    else
     -- 티어 저장과 검사를 한 블록에서: 검사에 걸리면 이 블록의 저장도 되돌림 (거절됐는데 티어만 바뀌는 일이 없게)
     begin
      -- 경매 티어: 새로 정한 값을 신청 명단에 저장 (대기 인원 포함)
      update signups s set grade = nullif(g.v, '') from jsonb_each_text(coalesce(p_arg -> 'grades', '{}')) g(k, v)
       where s.auction_id = p_id and s.id = g.k::bigint;
      -- 티어를 쓰면: 팀장 빼고 모두 티어가 있고, A·B·C·D가 팀 수만큼씩 있어야 함
      select count(*) filter (where s.grade is not null) graded, count(*) total,
             count(*) filter (where s.grade = 'A') na, count(*) filter (where s.grade = 'B') nb,
             count(*) filter (where s.grade = 'C') nc, count(*) filter (where s.grade = 'D') nd
        into r from signups s
       where s.auction_id = p_id and not (s.id::text in (select jsonb_array_elements_text(p_arg -> 'captains')))
         and not (s.id::text in (select jsonb_array_elements_text(coalesce(p_arg -> 'exclude', '[]'))));
      if r.graded > 0 and (r.graded <> r.total or r.na <> v_n or r.nb <> v_n or r.nc <> v_n or r.nd <> v_n or _cfg_int(a, 'teamSize') <> 5) then
        v_reason := case when _cfg_int(a, 'teamSize') <> 5 then '경매 티어(A~D)를 쓰려면 팀 인원이 5명(팀장 포함)이어야 해요.'
          when r.graded <> r.total then format('경매 선수 중 %s명이 경매 티어가 없어요.', r.total - r.graded)
          else format('경매 티어는 팀 수(%s)만큼씩 있어야 해요. 지금 A %s · B %s · C %s · D %s명', v_n, r.na, r.nb, r.nc, r.nd) end;
        raise exception using errcode = 'P0A01', message = v_reason;
      end if;
     exception when sqlstate 'P0A01' then v_reason := sqlerrm;   -- 위 저장을 되돌리고 거절 이유만 남김
     end;
    end if;
    if v_reason is null and p_action = 'load_signups' and a.status = 'setup' then
      update signups set bench = (id::text in (select jsonb_array_elements_text(coalesce(p_arg -> 'exclude', '[]')))) where auction_id = p_id;
      delete from players where auction_id = p_id;
      delete from teams where auction_id = p_id;
      -- 팀 수 = 팀장 수. 팀장 링크(열쇠)도 그 수만큼 맞춤 (있던 링크는 그대로 씀)
      for i in 0 .. v_n - 1 loop
        if not exists (select 1 from auction_keys where auction_id = p_id and role = 'team' and team_idx = i) then
          insert into auction_keys (key, auction_id, role, team_idx) values (replace(gen_random_uuid()::text, '-', ''), p_id, 'team', i);
        end if;
      end loop;
      delete from auction_keys where auction_id = p_id and role = 'team' and team_idx >= v_n;
      update auctions set config = jsonb_set(config, '{teamCount}', to_jsonb(v_n)) where id = p_id;
      select * into a from auctions where id = p_id;
      -- 선수 번호는 0부터: 팀장 먼저, 그다음 나머지 신청자(신청 순서)
      i := 0;
      for r in select s.*, c.ord from signups s
               left join jsonb_array_elements_text(p_arg -> 'captains') with ordinality c(x, ord) on c.x::bigint = s.id
               where s.auction_id = p_id
                 and (c.x is not null or not (s.id::text in (select jsonb_array_elements_text(coalesce(p_arg -> 'exclude', '[]')))))
               order by c.ord nulls last, s.id loop
        insert into players (auction_id, id, name, peak, current_tier, pos, captain, motto, photo, signup_id, score_override, agents, grade)
        values (p_id, i, r.nick, r.peak, r.current_tier, r.pos, r.ord is not null, r.motto, r.photo, r.id, r.score_override, r.agents,
                case when r.ord is null then r.grade end);
        if r.ord is not null then
          v_amt := coalesce((p_arg #>> array['handicaps', r.id::text])::numeric, 0)::int;
          insert into teams (auction_id, idx, name, color, points, handicap)
          values (p_id, (r.ord - 1)::int, r.nick || ' 팀',
                  coalesce(a.config -> 'teamColors' ->> (((r.ord - 1)::int) % greatest(jsonb_array_length(a.config -> 'teamColors'), 1)), '#ff4655'),
                  _cfg_int(a, 'startPoints') - v_amt, v_amt);
          update players set team_idx = (r.ord - 1)::int, price = 0, how = 'captain' where auction_id = p_id and id = i;
        end if;
        i := i + 1;
      end loop;
      update signups set captain = (id::text in (select jsonb_array_elements_text(p_arg -> 'captains'))) where auction_id = p_id;
      update auctions set queue = (select coalesce(array_agg(id order by id), '{}') from players where auction_id = p_id and not captain),
             players_version = players_version + 1 where id = p_id;
      perform _log(p_id, '', format('신청 명단으로 선수를 채웠습니다 — 팀장 %s명, 경매 선수 %s명', v_n, i - v_n));
    end if;

  -- 경매 설정 바꾸기. 규칙 숫자는 준비 단계에서만, 점수표·비율은 언제든
  elsif p_action = 'set_config' then
    v_cfg := a.config || jsonb_strip_nulls(jsonb_build_object(
      'startSeconds', case when p_arg ? 'startSeconds' then (p_arg ->> 'startSeconds')::int end,
      'bidAddSeconds', case when p_arg ? 'bidAddSeconds' then (p_arg ->> 'bidAddSeconds')::int end,
      'maxSeconds', case when p_arg ? 'maxSeconds' then (p_arg ->> 'maxSeconds')::int end));
    if (v_cfg ->> 'startSeconds')::int not between 3 and 120 or (v_cfg ->> 'maxSeconds')::int not between 3 and 120
       or (v_cfg ->> 'bidAddSeconds')::int not between 1 and 60 then
      v_reason := '시간은 처음 시간·최대 시간 3~120초, 입찰마다 늘어나는 시간 1~60초로 정해 주세요.';
    elsif (v_cfg ->> 'startSeconds')::int > (v_cfg ->> 'maxSeconds')::int then
      v_reason := '처음 시간은 최대 시간보다 길 수 없어요.';
    elsif (p_arg ?| array['startPoints', 'bidStep', 'teamSize', 'reservePerSlot']) and a.status <> 'setup' then
      v_reason := '시작 포인트·입찰 단위·팀 인원은 경매 시작 전에만 바꿀 수 있어요.';
    elsif p_arg ? 'startPoints' and not ((p_arg ->> 'startPoints')::numeric between 10 and 100000) then v_reason := '시작 포인트는 10에서 100000 사이로 정해 주세요.';
    elsif p_arg ? 'startPoints' and (p_arg ->> 'startPoints')::numeric <= coalesce((select max(handicap) from teams where auction_id = p_id), 0) then
      v_reason := '시작 포인트가 가장 큰 핸디캡보다 커야 해요.';
    elsif p_arg ? 'bidStep' and not ((p_arg ->> 'bidStep')::numeric between 1 and 1000) then v_reason := '입찰 단위는 1에서 1000 사이로 정해 주세요.';
    elsif p_arg ? 'teamSize' and not ((p_arg ->> 'teamSize')::numeric between 1 and 12) then v_reason := '팀 인원은 1명에서 12명 사이로 정해 주세요.';
    elsif p_arg ? 'reservePerSlot' and not ((p_arg ->> 'reservePerSlot')::numeric between 0 and 1000) then v_reason := '빈자리 몫은 0에서 1000 사이로 정해 주세요.';
    elsif p_arg ? 'peakWeight' and not ((p_arg ->> 'peakWeight')::numeric between 0 and 1) then v_reason := '최고 티어 비율은 0%에서 100% 사이로 정해 주세요.';
    elsif p_arg ? 'tierScores' and (jsonb_typeof(p_arg -> 'tierScores') <> 'object'
          or exists (select 1 from jsonb_each(p_arg -> 'tierScores') t(k, v) where not _valid_tier(k) or jsonb_typeof(v) <> 'number' or v::numeric < 0 or v::numeric > 1000)) then
      v_reason := '점수표에 잘못된 값이 있어요. (0에서 1000 사이 숫자)';
    else
      for r in select key, value from jsonb_each(p_arg) where key in ('startPoints', 'bidStep', 'teamSize', 'reservePerSlot') loop
        v_cfg := jsonb_set(v_cfg, array[r.key], to_jsonb((r.value #>> '{}')::int));
      end loop;
      if p_arg ? 'peakWeight' then v_cfg := jsonb_set(v_cfg, '{peakWeight}', to_jsonb(round((p_arg ->> 'peakWeight')::numeric, 2))); end if;
      if p_arg ? 'tierScores' then v_cfg := jsonb_set(v_cfg, '{tierScores}', p_arg -> 'tierScores'); end if;
      update auctions set config = v_cfg where id = p_id;
      if a.status = 'setup' then update teams set points = (v_cfg ->> 'startPoints')::int - handicap where auction_id = p_id; end if;
      perform _log(p_id, '', '경매 설정을 바꿨습니다.');
    end if;

  -- 팀장 핸디캡 (시작 포인트에서 깎을 만큼). arg = {team: 팀 번호, amount: 포인트}
  elsif p_action = 'set_handicap' then
    v_team := (p_arg ->> 'team')::int; v_amt := coalesce((p_arg ->> 'amount')::numeric, 0)::int;
    if a.status <> 'setup' then v_reason := '핸디캡은 경매 시작 전에만 바꿀 수 있어요.';
    elsif not exists (select 1 from teams where auction_id = p_id and idx = v_team) then v_reason := '팀을 찾지 못했어요.';
    elsif v_amt < 0 or v_amt >= _cfg_int(a, 'startPoints') then v_reason := '핸디캡은 0 이상, 시작 포인트보다 작아야 해요.';
    else
      update teams set handicap = v_amt, points = _cfg_int(a, 'startPoints') - v_amt where auction_id = p_id and idx = v_team;
      perform _log(p_id, '', format('%s 핸디캡 %sP', (select name from teams where auction_id = p_id and idx = v_team), v_amt));
    end if;

  -- 선수 티어·점수 직접 고치기 (경매 중에도 가능). arg = {id, peak, current, score: 숫자 또는 null(자동 계산)}
  elsif p_action = 'set_player' then
    select * into r from players where auction_id = p_id and id = (p_arg ->> 'id')::int;
    v_score := case when p_arg ? 'score' then (p_arg ->> 'score')::numeric end;
    if r.id is null then v_reason := '선수를 찾지 못했어요.';
    elsif p_arg ? 'peak' and not _valid_tier(p_arg ->> 'peak') then v_reason := '최고 티어 이름이 잘못됐어요.';
    elsif p_arg ? 'current' and not _valid_tier(p_arg ->> 'current') then v_reason := '현재 티어 이름이 잘못됐어요.';
    elsif v_score is not null and (v_score < 0 or v_score > 1000) then v_reason := '점수는 0에서 1000 사이로 적어 주세요.';
    else
      update players set peak = coalesce(p_arg ->> 'peak', peak), current_tier = coalesce(p_arg ->> 'current', current_tier),
             score_override = case when p_arg ? 'score' then round(v_score, 1) else score_override end
       where auction_id = p_id and id = r.id;
      -- 신청 명단에서 온 선수면 신청 명단(운영자 콘솔)에도 같이 반영
      if r.signup_id is not null then
        update signups set peak = coalesce(p_arg ->> 'peak', peak), current_tier = coalesce(p_arg ->> 'current', current_tier),
               score_override = case when p_arg ? 'score' then round(v_score, 1) else score_override end,
               updated_at = now(), updated_by = '진행자 화면'
         where id = r.signup_id;
      end if;
      perform _log(p_id, '', format('%s 점수·티어를 고쳤습니다.', r.name));
    end if;

  -- 결과 되돌리기: 가장 최근 결과부터 하나씩, 그 선수를 다시 경매에 올림.
  -- 지금 선수가 경매 중(입찰이 있어도)이면 그 선수의 입찰은 취소되고 대기 순서 맨 앞으로 돌아감 (포인트는 낙찰 때만 빠지므로 돌려줄 것 없음)
  elsif p_action = 'undo' then
    if jsonb_typeof(a.undo) is distinct from 'array' or jsonb_array_length(a.undo) = 0 then
      v_reason := '되돌릴 결과가 없어요.';
    elsif a.status not in ('result', 'ready', 'running', 'paused', 'done') then
      v_reason := '지금은 되돌릴 수 없어요.';
    else
      v_cfg := a.undo -> -1;   -- 가장 최근 결과의 직전 상태
      select * into r from players where auction_id = p_id and id = (v_cfg ->> 'player')::int;
      update players set team_idx = null, price = null, how = null, unsold = (v_cfg ->> 'unsold')::int
       where auction_id = p_id and id = r.id;
      update teams t set points = (v_cfg -> 'points' ->> t.idx::text)::int where t.auction_id = p_id and v_cfg -> 'points' ? t.idx::text;
      update auctions set queue = array(select x::int from jsonb_array_elements_text(v_cfg -> 'queue') x),
             current_player = r.id, status = 'ready', bid_amount = 0, bid_team = null, ends_at = null, next_at = null,
             paused_left_ms = null, last_result = null, undo = a.undo - (jsonb_array_length(a.undo) - 1)
       where id = p_id;
      perform _log(p_id, '', format('되돌리기 — %s 결과를 취소하고 다시 경매합니다. (더 되돌릴 수 있는 결과 %s개)', r.name, jsonb_array_length(a.undo) - 1));
    end if;

  elsif p_action = 'reset' then
    update teams set points = _cfg_int(a, 'startPoints') - handicap where auction_id = p_id;
    update players set unsold = 0, team_idx = null, price = null, how = null where auction_id = p_id and not captain;
    update auctions set status = 'setup', current_player = null, bid_amount = 0, bid_team = null, ends_at = null,
           paused_left_ms = null, next_at = null, last_result = null, undo = null,
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
  public._finish(uuid), public._next(uuid), public._bump(uuid), public._push_undo(uuid, jsonb), public._state_for(uuid, text)
  from public, anon, authenticated;

revoke execute on function public.create_auction(jsonb, jsonb), public.whoami(uuid, text), public.get_links(uuid, text),
  public.get_state(uuid, text), public.get_photos(uuid, text), public.get_chat(uuid, text, bigint),
  public.send_chat(uuid, text, text), public.hide_chat(uuid, text, bigint, boolean), public.clear_chat(uuid, text), public.place_bid(uuid, text, int), public.tick(uuid, text),
  public.host_action(uuid, text, text, jsonb)
  from public;
grant execute on function public.create_auction(jsonb, jsonb), public.whoami(uuid, text), public.get_links(uuid, text),
  public.get_state(uuid, text), public.get_photos(uuid, text), public.get_chat(uuid, text, bigint),
  public.send_chat(uuid, text, text), public.hide_chat(uuid, text, bigint, boolean), public.clear_chat(uuid, text), public.place_bid(uuid, text, int), public.tick(uuid, text),
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
    '초월자 1','초월자 2','초월자 3','불멸 1','불멸 2','불멸 3','레디언트','언랭'])
$$;
-- 포지션: 여러 개 고를 수 있음 ("타격대, 척후대"처럼 고른 순서대로 쉼표로 이음). 잘못된 값이면 null
create or replace function public._norm_pos(t text) returns text
language sql immutable as $$
  select case when count(*) = 0 or bool_or(not (x = any (array['타격대','척후대','감시자','전략가']))) then null
              else string_agg(x, ', ' order by o) end
  from (select x, min(o) o from (select trim(x) x, o from unnest(string_to_array(coalesce(t, ''), ',')) with ordinality u(x, o)) a
        where x <> '' group by x) b
$$;
-- 올린 사진: 비우거나, 400KB 이하의 jpeg/png/webp 이미지만
create or replace function public._clean_photo(p text) returns text
language sql immutable as $$
  select case when coalesce(p, '') ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' and length(p) <= 400000 then p else '' end
$$;
create or replace function public._valid_pos(t text) returns boolean
language sql immutable as $$ select _norm_pos(t) is not null $$;

-- 주 요원: 이름 목록(jsonb 배열)을 다듬어 최대 3개까지 (빈 값·중복 빼고, 고른 순서 유지)
create or replace function public._clean_agents(p jsonb) returns text[]
language sql immutable as $$
  select coalesce((select array_agg(x order by o) from (
    select x, min(o) o from (
      select left(trim(e.value), 20) x, e.ordinality o
      from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality e) t
    where x <> '' group by x order by min(o) limit 3) u), '{}')
$$;

create or replace function public._signup_json(s public.signups) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', s.id, 'discord_name', s.discord_name, 'discord_username', s.discord_username,
    'discord_avatar', s.discord_avatar, 'nick', s.nick, 'peak', s.peak, 'current', s.current_tier, 'pos', s.pos,
    'agents', to_jsonb(s.agents), 'motto', s.motto, 'show_avatar', s.show_avatar, 'has_photo', s.photo <> '',
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
  return _signup_json(s) || jsonb_build_object('photo', s.photo);   -- 본인에게만 사진도 (고치기 미리보기)
end $$;

-- 신청하기: 디스코드 이름은 브라우저가 보낸 값이 아니라 로그인 정보에서 서버가 직접 꺼냄
drop function if exists public.submit_signup(text, text, text, text, text);   -- 7단계: 주 요원을 받도록 바뀜
drop function if exists public.submit_signup(text, text, text, text, text, jsonb);   -- 각오 한마디도 받도록 바뀜
drop function if exists public.submit_signup(text, text, text, text, text, jsonb, text);   -- 개인정보 동의·프로필 사진 선택을 받도록 바뀜
drop function if exists public.submit_signup(text, text, text, text, text, jsonb, text, boolean, boolean);   -- 직접 올린 사진도 받도록 바뀜
create or replace function public.submit_signup(p_code text, p_nick text, p_peak text, p_current text, p_pos text, p_agents jsonb default '[]',
  p_motto text default '', p_consent boolean default false, p_show_avatar boolean default false, p_photo text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_auction uuid; v_meta jsonb; v_nick text := left(trim(coalesce(p_nick, '')), 16);
  v_name text; v_user text; s signups;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 로그인해야 신청할 수 있어요.'); end if;
  select id into v_auction from auctions where signup_code = p_code;
  if v_auction is null then return jsonb_build_object('ok', false, 'reason', '신청 링크가 올바르지 않아요.'); end if;
  if _locked_id(v_auction) or not _signup_open((select x from auctions x where x.id = v_auction)) then
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
  if not coalesce(p_consent, false) then return jsonb_build_object('ok', false, 'reason', '개인정보 안내를 읽고 동의해 주세요.'); end if;

  select coalesce(raw_user_meta_data, '{}') into v_meta from auth.users where id = v_uid;
  v_user := regexp_replace(coalesce(v_meta ->> 'full_name', v_meta ->> 'name', ''), '#0$', '');
  v_name := coalesce(nullif(v_meta #>> '{custom_claims,global_name}', ''), nullif(v_user, ''), '이름 없음');

  insert into signups (auction_id, user_id, discord_id, discord_name, discord_username, discord_avatar, nick, peak, current_tier, pos, agents, motto, consented_at, show_avatar, photo)
  values (v_auction, v_uid, coalesce(v_meta ->> 'provider_id', v_meta ->> 'sub', ''), left(v_name, 40), left(v_user, 40),
          left(coalesce(v_meta ->> 'avatar_url', ''), 300), v_nick, p_peak, p_current, _norm_pos(p_pos), _clean_agents(p_agents), left(trim(coalesce(p_motto, '')), 60), now(), coalesce(p_show_avatar, false),
          case when coalesce(p_show_avatar, false) then '' else _clean_photo(p_photo) end)
  on conflict (auction_id, user_id) do nothing
  returning * into s;
  if s.id is null then       -- 거의 동시에 두 번 눌렀을 때
    select * into s from signups where auction_id = v_auction and user_id = v_uid;
    return jsonb_build_object('ok', false, 'reason', '이미 이 디스코드 계정으로 신청했어요.', 'signup', _signup_json(s));
  end if;
  perform _slog(v_auction, '신청 접수', format('%s (%s) · %s / %s · %s%s', s.nick, s.discord_name, s.peak, s.current_tier, s.pos,
    case when cardinality(s.agents) > 0 then ' · ' || array_to_string(s.agents, ', ') else '' end));
  return jsonb_build_object('ok', true, 'signup', _signup_json(s));
end $$;

-- 진행자 화면의 신청 명단
create or replace function public.get_signups(p_id uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return null; end if;
  return (select coalesce(jsonb_agg(_signup_json(s) || jsonb_build_object('captain', s.captain, 'score', s.score_override) order by s.id), '[]')
          from signups s where s.auction_id = p_id);
end $$;

revoke execute on function public._valid_tier(text), public._valid_pos(text), public._norm_pos(text), public._clean_photo(text), public._clean_agents(jsonb), public._signup_json(public.signups)
  from public, anon, authenticated;
revoke execute on function public.signup_info(text), public.my_signup(text),
  public.submit_signup(text, text, text, text, text, jsonb, text, boolean, boolean, text), public.get_signups(uuid, text) from public;
grant execute on function public.signup_info(text), public.my_signup(text),
  public.submit_signup(text, text, text, text, text, jsonb, text, boolean, boolean, text), public.get_signups(uuid, text) to anon, authenticated;

-- =====================================================================
-- 운영자 콘솔 (admin.html) — 디스코드로 로그인한 진행자·운영자만
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

-- 진행 권한이 있는 운영자: 제작자, 모든 회차 진행 권한을 받은 운영자, 또는 어떤 회차의 진행자 → 운영자 초대·승인 가능
create or replace function public._is_hostlike() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(_my_role() = 'owner' or (_is_staff() and (
    (select all_host from staff where user_id = auth.uid()) or exists (select 1 from auctions where host_user = auth.uid()))), false)
$$;

create or replace function public._no() returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'reason', '운영자만 할 수 있어요. 디스코드로 로그인했는지 확인해 주세요.') $$;

-- 진행 기록 남기기 (지금 로그인한 사람 이름으로)
create or replace function public._slog(p_auction uuid, p_action text, p_detail text default '') returns void
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  select * into d from _discord_of(auth.uid());
  insert into staff_log (auction_id, user_id, who, action, detail, event_title)
  values (p_auction, auth.uid(), coalesce(d.name, '알 수 없음'), p_action, left(coalesce(p_detail, ''), 500),
          coalesce((select title from auctions where id = p_auction), ''));
end $$;

-- 기록에 쓸 한국 시각 글자
create or replace function public._kst(t timestamptz) returns text
language sql immutable as $$ select coalesce(to_char(t at time zone 'Asia/Seoul', 'MM/DD HH24:MI'), '없음') $$;

-- 내 상태: 로그인 여부, 역할, 진행자 등록 여부
create or replace function public.my_role() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record;
begin
  if auth.uid() is null then
    return jsonb_build_object('logged_in', false, 'owner_exists', exists (select 1 from staff where role = 'owner'));
  end if;
  select * into d from _discord_of(auth.uid());
  return jsonb_build_object('logged_in', true, 'role', _my_role(), 'user_id', auth.uid(), 'can_invite', _is_hostlike(),
    'all_host', coalesce((select all_host from staff where user_id = auth.uid()), false),
    'owner_exists', exists (select 1 from staff where role = 'owner'),
    'name', d.name, 'username', d.username, 'avatar', d.avatar);
end $$;

-- 제작자(사이트 주인) 등록: 아직 제작자가 없을 때, 진행자 링크(경매 진행자 열쇠)를 가진 사람만
create or replace function public.claim_owner(p_id uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 먼저 로그인해 주세요.'); end if;
  if exists (select 1 from staff where role = 'owner') then return jsonb_build_object('ok', false, 'reason', '이미 제작자가 등록돼 있어요.'); end if;
  if (select role from _auth(p_id, p_key)) is distinct from 'host' then return jsonb_build_object('ok', false, 'reason', '진행자 링크가 올바르지 않아요.'); end if;
  select * into d from _discord_of(auth.uid());
  insert into staff (user_id, role, discord_name, discord_username, discord_avatar, approved_at)
  values (auth.uid(), 'owner', d.name, d.username, d.avatar, now())
  on conflict (user_id) do update set role = 'owner', approved_at = now();
  perform _slog(null, '제작자 등록', d.name);
  return jsonb_build_object('ok', true);
end $$;

-- 운영자 요청 (초대 링크 + 디스코드 로그인) → 진행자가 승인해야 운영자가 됨
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
  perform _slog(null, '운영자 요청', d.name);
  return jsonb_build_object('ok', true, 'role', 'pending');
end $$;

create or replace function public.staff_members() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not _is_staff() then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'role', role, 'name', discord_name,
            'username', discord_username, 'avatar', discord_avatar, 'at', _ms(created_at), 'all_host', all_host)
            order by case role when 'owner' then 0 when 'staff' then 1 else 2 end, created_at), '[]')
          from staff where role <> 'pending' or _is_hostlike());
end $$;

-- 승인·거절: 제작자와 진행자 / 운영자에서 빼기: 제작자만
create or replace function public.staff_decide(p_user uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not _is_hostlike() then return jsonb_build_object('ok', false, 'reason', '제작자나 진행자만 할 수 있어요.'); end if;
  if p_action = 'remove' and _my_role() is distinct from 'owner' then return jsonb_build_object('ok', false, 'reason', '운영자 빼기는 제작자만 할 수 있어요.'); end if;
  if p_action in ('approve', 'reject') and (select role from staff where user_id = p_user) is distinct from 'pending' then
    return jsonb_build_object('ok', false, 'reason', '승인을 기다리는 요청이 아니에요.');
  end if;
  select discord_name into v_name from staff where user_id = p_user;
  if p_action = 'approve' then
    update staff set role = 'staff', approved_at = now() where user_id = p_user and role = 'pending';
    if found then perform _slog(null, '운영자 승인', v_name); end if;
  elsif p_action in ('reject', 'remove') then
    delete from staff where user_id = p_user and role <> 'owner';
    if found then perform _slog(null, case p_action when 'reject' then '운영자 요청 거절' else '운영자에서 뺌' end, v_name); end if;
  else return jsonb_build_object('ok', false, 'reason', '알 수 없는 조작이에요.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_invite(p_reset boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_hostlike() then return null; end if;
  if p_reset and _my_role() is distinct from 'owner' then return jsonb_build_object('ok', false, 'reason', '초대 링크 바꾸기는 제작자만 할 수 있어요.'); end if;
  if p_reset then
    update site_settings set invite_code = replace(gen_random_uuid()::text, '-', '') where id = 1;
    perform _slog(null, '초대 링크 새로 바꿈', '예전 초대 링크는 더 이상 쓸 수 없음');
  end if;
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
      'host_name', (select discord_name from staff where user_id = a.host_user), 'status_label', a.status,
      'locked', _locked(a), 'unlocked', a.unlocked,
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
  insert into auctions (config, title, signup_mode, host_user) values (p_config, left(coalesce(trim(p_title), ''), 60), 'closed', auth.uid()) returning id into v_id;
  insert into auction_keys (key, auction_id, role) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'host');
  insert into auction_keys (key, auction_id, role) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'screen');
  for i in 0 .. (p_config ->> 'teamCount')::int - 1 loop
    insert into auction_keys (key, auction_id, role, team_idx) values (replace(gen_random_uuid()::text, '-', ''), v_id, 'team', i);
  end loop;
  perform _log(v_id, '', format('%s 님이 회차를 만들었습니다.', d.name));
  perform _slog(v_id, '회차 만듦', left(coalesce(trim(p_title), ''), 60));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 회차 이름·일정·신청 마감 바꾸기
create or replace function public.update_event(p_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o auctions; n auctions; v_changes text;
begin
  if not _is_staff() then return _no(); end if;
  select * into o from auctions where id = p_id;
  if _locked(o) then return _lock_msg(); end if;
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
  where id = p_id
  returning * into n;
  if n.id is null then return jsonb_build_object('ok', false, 'reason', '회차를 찾지 못했어요.'); end if;
  v_changes := concat_ws(', ',
    case when n.title is distinct from o.title then format('이름 "%s" → "%s"', o.title, n.title) end,
    case when n.signup_opens_at is distinct from o.signup_opens_at then format('신청 시작 %s → %s', _kst(o.signup_opens_at), _kst(n.signup_opens_at)) end,
    case when n.signup_closes_at is distinct from o.signup_closes_at then format('신청 마감 %s → %s', _kst(o.signup_closes_at), _kst(n.signup_closes_at)) end,
    case when n.auction_at is distinct from o.auction_at then format('경매 일시 %s → %s', _kst(o.auction_at), _kst(n.auction_at)) end,
    case when n.match_at is distinct from o.match_at then format('경기 일시 %s → %s', _kst(o.match_at), _kst(n.match_at)) end,
    case when n.signup_mode is distinct from o.signup_mode then format('신청 상태 → %s',
      case n.signup_mode when 'auto' then '일정대로 자동' when 'open' then '지금 열기' else '지금 마감' end) end);
  if v_changes <> '' then perform _slog(p_id, '일정·신청 바꿈', v_changes); end if;
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
      'signup_code', a.signup_code, 'team_count', (a.config ->> 'teamCount')::int, 'config', a.config,
      'locked', _locked(a), 'unlocked', a.unlocked),
    'signups', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'user_id', s.user_id,
        'discord_name', s.discord_name, 'discord_username', s.discord_username, 'discord_avatar', s.discord_avatar,
        'nick', s.nick, 'peak', s.peak, 'current', s.current_tier, 'pos', s.pos, 'agents', to_jsonb(s.agents), 'grade', s.grade, 'bench', s.bench, 'motto', s.motto, 'captain', s.captain, 'memo', s.memo, 'score', s.score_override,
        'at', _ms(s.created_at), 'updated_by', s.updated_by, 'updated_at', _ms(s.updated_at),
        'checks', (select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'user_id', c.user_id, 'name', c.staff_name) order by c.at), '[]')
                   from signup_checks c where c.signup_id = s.id)) order by s.id), '[]')
      from signups s where s.auction_id = a.id),
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'assignee', t.assignee,
        'due_at', _ms(t.due_at), 'done', t.done, 'created_by', t.created_by) order by t.done, t.due_at nulls last, t.id), '[]')
      from tasks t where t.auction_id = a.id),
    'host', jsonb_build_object('user_id', a.host_user, 'name', (select discord_name from staff where user_id = a.host_user)),
    'can_host', _can_host(a.id),
    'state', _state(a.id),
    'links', case when _can_host(a.id) then jsonb_build_object(
        'host_key', (select key from auction_keys where auction_id = a.id and role = 'host'),
        'team_keys', (select jsonb_agg(key order by team_idx) from auction_keys where auction_id = a.id and role = 'team'),
        'screen_key', (select key from auction_keys where auction_id = a.id and role = 'screen' limit 1)) end);
end $$;

-- 신청 고치기: 닉네임·티어·포지션·메모·팀장. 티어를 고치면 그 사람의 검수는 처음부터 다시
create or replace function public.signup_update(p_signup bigint, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s signups; d record; v_peak text; v_cur text; v_teams int; v_changes text; v_nick text; v_score numeric;
begin
  if not _is_staff() then return _no(); end if;
  select * into s from signups where id = p_signup for update;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', '신청을 찾지 못했어요.'); end if;
  if _locked_id(s.auction_id) then return _lock_msg(); end if;
  v_peak := coalesce(p_patch ->> 'peak', s.peak);
  v_cur := coalesce(p_patch ->> 'current', s.current_tier);
  if not _valid_tier(v_peak) or not _valid_tier(v_cur) then return jsonb_build_object('ok', false, 'reason', '티어 이름이 잘못됐어요.'); end if;
  if p_patch ? 'pos' and not _valid_pos(p_patch ->> 'pos') then return jsonb_build_object('ok', false, 'reason', '포지션이 잘못됐어요.'); end if;
  if p_patch ? 'nick' and coalesce(trim(p_patch ->> 'nick'), '') = '' then return jsonb_build_object('ok', false, 'reason', '닉네임이 비어 있어요.'); end if;
  v_score := case when p_patch ? 'score' then round((p_patch ->> 'score')::numeric, 1) else s.score_override end;
  if v_score is not null and (v_score < 0 or v_score > 1000) then return jsonb_build_object('ok', false, 'reason', '점수는 0에서 1000 사이로 적어 주세요.'); end if;
  if coalesce((p_patch ->> 'captain')::boolean, false) and not s.captain then
    v_teams := 8;   -- 팀 수 = 팀장 수 (최대 8팀)
    if (select count(*) from signups where auction_id = s.auction_id and captain) >= v_teams then
      return jsonb_build_object('ok', false, 'reason', format('팀장은 %s명까지예요. 다른 팀장을 먼저 빼 주세요.', v_teams));
    end if;
  end if;
  select * into d from _discord_of(auth.uid());
  v_nick := case when p_patch ? 'nick' then left(trim(p_patch ->> 'nick'), 16) else s.nick end;
  v_changes := concat_ws(', ',
    case when v_nick <> s.nick then format('닉네임 %s → %s', s.nick, v_nick) end,
    case when v_peak <> s.peak then format('최고 티어 %s → %s', s.peak, v_peak) end,
    case when v_cur <> s.current_tier then format('현재 티어 %s → %s', s.current_tier, v_cur) end,
    case when p_patch ? 'pos' and _norm_pos(p_patch ->> 'pos') <> s.pos then format('포지션 %s → %s', s.pos, _norm_pos(p_patch ->> 'pos')) end,
    case when p_patch ? 'motto' and left(trim(coalesce(p_patch ->> 'motto', '')), 60) <> s.motto then format('각오 "%s" → "%s"', s.motto, left(trim(coalesce(p_patch ->> 'motto', '')), 60)) end,
    case when p_patch ? 'agents' and _clean_agents(p_patch -> 'agents') <> s.agents
         then format('주 요원 %s → %s', coalesce(nullif(array_to_string(s.agents, ', '), ''), '없음'), coalesce(nullif(array_to_string(_clean_agents(p_patch -> 'agents'), ', '), ''), '없음')) end,
    case when p_patch ? 'memo' and left(coalesce(p_patch ->> 'memo', ''), 200) <> s.memo then format('메모 "%s" → "%s"', s.memo, left(coalesce(p_patch ->> 'memo', ''), 200)) end,
    case when v_score is distinct from s.score_override then format('직접 정한 점수 %s → %s', coalesce(s.score_override::text, '자동'), coalesce(v_score::text, '자동')) end,
    case when (p_patch ->> 'captain') is not null and (p_patch ->> 'captain')::boolean <> s.captain
         then case when (p_patch ->> 'captain')::boolean then '팀장으로 지정' else '팀장에서 뺌' end end,
    case when v_peak <> s.peak or v_cur <> s.current_tier then '(티어가 바뀌어 검수 초기화)' end);
  if v_changes <> '' then perform _slog(s.auction_id, '참가자 고침', format('%s (%s): %s', s.nick, s.discord_name, v_changes)); end if;
  if v_peak <> s.peak or v_cur <> s.current_tier then delete from signup_checks where signup_id = s.id; end if;
  update signups set
    nick         = case when p_patch ? 'nick' then left(trim(p_patch ->> 'nick'), 16) else nick end,
    peak         = v_peak, current_tier = v_cur,
    pos          = coalesce(_norm_pos(p_patch ->> 'pos'), pos),
    agents       = case when p_patch ? 'agents' then _clean_agents(p_patch -> 'agents') else agents end,
    motto        = case when p_patch ? 'motto' then left(trim(coalesce(p_patch ->> 'motto', '')), 60) else motto end,
    memo         = case when p_patch ? 'memo' then left(coalesce(p_patch ->> 'memo', ''), 200) else memo end,
    captain      = coalesce((p_patch ->> 'captain')::boolean, captain),
    score_override = v_score,
    updated_at   = now(), updated_by = d.name
  where id = s.id;
  -- 이미 경매에 올라간 선수면 경매 화면에도 같이 반영 (닉네임·티어·포지션·점수)
  update players set name = case when p_patch ? 'nick' then v_nick else name end,
         peak = v_peak, current_tier = v_cur, pos = coalesce(_norm_pos(p_patch ->> 'pos'), pos), score_override = v_score,
         agents = case when p_patch ? 'agents' then _clean_agents(p_patch -> 'agents') else agents end,
         motto = case when p_patch ? 'motto' then left(trim(coalesce(p_patch ->> 'motto', '')), 60) else motto end
   where signup_id = s.id and auction_id = s.auction_id;
  if found then perform _bump(s.auction_id); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.signup_delete(p_signup bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s signups;
begin
  if not _is_staff() then return _no(); end if;
  if _locked_id((select auction_id from signups where id = p_signup)) then return _lock_msg(); end if;
  -- 이미 경매 선수로 올라간 사람을 지우면 경매에 "유령 선수"가 남으므로 막음
  if exists (select 1 from players pl join signups sg on sg.id = p_signup and sg.auction_id = pl.auction_id where pl.signup_id = p_signup) then
    return jsonb_build_object('ok', false, 'reason', '이미 경매 선수로 올라간 사람이에요. ‘경매 준비’ 탭에서 이 사람의 ‘포함’을 끄고 다시 채운 뒤 지워 주세요.');
  end if;
  delete from signups where id = p_signup returning * into s;
  if s.id is not null then
    perform _slog(s.auction_id, '신청 지움', format('%s (%s) · %s / %s · %s', s.nick, s.discord_name, s.peak, s.current_tier, s.pos));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 교차검수 표시 켜기/끄기 (내 이름으로)
create or replace function public.signup_check(p_signup bigint, p_kind text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record; s signups; v_label text := case p_kind when 'tier' then '티어 검수' else '점수 계산 재확인' end;
begin
  if not _is_staff() then return _no(); end if;
  if p_kind not in ('tier', 'score') then return jsonb_build_object('ok', false, 'reason', '검수 종류가 잘못됐어요.'); end if;
  select * into s from signups where id = p_signup;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', '신청을 찾지 못했어요.'); end if;
  if _locked_id(s.auction_id) then return _lock_msg(); end if;
  if p_on then
    select * into d from _discord_of(auth.uid());
    insert into signup_checks (signup_id, kind, user_id, staff_name) values (p_signup, p_kind, auth.uid(), d.name)
    on conflict do nothing;
    if found then perform _slog(s.auction_id, v_label || ' 확인', format('%s (%s) · %s / %s', s.nick, s.discord_name, s.peak, s.current_tier)); end if;
  else
    delete from signup_checks where signup_id = p_signup and kind = p_kind and user_id = auth.uid();
    if found then perform _slog(s.auction_id, v_label || ' 확인 취소', format('%s (%s)', s.nick, s.discord_name)); end if;
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
  perform _slog(p_id, '할 일 추가', concat_ws(' · ', left(trim(p_title), 100),
    (select '담당 ' || discord_name from staff where user_id = p_assignee), case when p_due is not null then _kst(p_due) || '까지' end));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.task_update(p_task bigint, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o tasks; n tasks; v_changes text;
begin
  if not _is_staff() then return _no(); end if;
  select * into o from tasks where id = p_task;
  update tasks set
    title    = case when p_patch ? 'title' and coalesce(trim(p_patch ->> 'title'), '') <> '' then left(trim(p_patch ->> 'title'), 100) else title end,
    assignee = case when p_patch ? 'assignee' then (p_patch ->> 'assignee')::uuid else assignee end,
    due_at   = case when p_patch ? 'due_at' then (p_patch ->> 'due_at')::timestamptz else due_at end,
    done     = coalesce((p_patch ->> 'done')::boolean, done),
    done_at  = case when (p_patch ->> 'done')::boolean then now() when p_patch ? 'done' then null else done_at end
  where id = p_task
  returning * into n;
  if n.id is not null then
    v_changes := concat_ws(', ',
      case when n.title <> o.title then format('내용 "%s" → "%s"', o.title, n.title) end,
      case when n.assignee is distinct from o.assignee then format('담당 %s → %s',
        coalesce((select discord_name from staff where user_id = o.assignee), '없음'), coalesce((select discord_name from staff where user_id = n.assignee), '없음')) end,
      case when n.due_at is distinct from o.due_at then format('기한 %s → %s', _kst(o.due_at), _kst(n.due_at)) end,
      case when n.done <> o.done then case when n.done then '완료' else '다시 할 일로' end end);
    if v_changes <> '' then perform _slog(n.auction_id, '할 일 바꿈', format('%s: %s', o.title, v_changes)); end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.task_delete(p_task bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  if not _is_staff() then return _no(); end if;
  delete from tasks where id = p_task returning * into t;
  if t.id is not null then perform _slog(t.auction_id, '할 일 지움', t.title); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 이 회차의 경매 준비를 할 수 있는 사람: 그 회차의 진행자, 또는 제작자
create or replace function public._can_host(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(_my_role() = 'owner' or (_is_staff() and (
    (select host_user from auctions where id = p_id) = auth.uid() or (select all_host from staff where user_id = auth.uid()))), false)
$$;

-- 진행자 넘기기 (지금 진행자 또는 제작자가, 다른 운영자에게)
create or replace function public.set_event_host(p_id uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from text; v_to text;
begin
  if not _can_host(p_id) then return jsonb_build_object('ok', false, 'reason', '이 회차의 진행자나 제작자만 진행자를 넘길 수 있어요.'); end if;
  select discord_name into v_to from staff where user_id = p_user and role in ('owner', 'staff');
  if v_to is null then return jsonb_build_object('ok', false, 'reason', '운영자에게만 넘길 수 있어요.'); end if;
  select s.discord_name into v_from from auctions a left join staff s on s.user_id = a.host_user where a.id = p_id;
  update auctions set host_user = p_user where id = p_id;
  perform _slog(p_id, '진행자 넘김', format('%s → %s', coalesce(v_from, '없음'), v_to));
  return jsonb_build_object('ok', true);
end $$;

-- 운영자 콘솔에서 경매 준비하기 (진행자·제작자만). 진행자 화면과 같은 규칙(host_action)을 그대로 씀
-- 경매 준비의 현재 상태를 한 줄로 (팀장·대기·경매 티어가 있는 신청만). 콘솔이 같은 방식으로 계산해 보내서 비교함
create or replace function public._prep_sig(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(s.id::text || ':' || case when s.captain then '1' else '0' end
           || case when s.bench and not s.captain then '1' else '0' end
           || case when s.captain then '-' else coalesce(s.grade, '-') end, ',' order by s.id), '')
  from signups s where s.auction_id = p_id and (s.captain or s.bench or s.grade is not null)
$$;
revoke execute on function public._prep_sig(uuid) from public, anon, authenticated;

create or replace function public.console_host_action(p_id uuid, p_action text, p_arg jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_key text; r jsonb;
begin
  if not _can_host(p_id) then return jsonb_build_object('ok', false, 'reason', '이 회차의 진행자나 제작자만 경매 준비를 할 수 있어요.'); end if;
  if _locked_id(p_id) then return _lock_msg(); end if;
  -- 다른 운영자가 먼저 경매 준비를 바꿨으면 덮어쓰지 않음 (콘솔이 불러온 때의 서명 base_sig와 비교)
  if p_action in ('save_prep', 'load_signups') and p_arg ? 'base_sig' and (p_arg ->> 'base_sig') is distinct from _prep_sig(p_id) then
    return jsonb_build_object('ok', false, 'conflict', true,
      'reason', '다른 운영자가 방금 경매 준비(팀장·대기·경매 티어)를 바꿨어요. ‘다시 불러오기’로 새 내용을 확인한 뒤 다시 해 주세요.');
  end if;
  -- 경매 준비 저장 (선수 채우기 없이): arg = {captains: [신청 번호], exclude: [대기 신청 번호], grades: {"신청 번호": "A"|""}}
  if p_action = 'save_prep' then
    if (select status from auctions where id = p_id) <> 'setup' then
      return jsonb_build_object('ok', false, 'reason', '경매 준비 단계에서만 저장할 수 있어요.');
    elsif jsonb_typeof(coalesce(p_arg -> 'captains', '[]')) <> 'array' or jsonb_typeof(coalesce(p_arg -> 'exclude', '[]')) <> 'array'
       or jsonb_typeof(coalesce(p_arg -> 'grades', '{}')) <> 'object' then
      return jsonb_build_object('ok', false, 'reason', '저장할 내용이 올바르지 않아요.');
    elsif jsonb_array_length(coalesce(p_arg -> 'captains', '[]')) > 8 then
      return jsonb_build_object('ok', false, 'reason', '팀장은 8명까지예요.');
    elsif exists (select 1 from jsonb_each_text(coalesce(p_arg -> 'grades', '{}')) g(k, v) where v not in ('A', 'B', 'C', 'D', '')) then
      return jsonb_build_object('ok', false, 'reason', '경매 티어는 A, B, C, D 중 하나예요.');
    end if;
    update signups s set captain = (s.id::text in (select jsonb_array_elements_text(coalesce(p_arg -> 'captains', '[]')))) where s.auction_id = p_id;
    update signups s set bench = not s.captain and (s.id::text in (select jsonb_array_elements_text(coalesce(p_arg -> 'exclude', '[]')))) where s.auction_id = p_id;
    update signups s set grade = case when s.captain then null else nullif(g.v, '') end
      from jsonb_each_text(coalesce(p_arg -> 'grades', '{}')) g(k, v) where s.auction_id = p_id and s.id::text = g.k;
    perform _slog(p_id, '경매 준비 저장', (select format('팀장 %s명, 대기 %s명, 경매 티어 A %s · B %s · C %s · D %s명',
        count(*) filter (where captain), count(*) filter (where bench),
        count(*) filter (where grade = 'A'), count(*) filter (where grade = 'B'), count(*) filter (where grade = 'C'), count(*) filter (where grade = 'D'))
      from signups where auction_id = p_id));
    return jsonb_build_object('ok', true);
  end if;
  if p_action not in ('load_signups', 'set_config', 'set_handicap', 'set_order') then
    return jsonb_build_object('ok', false, 'reason', '운영자 콘솔에서 할 수 없는 조작이에요.');
  end if;
  select key into v_key from auction_keys where auction_id = p_id and role = 'host';
  r := host_action(p_id, v_key, p_action, p_arg);
  if (r ->> 'ok')::boolean then
    perform _slog(p_id, case p_action when 'load_signups' then '경매 선수 채움' when 'set_config' then '경매 설정 바꿈'
                                      when 'set_handicap' then '핸디캡 바꿈' else '경매 순서 확정' end,
      case p_action
        when 'load_signups' then format('팀장 %s명, 경매 선수 %s명', jsonb_array_length(r -> 'state' -> 'teams'), jsonb_array_length(r -> 'state' -> 'queue'))
        when 'set_handicap' then format('%s: %sP', r -> 'state' -> 'teams' -> ((p_arg ->> 'team')::int) ->> 'name', p_arg ->> 'amount')
        when 'set_config' then (select string_agg(format('%s=%s', k, case when k = 'tierScores' then '(점수표)' else v #>> '{}' end), ', ')
                                from jsonb_each(p_arg) e(k, v))
        else format('%s명', jsonb_array_length(p_arg)) end);
  end if;
  return r;
end $$;

-- 회차(내전) 지우기: 그 회차의 진행자나 제작자만. 실수 방지로 회차 이름을 똑같이 적어야 함
create or replace function public.delete_event(p_id uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; v_title text; v_signups int;
begin
  if not _can_host(p_id) then return jsonb_build_object('ok', false, 'reason', '이 회차의 진행자나 제작자만 지울 수 있어요.'); end if;
  select * into a from auctions where id = p_id;
  v_title := coalesce(nullif(a.title, ''), '이름 없는 회차');
  if coalesce(trim(p_confirm), '') <> v_title then return jsonb_build_object('ok', false, 'reason', '회차 이름이 맞지 않아요. 똑같이 적어 주세요.'); end if;
  select count(*) into v_signups from signups where auction_id = p_id;
  perform _slog(null, '회차 지움', format('%s (신청 %s명, 상태 %s)', v_title, v_signups, a.status));
  -- 지운 회차 참가자의 닉네임·디스코드 이름이 기록에 남지 않게 내용만 가림 (누가 언제 무엇을 했는지는 남김)
  update staff_log set detail = '(회차를 지워서 참가자 정보를 가렸어요)' where auction_id = p_id and detail <> '';
  delete from auctions where id = p_id;   -- 선수·팀·신청·검수·할 일·채팅·링크가 함께 지워짐 (진행 기록은 남음)
  return jsonb_build_object('ok', true);
end $$;
-- 지난 회차 잠금 풀기 / 다시 잠그기 (제작자만)
create or replace function public.set_event_unlocked(p_id uuid, p_unlocked boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  -- 그 회차의 진행자, 모든 회차 진행 권한자, 제작자가 풀고 잠글 수 있음
  if not _can_host(p_id) then return jsonb_build_object('ok', false, 'reason', '잠금은 이 회차의 진행자나 제작자만 풀 수 있어요.'); end if;
  update auctions set unlocked = coalesce(p_unlocked, false) where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'reason', '회차를 찾지 못했어요.'); end if;
  perform _slog(p_id, case when p_unlocked then '지난 회차 잠금 풀기' else '지난 회차 다시 잠그기' end, '');
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.set_event_unlocked(uuid, boolean) from public;
grant execute on function public.set_event_unlocked(uuid, boolean) to anon, authenticated;
revoke execute on function public._locked(public.auctions), public._locked_id(uuid), public._lock_msg() from public, anon, authenticated;

revoke execute on function public.delete_event(uuid, text) from public;
grant execute on function public.delete_event(uuid, text) to anon, authenticated;

-- 회차의 선수 사진만 지우기 (무료 저장 공간 아끼기). 진행자·제작자만, 지난 회차도 가능
create or replace function public.purge_photos(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_bytes bigint;
begin
  if not _can_host(p_id) then return jsonb_build_object('ok', false, 'reason', '이 회차의 진행자나 제작자만 할 수 있어요.'); end if;
  select count(*), coalesce(sum(length(photo)), 0) into v_n, v_bytes from players where auction_id = p_id and photo <> '';
  v_bytes := v_bytes + (select coalesce(sum(length(photo)), 0) from signups where auction_id = p_id);
  update players set photo = '' where auction_id = p_id and photo <> '';
  update signups set photo = '' where auction_id = p_id and photo <> '';
  update auctions set players_version = players_version + 1, version = version + 1 where id = p_id;
  perform _slog(p_id, '선수 사진 지움', format('%s장, 약 %sKB', v_n, round(v_bytes / 1024.0)));
  return jsonb_build_object('ok', true, 'count', v_n, 'bytes', v_bytes);
end $$;
revoke execute on function public.purge_photos(uuid) from public;
grant execute on function public.purge_photos(uuid) to anon, authenticated;

-- 참가자가 신청 기간 안에 자기 신청 고치기 (티어를 고치면 검수는 처음부터)
create or replace function public.my_signup_update(p_code text, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; s signups; v_nick text; v_peak text; v_cur text; v_pos text; v_agents text[]; v_motto text; v_changes text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 로그인해 주세요.'); end if;
  select * into a from auctions where signup_code = p_code;
  select * into s from signups where auction_id = a.id and user_id = auth.uid() for update;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', '신청 내역이 없어요.'); end if;
  if _locked(a) or not _signup_open(a) then return jsonb_build_object('ok', false, 'reason', '신청 기간이 끝나서 고칠 수 없어요. 운영자에게 말해 주세요.'); end if;
  v_nick := left(trim(coalesce(p_patch ->> 'nick', s.nick)), 16);
  v_peak := coalesce(p_patch ->> 'peak', s.peak); v_cur := coalesce(p_patch ->> 'current', s.current_tier); v_pos := case when p_patch ? 'pos' then coalesce(_norm_pos(p_patch ->> 'pos'), '') else s.pos end;
  v_agents := case when p_patch ? 'agents' then _clean_agents(p_patch -> 'agents') else s.agents end;
  v_motto := case when p_patch ? 'motto' then left(trim(coalesce(p_patch ->> 'motto', '')), 60) else s.motto end;
  if p_patch ? 'show_avatar' and (p_patch ->> 'show_avatar')::boolean is distinct from s.show_avatar then
    update signups set show_avatar = (p_patch ->> 'show_avatar')::boolean where id = s.id;
    update auctions set version = version + 1 where id = a.id;
  end if;
  if p_patch ? 'photo' or (p_patch ->> 'show_avatar')::boolean then
    -- 디스코드 사진을 쓰면 올린 사진은 지움. 경매 선수로 올라가 있으면 선수 사진도 같이 바꿈
    update signups set photo = case when coalesce((p_patch ->> 'show_avatar')::boolean, s.show_avatar) then '' else _clean_photo(p_patch ->> 'photo') end
     where id = s.id and (p_patch ? 'photo' or (p_patch ->> 'show_avatar')::boolean);
    update players pl set photo = sg.photo from signups sg where sg.id = s.id and pl.signup_id = s.id and pl.auction_id = a.id;
    if found then update auctions set players_version = players_version + 1, version = version + 1 where id = a.id; end if;
  end if;
  if v_nick = '' then return jsonb_build_object('ok', false, 'reason', '게임 닉네임을 적어 주세요.'); end if;
  if not _valid_tier(v_peak) or not _valid_tier(v_cur) then return jsonb_build_object('ok', false, 'reason', '티어를 골라 주세요.'); end if;
  if not _valid_pos(v_pos) then return jsonb_build_object('ok', false, 'reason', '포지션을 골라 주세요.'); end if;
  v_changes := concat_ws(', ',
    case when v_nick <> s.nick then format('닉네임 %s → %s', s.nick, v_nick) end,
    case when v_peak <> s.peak then format('최고 티어 %s → %s', s.peak, v_peak) end,
    case when v_cur <> s.current_tier then format('현재 티어 %s → %s', s.current_tier, v_cur) end,
    case when v_pos <> s.pos then format('포지션 %s → %s', s.pos, v_pos) end,
    case when v_agents <> s.agents then format('주 요원 → %s', coalesce(nullif(array_to_string(v_agents, ', '), ''), '없음')) end,
    case when v_motto <> s.motto then format('각오 → "%s"', v_motto) end,
    case when v_peak <> s.peak or v_cur <> s.current_tier then '(티어가 바뀌어 검수 초기화)' end);
  if v_changes = '' then return jsonb_build_object('ok', true, 'signup', _signup_json((select x from signups x where x.id = s.id))); end if;
  if v_peak <> s.peak or v_cur <> s.current_tier then delete from signup_checks where signup_id = s.id; end if;
  update signups set nick = v_nick, peak = v_peak, current_tier = v_cur, pos = v_pos, agents = v_agents, motto = v_motto,
         updated_at = now(), updated_by = '본인' where id = s.id returning * into s;
  update players set name = v_nick, peak = v_peak, current_tier = v_cur, pos = v_pos, agents = v_agents, motto = v_motto
   where signup_id = s.id and auction_id = a.id;
  if found then perform _bump(a.id); end if;
  perform _slog(a.id, '신청 고침(본인)', format('%s (%s): %s', s.nick, s.discord_name, v_changes));
  return jsonb_build_object('ok', true, 'signup', _signup_json(s));
end $$;

-- 참가자가 신청 기간 안에 신청 취소 (이미 경매 명단에 올라갔으면 운영자에게)
create or replace function public.my_signup_cancel(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a auctions; s signups;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', '디스코드로 로그인해 주세요.'); end if;
  select * into a from auctions where signup_code = p_code;
  select * into s from signups where auction_id = a.id and user_id = auth.uid();
  if s.id is null then return jsonb_build_object('ok', false, 'reason', '신청 내역이 없어요.'); end if;
  if _locked(a) or not _signup_open(a) then return jsonb_build_object('ok', false, 'reason', '신청 기간이 끝나서 취소할 수 없어요. 운영자에게 말해 주세요.'); end if;
  if exists (select 1 from players where auction_id = a.id and signup_id = s.id) then
    return jsonb_build_object('ok', false, 'reason', '이미 경매 명단에 올라가서 직접 취소할 수 없어요. 운영자에게 말해 주세요.');
  end if;
  delete from signups where id = s.id;
  perform _slog(a.id, '신청 취소(본인)', format('%s (%s)', s.nick, s.discord_name));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.my_signup_update(text, jsonb), public.my_signup_cancel(text) from public;
grant execute on function public.my_signup_update(text, jsonb), public.my_signup_cancel(text) to anon, authenticated;

revoke execute on function public._can_host(uuid), public._is_hostlike() from public, anon, authenticated;

-- 모든 회차 진행 권한 주기/빼기 (제작자만)
create or replace function public.set_all_host(p_user uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if _my_role() is distinct from 'owner' then return jsonb_build_object('ok', false, 'reason', '제작자만 할 수 있어요.'); end if;
  update staff set all_host = coalesce(p_on, false) where user_id = p_user and role = 'staff' returning discord_name into v_name;
  if v_name is null then return jsonb_build_object('ok', false, 'reason', '승인된 운영자만 지정할 수 있어요.'); end if;
  perform _slog(null, case when p_on then '모든 회차 진행 권한 줌' else '모든 회차 진행 권한 뺌' end, v_name);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.set_all_host(uuid, boolean) from public;
grant execute on function public.set_all_host(uuid, boolean) to anon, authenticated;
revoke execute on function public.set_event_host(uuid, uuid), public.console_host_action(uuid, text, jsonb) from public;
grant execute on function public.set_event_host(uuid, uuid), public.console_host_action(uuid, text, jsonb) to anon, authenticated;

-- 서비스 상태: 마지막 사용 시각과 데이터베이스 사용량. 부를 때마다 '사용 중' 표시를 써서 7일 정지 시계를 되돌림
create or replace function public.service_ping() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prev timestamptz; v_last timestamptz;
begin
  if not _is_staff() then return null; end if;
  select last_ping into v_prev from site_settings where id = 1;
  v_last := greatest(v_prev,
    (select max(created_at) from events), (select max(created_at) from chat),
    (select max(created_at) from signups), (select max(created_at) from staff_log));
  update site_settings set last_ping = now() where id = 1;
  return jsonb_build_object('ok', true, 'now', _ms(now()), 'last_activity', _ms(v_last),
    'last_auto_ping', (select _ms(last_auto_ping) from site_settings where id = 1),
    'db_bytes', pg_database_size(current_database()),
    'rounds', (select count(*) from auctions), 'signups', (select count(*) from signups),
    'photo_bytes', (select coalesce(sum(length(photo)), 0) from players) + (select coalesce(sum(length(photo)), 0) from signups));
end $$;
-- 자동 깨우기: GitHub Actions가 3일마다 부름 (시각만 기록, 다른 정보는 돌려주지 않음)
create or replace function public.keepalive() returns jsonb
language sql security definer set search_path = public as $$
  update site_settings set last_auto_ping = now() where id = 1;
  select jsonb_build_object('ok', true);
$$;
revoke execute on function public.keepalive() from public;
grant execute on function public.keepalive() to anon, authenticated;

revoke execute on function public.service_ping() from public;
grant execute on function public.service_ping() to anon, authenticated;

-- 진행 기록 보기: 회차 하나(p_id) 또는 사이트 전체(p_id 없음)
create or replace function public.get_log(p_id uuid default null, p_limit int default 300) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not _is_staff() then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'who', l.who, 'action', l.action, 'detail', l.detail,
            'at', _ms(l.created_at), 'event', coalesce(nullif(a.title, ''), nullif(l.event_title, ''), case when l.auction_id is not null then '이름 없는 회차' end)) order by l.id desc), '[]')
          from (select * from staff_log
                where (p_id is null or auction_id = p_id)
                order by id desc limit least(greatest(coalesce(p_limit, 300), 1), 1000)) l
          left join auctions a on a.id = l.auction_id);
end $$;

revoke execute on function public._slog(uuid, text, text), public._kst(timestamptz) from public, anon, authenticated;
revoke execute on function public.get_log(uuid, int) from public;
grant execute on function public.get_log(uuid, int) to anon, authenticated;

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
