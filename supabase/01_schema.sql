-- Jasoos Online, isolated namespace. Run 01 then 02 then 03 in SQL Editor.
begin;
create schema if not exists jasoos_private;
revoke all on schema jasoos_private from public, anon, authenticated;
create table if not exists jasoos_private.rooms (
 id uuid primary key default gen_random_uuid(), alias text not null,
 title text not null, host uuid not null, invite_hash text not null,
 version bigint not null default 1, closed boolean not null default false,
 join_open boolean not null default true, settings jsonb not null,
 state jsonb not null default '{"stage":"LOBBY"}',
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 request_id uuid not null, unique(host,request_id)
);
create unique index if not exists jasoos_active_alias on jasoos_private.rooms(alias) where not closed;
create table if not exists jasoos_private.players (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references jasoos_private.rooms on delete cascade,
 uid uuid not null, name text not null, name_key text not null, seat bigint generated always as identity,
 active boolean not null default true, ready boolean not null default false,
 last_seen timestamptz not null default clock_timestamp(),
 unique(room_id,uid)
);
create unique index if not exists jasoos_active_name on jasoos_private.players(room_id,name_key) where active;
create table if not exists jasoos_private.secrets (
 round_id uuid primary key, room_id uuid not null references jasoos_private.rooms on delete cascade,
 ordinary_word text not null, spy_word text, spies uuid[] not null, members uuid[] not null
);
create table if not exists jasoos_private.ballots (
 round_id uuid not null references jasoos_private.secrets on delete cascade,
 runoff integer not null, voter uuid not null references jasoos_private.players,
 picks uuid[] not null, primary key(round_id,runoff,voter)
);
create table if not exists jasoos_private.words (
 key text primary key, lang text not null, category text not null, category_name text not null,
 word text not null, spy_word text
);
create table if not exists jasoos_private.history (
 room_id uuid not null references jasoos_private.rooms on delete cascade,
 word_key text not null, used_at timestamptz not null default clock_timestamp(), primary key(room_id,word_key)
);
create table if not exists jasoos_private.rate_limits (
 uid uuid primary key, window_start timestamptz not null, calls integer not null default 0,
 create_window timestamptz not null default clock_timestamp(), creates integer not null default 0
);
alter table jasoos_private.rooms enable row level security;
alter table jasoos_private.players enable row level security;
alter table jasoos_private.secrets enable row level security;
alter table jasoos_private.ballots enable row level security;
alter table jasoos_private.words enable row level security;
alter table jasoos_private.history enable row level security;
alter table jasoos_private.rate_limits enable row level security;
revoke all on all tables in schema jasoos_private from public,anon,authenticated;
revoke all on all sequences in schema jasoos_private from public,anon,authenticated;

create or replace function jasoos_private.clean(t text) returns text
language sql immutable set search_path='' as $$
 select trim(regexp_replace(translate(coalesce(t,''),'يك','یک'),'[[:space:][:cntrl:]]+',' ','g'))
$$;
create or replace function jasoos_private.norm(t text) returns text
language sql immutable set search_path='' as $$
 select lower(regexp_replace(translate(jasoos_private.clean(t),'۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩','01234567890123456789'),'[[:space:]‌‍]+','','g'))
