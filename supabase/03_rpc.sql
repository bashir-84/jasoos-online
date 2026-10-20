begin;
create or replace function public.jasoos_api(
 p_action text, p_room uuid default null, p_data jsonb default '{}',
 p_version bigint default null, p_request uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
<<api>>
declare
 uid uuid:=auth.uid(); r jasoos_private.rooms; me jasoos_private.players;
 sec jasoos_private.secrets; limits jasoos_private.rate_limits;
 d jsonb; st jsonb; settings jsonb; out jsonb; v_title text; v_name text; v_alias text; invite text;
 phase text; n int; s int; h int; c int; slots int; runoff int; total int; threshold int;
 member_ids uuid[]; spy_ids uuid[]; safe uuid[]; candidates uuid[]; fixed uuid[]; tied uuid[]; selected uuid[];
 picks uuid[]; word_key text; word1 text; word2 text; tmp text; remaining numeric; now_at timestamptz:=clock_timestamp();
 rec record; host_seen timestamptz; new_host uuid; request_token uuid:=coalesce(p_request,gen_random_uuid());
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_action='create' then
  insert into jasoos_private.rate_limits(uid,window_start,calls) values(uid,now_at,0) on conflict do nothing;
  select * into limits from jasoos_private.rate_limits where rate_limits.uid=uid for update;
  if limits.create_window<now_at-interval '10 minutes' then limits.creates:=0; limits.create_window:=now_at; end if;
  if limits.creates>=10 then return jsonb_build_object('error','CREATE_RATE_LIMIT'); end if;
  select * into r from jasoos_private.rooms where host=uid and request_id=request_token;
  if r.id is not null then return jasoos_private.snapshot(r.id,uid); end if;
  settings:=jasoos_private.validate_settings(p_data->'settings');
  v_name:=jasoos_private.clean(p_data->>'name'); v_title:=jasoos_private.clean(p_data->>'title');
  v_alias:=jasoos_private.norm(p_data->>'alias');
  if length(v_name) not between 1 and 40 or length(v_title) not between 1 and 60 then raise exception 'INVALID_NAME_OR_TITLE'; end if;
  if v_alias='' then loop v_alias:=lpad((floor(random()*900000)+100000)::text,6,'0');exit when not exists(select 1 from jasoos_private.rooms where alias=v_alias and not closed);end loop;end if;
  if length(v_alias) not between 4 and 40 or v_alias !~ '^[[:alnum:]_-]+$' then raise exception 'INVALID_ROOM_CODE'; end if;
  if exists(select 1 from jasoos_private.rooms where alias=v_alias and not closed) then raise exception 'ROOM_CODE_TAKEN'; end if;
  invite:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into jasoos_private.rooms(alias,title,host,invite_hash,settings,request_id) values(v_alias,v_title,uid,encode(sha256(convert_to(invite,'UTF8')),'hex'),settings,request_token) returning * into r;
  insert into jasoos_private.players(room_id,uid,name,name_key) values(r.id,uid,v_name,jasoos_private.norm(v_name));
  update jasoos_private.rate_limits set creates=limits.creates+1,create_window=limits.create_window where rate_limits.uid=uid;
  return jasoos_private.snapshot(r.id,uid)||jsonb_build_object('invite_token',invite);
 elsif p_action='join' then
  -- Return rate failures rather than raising: the counter must commit on failure.
  insert into jasoos_private.rate_limits(uid,window_start,calls) values(uid,now_at,0) on conflict do nothing;
  select * into limits from jasoos_private.rate_limits where rate_limits.uid=uid for update;
  if limits.window_start<now_at-interval '15 minutes' then limits.calls:=0;limits.window_start:=now_at;end if;
  if limits.calls>=5 then return jsonb_build_object('error','JOIN_RATE_LIMIT');end if;
  update jasoos_private.rate_limits set calls=limits.calls+1,window_start=limits.window_start where rate_limits.uid=uid;
  if coalesce(p_data->>'invite','')<>'' then
   select * into r from jasoos_private.rooms where invite_hash=encode(sha256(convert_to(p_data->>'invite','UTF8')),'hex') and not closed for update;
  else
   select * into r from jasoos_private.rooms where alias=jasoos_private.norm(p_data->>'code') and not closed for update;
  end if;
  if r.id is null then return jsonb_build_object('error','ROOM_NOT_FOUND');end if;
  select * into me from jasoos_private.players where room_id=r.id and players.uid=uid;
  if me.active then return jasoos_private.snapshot(r.id,uid);end if;
  if r.state->>'stage'<>'LOBBY' or not r.join_open then return jsonb_build_object('error','ROOM_LOCKED');end if;
  if (select count(*) from jasoos_private.players where room_id=r.id and active)>=(r.settings->>'capacity')::int then return jsonb_build_object('error','ROOM_FULL');end if;
  v_name:=jasoos_private.clean(p_data->>'name');
  if length(v_name) not between 1 and 40 then return jsonb_build_object('error','INVALID_NAME');end if;
  if exists(select 1 from jasoos_private.players where room_id=r.id and name_key=jasoos_private.norm(v_name) and active) then return jsonb_build_object('error','DUPLICATE_NAME');end if;
  insert into jasoos_private.players(room_id,uid,name,name_key) values(r.id,uid,v_name,jasoos_private.norm(v_name)) on conflict on constraint players_room_id_uid_key do update set active=true,ready=false,name=excluded.name,name_key=excluded.name_key,last_seen=now_at;
  update jasoos_private.rooms set version=version+1,updated_at=now_at where id=r.id;
  update jasoos_private.rate_limits set calls=0 where rate_limits.uid=uid;
  return jasoos_private.snapshot(r.id,uid);
 end if;

 select * into r from jasoos_private.rooms where id=p_room for update;
 if r.id is null then raise exception 'ROOM_NOT_FOUND';end if;
 select * into me from jasoos_private.players where room_id=r.id and players.uid=uid and active;
 if me.id is null then raise exception 'NOT_A_MEMBER';end if;
 update jasoos_private.players set last_seen=now_at where id=me.id;
 st:=r.state;phase:=st->>'stage';settings:=r.settings;
 select * into sec from jasoos_private.secrets where round_id=(st->>'round_id')::uuid;
 -- Any authenticated member may reconcile deadlines, never the browser itself.
 if phase='PLAYING' and not (st->>'paused')::boolean and (st->>'deadline')::timestamptz<=now_at then
  if (settings->>'voting')::boolean then
   select array_agg(x) into candidates from unnest(sec.members) x where not x=any(coalesce(array(select jsonb_array_elements_text(st->'safe')::uuid),'{}'::uuid[]));
   st:=st||jsonb_build_object('stage','VOTING','candidates',candidates,'slots',(settings->>'spies')::int,'runoff',0,'fixed','[]'::jsonb);
  else st:=st||jsonb_build_object('stage','RESULT','winner','spies','reason','TIME_EXPIRED');end if;
 elsif phase='GUESSING' and (st->>'guess_deadline')::timestamptz<=now_at then
  st:=st||jsonb_build_object('stage','RESULT','winner','ordinary','reason','NO_GUESS');
 end if;
 if st is distinct from r.state then
  update jasoos_private.rooms set state=st,version=version+1,updated_at=now_at where id=r.id returning * into r;
  if p_action<>'snapshot' then return jasoos_private.snapshot(r.id,uid)||jsonb_build_object('transitioned',true);end if;
 end if;
 phase:=st->>'stage';
 -- Host handoff uses server-maintained heartbeats, oldest connected seat.
 if p_action='snapshot' and not r.closed then
  select last_seen into host_seen from jasoos_private.players where room_id=r.id and players.uid=r.host and active;
  if host_seen<now_at-interval '60 seconds' or host_seen is null then
   select players.uid into new_host from jasoos_private.players where room_id=r.id and active and last_seen>now_at-interval '15 seconds' order by seat limit 1;
   if new_host is not null and new_host<>r.host then update jasoos_private.rooms set host=new_host,version=version+1,updated_at=now_at where id=r.id returning * into r;end if;
  end if;
  if (phase='LOBBY' and r.updated_at<now_at-interval '24 hours') or (phase in ('RESULT','CANCELLED') and r.updated_at<now_at-interval '2 hours') then
   update jasoos_private.rooms set closed=true,state='{"stage":"CLOSED"}',version=version+1 where id=r.id;
  end if;
 end if;
 if p_action='snapshot' then return jasoos_private.snapshot(r.id,uid);end if;
 if r.closed then raise exception 'ROOM_CLOSED';end if;
 if p_version is distinct from r.version then return jasoos_private.snapshot(r.id,uid)||jsonb_build_object('stale',true);end if;
 if p_action not in ('ready','vote','guess','leave') and r.host<>uid then raise exception 'HOST_ONLY';end if;

 if p_action='settings' then
  if phase<>'LOBBY' then raise exception 'WRONG_STAGE';end if;
  d:=p_data->'settings';
  if coalesce((d->>'preserve_custom')::boolean,false) then d:=d||jsonb_build_object('custom',r.settings->'custom');end if;
  settings:=jasoos_private.validate_settings(d);
  if (settings->>'capacity')::int<(select count(*) from jasoos_private.players where room_id=r.id and active) then raise exception 'CAPACITY_BELOW_MEMBERS';end if;
  update jasoos_private.rooms set settings=api.settings where id=r.id;
 elsif p_action='deal' then
  if phase<>'LOBBY' then raise exception 'WRONG_STAGE';end if;
  n:=(settings->>'capacity')::int;s:=(settings->>'spies')::int;
  select array_agg(id order by seat) into member_ids from jasoos_private.players where room_id=r.id and active;
  if cardinality(member_ids)<>n then raise exception 'WAIT_FOR_MEMBERS';end if;
  select array_agg(id) into spy_ids from (select x as id from unnest(member_ids) x order by gen_random_uuid() limit s) q;
  with raw_pool as (
   select w.word,w.spy_word from jasoos_private.words w where w.lang=settings->>'lang' and (settings->'categories') ? w.category and ((settings->>'mode'='simple' and w.spy_word is null) or (settings->>'mode'='advanced' and w.spy_word is not null))
   union all select x->>'word',x->>'spyWord' from jsonb_array_elements(settings->'custom') x
  ), keyed as (
   select case when settings->>'mode'='simple' then 'word:'||jasoos_private.norm(word) else 'pair:'||least(jasoos_private.norm(word),jasoos_private.norm(spy_word))||'|'||greatest(jasoos_private.norm(word),jasoos_private.norm(spy_word)) end as key,word,spy_word from raw_pool
  ), pool as (select distinct on (key) * from keyed)
  select q.key,q.word,q.spy_word into word_key,word1,word2 from pool q left join jasoos_private.history h on h.room_id=r.id and h.word_key=q.key order by (h.used_at is null) desc,h.used_at asc,gen_random_uuid() limit 1;
  if word1 is null or (settings->>'mode'='advanced' and word2 is null) then raise exception 'NO_WORDS';end if;
  if settings->>'mode'='advanced' and random()<0.5 then tmp:=word1;word1:=word2;word2:=tmp;end if;
  invite:=gen_random_uuid()::text;
  insert into jasoos_private.secrets(round_id,room_id,ordinary_word,spy_word,spies,members) values(invite::uuid,r.id,word1,word2,spy_ids,member_ids);
  insert into jasoos_private.history(room_id,word_key) values(r.id,word_key) on conflict on constraint history_pkey do update set used_at=now_at;
  update jasoos_private.players set ready=false where room_id=r.id;
  st:=jsonb_build_object('stage','DEALING','round_id',invite,'safe','[]'::jsonb,'hint_used',false,'paused',true,'remaining',(settings->>'seconds')::numeric,'runoff',0);
 elsif p_action='ready' then
  if phase<>'DEALING' then raise exception 'WRONG_STAGE';end if;
  update jasoos_private.players set ready=coalesce((p_data->>'ready')::boolean,true) where id=me.id;
 elsif p_action='start' then
  if phase<>'DEALING' then raise exception 'WRONG_STAGE';end if;
  if exists(select 1 from jasoos_private.players where room_id=r.id and active and not ready) then raise exception 'WAIT_FOR_READY';end if;
  st:=st||jsonb_build_object('stage','PLAYING','paused',false,'deadline',now_at+make_interval(secs=>(settings->>'seconds')::int));
 elsif p_action in ('pause','resume','hint','early','accuse') then
  if phase<>'PLAYING' then raise exception 'WRONG_STAGE';end if;
  remaining:=case when (st->>'paused')::boolean then (st->>'remaining')::numeric else greatest(0,extract(epoch from (st->>'deadline')::timestamptz-now_at)) end;
  if p_action='pause' then
   if (st->>'paused')::boolean then raise exception 'ALREADY_PAUSED';end if;
   st:=st||jsonb_build_object('paused',true,'remaining',remaining,'deadline',null);
  elsif p_action='resume' then
   if not (st->>'paused')::boolean then raise exception 'NOT_PAUSED';end if;
   st:=st||jsonb_build_object('paused',false,'deadline',now_at+make_interval(secs=>remaining::double precision));
  elsif p_action='hint' then
   h:=(p_data->>'count')::int;n:=cardinality(sec.members);s:=cardinality(sec.spies);c:=n-s;
   if not (settings->>'hints')::boolean or (st->>'hint_used')::boolean or (st->>'paused')::boolean or remaining<=9 or h is null or h<1 or h>c-(case when settings->>'mode'='advanced' then 1 else 2 end) then raise exception 'INVALID_HINT';end if;
   select array_agg(id) into safe from (select x as id from unnest(sec.members) x where not x=any(sec.spies) order by gen_random_uuid() limit h) q;
   remaining:=case when settings->>'mode'='advanced' and c-h=1 then 9 else greatest(9,remaining*(c-h)/c) end;
   st:=st||jsonb_build_object('hint_used',true,'safe',safe,'deadline',now_at+make_interval(secs=>remaining::double precision));
  elsif p_action='early' then
   if not (settings->>'voting')::boolean then raise exception 'VOTING_DISABLED';end if;
   select array_agg(x) into candidates from unnest(sec.members) x where not x=any(array(select jsonb_array_elements_text(st->'safe')::uuid));
   st:=st||jsonb_build_object('stage','VOTING','candidates',candidates,'slots',cardinality(sec.spies),'runoff',0,'fixed','[]'::jsonb);
  elsif p_action='accuse' then
   if (settings->>'voting')::boolean or (st->>'paused')::boolean then raise exception 'INVALID_ACCUSATION';end if;
   picks:=array(select jsonb_array_elements_text(p_data->'picks')::uuid);
   if cardinality(picks)<>cardinality(sec.spies) or cardinality(picks)<>(select count(distinct x) from unnest(picks)x) or not picks<@sec.members or picks&&array(select jsonb_array_elements_text(st->'safe')::uuid) then raise exception 'INVALID_SELECTION';end if;
   if picks@>sec.spies then st:=st||jsonb_build_object('stage','CAUGHT');else st:=st||jsonb_build_object('stage','RESULT','winner','spies','reason','WRONG_ACCUSATION');end if;
  end if;
 elsif p_action='vote' then
  if phase not in ('VOTING','RUNOFF_VOTING') then raise exception 'WRONG_STAGE';end if;
  picks:=array(select jsonb_array_elements_text(p_data->'picks')::uuid); candidates:=array(select jsonb_array_elements_text(st->'candidates')::uuid);slots:=(st->>'slots')::int;
  if cardinality(picks)<>slots or cardinality(picks)<>(select count(distinct x) from unnest(picks)x) or me.id=any(picks) or not picks<@candidates then raise exception 'INVALID_BALLOT';end if;
  insert into jasoos_private.ballots values(sec.round_id,(st->>'runoff')::int,me.id,picks) on conflict on constraint ballots_pkey do update set picks=excluded.picks;
 elsif p_action='lock_votes' then
  if phase not in ('VOTING','RUNOFF_VOTING') then raise exception 'WRONG_STAGE';end if;
  runoff:=(st->>'runoff')::int;slots:=(st->>'slots')::int;
  if (select count(*) from jasoos_private.ballots where round_id=sec.round_id and ballots.runoff=api.runoff)<>cardinality(sec.members) then raise exception 'WAIT_FOR_VOTES';end if;
  candidates:=array(select jsonb_array_elements_text(st->'candidates')::uuid); fixed:=array(select jsonb_array_elements_text(st->'fixed')::uuid);
  with counts as (select x as id,(select count(*) from jasoos_private.ballots b where b.round_id=sec.round_id and b.runoff=api.runoff and x=any(b.picks)) as votes from unnest(candidates)x)
  select votes into threshold from counts order by votes desc limit 1 offset slots-1;
  select coalesce(array_agg(x),'{}'::uuid[]) into selected from unnest(candidates)x where (select count(*) from jasoos_private.ballots b where b.round_id=sec.round_id and b.runoff=api.runoff and x=any(b.picks))>threshold;
  select coalesce(array_agg(x),'{}'::uuid[]) into tied from unnest(candidates)x where (select count(*) from jasoos_private.ballots b where b.round_id=sec.round_id and b.runoff=api.runoff and x=any(b.picks))=threshold;
  if cardinality(tied)>slots-cardinality(selected) then
   if runoff=1 then st:=st||jsonb_build_object('stage','RESULT','winner','spies','reason','TIE');
   else st:=st||jsonb_build_object('stage','RUNOFF_WAIT','candidates',tied,'fixed',fixed||selected,'slots',slots-cardinality(selected),'runoff',1);end if;
  else
   selected:=fixed||selected||tied;
   if selected@>sec.spies and cardinality(selected)=cardinality(sec.spies) then st:=st||jsonb_build_object('stage','CAUGHT');else st:=st||jsonb_build_object('stage','RESULT','winner','spies','reason','WRONG_ACCUSATION');end if;
  end if;
 elsif p_action='runoff' then
  if phase<>'RUNOFF_WAIT' then raise exception 'WRONG_STAGE';end if;
  st:=st||jsonb_build_object('stage','RUNOFF_VOTING');
 elsif p_action='start_guess' then
  if phase<>'CAUGHT' then raise exception 'WRONG_STAGE';end if;
  st:=st||jsonb_build_object('stage','GUESSING','guess_deadline',now_at+interval '15 seconds');
 elsif p_action='guess' then
  if phase<>'GUESSING' or not me.id=any(sec.spies) then raise exception 'SPY_ONLY';end if;
  tmp:=jasoos_private.clean(p_data->>'guess');if length(tmp) not between 1 and 80 then raise exception 'INVALID_GUESS';end if;
  st:=st||jsonb_build_object('stage','JUDGING','guess',tmp,'guessed_by',me.id);
 elsif p_action='judge' then
  if phase<>'JUDGING' or jsonb_typeof(p_data->'correct') is distinct from 'boolean' then raise exception 'WRONG_STAGE';end if;
  st:=st||jsonb_build_object('stage','RESULT','winner',case when (p_data->>'correct')::boolean then 'spies' else 'ordinary' end,'reason',case when (p_data->>'correct')::boolean then 'CORRECT_GUESS' else 'WRONG_GUESS' end);
 elsif p_action='cancel' then
  if phase in ('LOBBY','RESULT','CANCELLED','CLOSED') or p_data->>'confirm' is distinct from 'CANCEL' then raise exception 'CONFIRM_CANCEL';end if;
  st:=jsonb_build_object('stage','CANCELLED','round_id',st->>'round_id');
 elsif p_action='next' then
  if phase not in ('RESULT','CANCELLED') then raise exception 'WRONG_STAGE';end if;
  delete from jasoos_private.secrets where room_id=r.id;
  update jasoos_private.players set ready=false where room_id=r.id;
  st:='{"stage":"LOBBY"}';
 elsif p_action in ('kick','leave','transfer','toggle_join','close') then
  if phase not in ('LOBBY','RESULT','CANCELLED') then raise exception 'CANNOT_LEAVE_ACTIVE_ROUND';end if;
  if p_action='kick' then
   if phase<>'LOBBY' or (p_data->>'player')::uuid=me.id then raise exception 'INVALID_SELECTION';end if;
   update jasoos_private.players set active=false where room_id=r.id and id=(p_data->>'player')::uuid;
  elsif p_action='leave' then
   if r.host=uid then raise exception 'TRANSFER_HOST_FIRST';end if;
   update jasoos_private.players set active=false where id=me.id;
   update jasoos_private.rooms set version=version+1,updated_at=now_at where id=r.id;
   return jsonb_build_object('left',true,'server_now',now_at);
  elsif p_action='transfer' then
   if phase<>'LOBBY' then raise exception 'WRONG_STAGE';end if;
   select players.uid into new_host from jasoos_private.players where id=(p_data->>'player')::uuid and room_id=r.id and active;
   if new_host is null then raise exception 'NOT_A_MEMBER';end if;
   update jasoos_private.rooms set host=new_host where id=r.id;
  elsif p_action='toggle_join' then update jasoos_private.rooms set join_open=not join_open where id=r.id;
  elsif p_action='close' then st:='{"stage":"CLOSED"}';update jasoos_private.rooms set closed=true where id=r.id;
  end if;
 else raise exception 'UNKNOWN_ACTION';end if;
 update jasoos_private.rooms set state=st,version=version+1,updated_at=now_at where id=r.id;
 return jasoos_private.snapshot(r.id,uid);
end $$;
revoke all on function public.jasoos_api(text,uuid,jsonb,bigint,uuid) from public,anon;
grant execute on function public.jasoos_api(text,uuid,jsonb,bigint,uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