$$;
create or replace function jasoos_private.validate_settings(d jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare n int; s int; seconds int; pair jsonb; custom jsonb;
begin
 n:=(d->>'capacity')::int; s:=(d->>'spies')::int; seconds:=(d->>'seconds')::int;
 if n is null or s is null or seconds is null or n<3 or n>30 or s<1 or s>n-2 or seconds<1 or seconds>86400
 or coalesce(d->>'mode','') not in ('simple','advanced') or coalesce(d->>'lang','') not in ('fa','en')
 or jsonb_typeof(d->'voting') is distinct from 'boolean' or jsonb_typeof(d->'hints') is distinct from 'boolean'
 or jsonb_typeof(d->'categories') is distinct from 'array' or jsonb_array_length(d->'categories')>20 then raise exception 'INVALID_SETTINGS'; end if;
 custom:=coalesce(d->'custom','[]');
 if jsonb_typeof(custom) <> 'array' or jsonb_array_length(custom)>400 then raise exception 'INVALID_CUSTOM_WORDS'; end if;
 for pair in select value from jsonb_array_elements(custom) loop
 if coalesce(length(pair->>'word'),0) not between 2 and 40 or length(regexp_replace(coalesce(pair->>'word',''),'[^[:alpha:]]','','g'))<2 or (pair->>'word') ~ '(.)\1{4}' or
 (d->>'mode'='advanced' and (coalesce(length(pair->>'spyWord'),0) not between 2 and 40 or length(regexp_replace(coalesce(pair->>'spyWord',''),'[^[:alpha:]]','','g'))<2 or (pair->>'spyWord') ~ '(.)\1{4}' or jasoos_private.norm(pair->>'word')=jasoos_private.norm(pair->>'spyWord'))) then raise exception 'INVALID_CUSTOM_WORDS'; end if;
 end loop;
 if jsonb_array_length(d->'categories')=0 and jsonb_array_length(custom)=0 then raise exception 'NO_WORDS'; end if;
 return jsonb_build_object('capacity',n,'spies',s,'seconds',seconds,'mode',d->>'mode','lang',d->>'lang','voting',(d->>'voting')::boolean,'hints',(d->>'hints')::boolean,'categories',d->'categories','custom',custom);
end $$;

-- Projection explicitly whitelists public fields. Advanced cards have no role flag.
create or replace function jasoos_private.snapshot(rid uuid, who uuid) returns jsonb
language plpgsql set search_path='' as $$
declare r jasoos_private.rooms; me jasoos_private.players; sec jasoos_private.secrets; out jsonb; card text; members jsonb; picks uuid[];
begin
 select * into r from jasoos_private.rooms where id=rid;
 select * into me from jasoos_private.players where room_id=rid and uid=who and active;
 if me.id is null then raise exception 'NOT_A_MEMBER'; end if;
 select * into sec from jasoos_private.secrets where round_id=(r.state->>'round_id')::uuid;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'host',p.uid=r.host,'ready',p.ready,'connected',p.last_seen>clock_timestamp()-interval '15 seconds','voted',exists(select 1 from jasoos_private.ballots b where b.round_id=sec.round_id and b.runoff=coalesce((r.state->>'runoff')::int,0) and b.voter=p.id)) order by p.seat),'[]') into members from jasoos_private.players p where p.room_id=rid and p.active;
 if r.state->>'stage' in ('DEALING','PLAYING') then
 card:=case when me.id=any(sec.spies) then case when r.settings->>'mode'='advanced' then sec.spy_word when r.settings->>'lang'='en' then 'You are a spy!' else 'تو جاسوسی!' end else sec.ordinary_word end;
 end if;
 select b.picks into picks from jasoos_private.ballots b where b.round_id=sec.round_id and b.runoff=coalesce((r.state->>'runoff')::int,0) and b.voter=me.id;
 out:=jsonb_build_object('room_id',r.id,'title',r.title,'alias',r.alias,'version',r.version,'closed',r.closed,'join_open',r.join_open,'is_host',r.host=who,'me',me.id,'settings',r.settings-'custom','state',r.state,'players',members,'my_card',card,'my_ballot',to_jsonb(coalesce(picks,'{}'::uuid[])),'can_guess',r.state->>'stage'='GUESSING' and me.id=any(sec.spies),'server_now',clock_timestamp());
 if r.state->>'stage' in ('CAUGHT','GUESSING','JUDGING','RESULT') then out:=out||jsonb_build_object('spies',sec.spies); end if;
 if r.state->>'stage' in ('JUDGING','RESULT') then out:=out||jsonb_build_object('ordinary_word',sec.ordinary_word,'spy_word',sec.spy_word); end if;
 return out;
end $$;
revoke all on all functions in schema jasoos_private from public,anon,authenticated;
commit;
