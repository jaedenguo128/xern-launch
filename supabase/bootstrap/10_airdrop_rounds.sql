create table xern_private.airdrop_rounds (
  owner_id uuid references public.profiles on delete cascade,
  game text not null,
  id uuid not null default gen_random_uuid(),
  started_at timestamptz not null default clock_timestamp(),
  state jsonb not null default '{}'::jsonb,
  result jsonb,
  primary key(owner_id,game)
);
alter table xern_private.airdrop_rounds enable row level security;
revoke all on xern_private.airdrop_rounds from public,anon,authenticated;

create function xern_private.airdrop_round(p_game text,p_action text,p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=xern_private.player(); r xern_private.airdrop_rounds; c public.airdrop_claims; rules record;
  today date:=(clock_timestamp() at time zone 'America/New_York')::date;
  used integer; reward integer:=0; wallet bigint; outcome jsonb; data jsonb; choice integer;
  symbols integer[]; board integer[]; opened integer[]; matched integer[]; path integer[]; slot integer;
  hits integer; tries integer; elapsed numeric; wait_ms integer; reaction_ms integer;
begin
  if p_input is null or jsonb_typeof(p_input)<>'object' then return xern_private.fail('Invalid round input'); end if;
  select * into rules from (values ('case',3600,100),('deck',2700,100),('spin',1800,100),
    ('bounce',60,3),('target',45,3),('reaction',45,3)) v(game,seconds,quota) where game=p_game;
  if not found then return xern_private.fail('Unknown airdrop game'); end if;
  perform 1 from public.profiles where id=uid for update;
  select * into r from xern_private.airdrop_rounds where owner_id=uid and game=p_game for update;
  select * into c from public.airdrop_claims where owner_id=uid and game=p_game;
  used:=case when c.day_utc=today then c.plays_today else 0 end;
  if p_action='status' then
    if r.id is null then return jsonb_build_object('ok',true,'active',false); end if;
    if r.result is not null then return r.result; end if;
    if r.started_at<clock_timestamp()-interval '10 minutes' then
      return jsonb_build_object('ok',true,'active',false,'round_id',r.id,'expired',true);
    end if;
    return jsonb_build_object('ok',true,'active',true,'round_id',r.id,'state',r.state-'board',
      'next_at',c.last_claim_at+make_interval(secs=>rules.seconds),'plays_today',used);
  end if;
  if p_action='start' then
    if r.id is not null and r.result is null and r.started_at>clock_timestamp()-interval '10 minutes' then
      return jsonb_build_object('ok',true,'active',true,'round_id',r.id,'state',r.state-'board',
        'next_at',c.last_claim_at+make_interval(secs=>rules.seconds),'plays_today',used);
    end if;
    if used>=rules.quota or c.last_claim_at+make_interval(secs=>rules.seconds)>clock_timestamp() then
      return xern_private.fail('Next play is on cooldown')||jsonb_build_object('plays_today',used,
        'next_at',c.last_claim_at+make_interval(secs=>rules.seconds));
    end if;
    data:=jsonb_build_object('hits',0);
    if p_game='deck' then
      select array_agg(value order by random()) into board from unnest(array[0,0,1,1,2,2]) value;
      data:=jsonb_build_object('board',board,'opened','[]'::jsonb,'matched','[]'::jsonb,'tries',0,'revealed','{}'::jsonb);
    elsif p_game='reaction' then data:=jsonb_build_object('wait_ms',1200+floor(random()*1800)::integer);
    elsif p_game='bounce' then
      if coalesce(p_input->>'lane','') !~ '^[0-4]$' then return xern_private.fail('Choose a lane'); end if;
      slot:=(p_input->>'lane')::integer; path:=array[slot];
      for hits in 1..4 loop slot:=greatest(0,least(4,slot+case when random()<.5 then -1 else 1 end)); path:=array_append(path,slot); end loop;
      reward:=(array[10,20,50,20,10])[slot+1];
      outcome:=jsonb_build_object('slot',slot,'path',path);
    elsif p_game='spin' then
      symbols:=array[floor(random()*6)::integer,floor(random()*6)::integer,floor(random()*6)::integer];
      reward:=case when symbols[1]=symbols[2] and symbols[2]=symbols[3] then 350
        when symbols[1]=symbols[2] or symbols[1]=symbols[3] or symbols[2]=symbols[3] then 100 else 35 end;
      outcome:=jsonb_build_object('symbols',symbols);
    end if;
    insert into public.airdrop_claims values(uid,p_game,clock_timestamp(),used+1,today)
      on conflict(owner_id,game) do update set last_claim_at=excluded.last_claim_at,plays_today=excluded.plays_today,day_utc=excluded.day_utc;
    insert into xern_private.airdrop_rounds(owner_id,game,state) values(uid,p_game,data)
      on conflict(owner_id,game) do update set id=gen_random_uuid(),started_at=clock_timestamp(),state=excluded.state,result=null
      returning * into r;
    used:=used+1;
    if reward=0 then
      return jsonb_build_object('ok',true,'active',true,'round_id',r.id,'state',data-'board',
        'next_at',clock_timestamp()+make_interval(secs=>rules.seconds),'plays_today',used);
    end if;
  else
    if r.id is null or p_input->>'round_id' is distinct from r.id::text then return xern_private.fail('This round is no longer active'); end if;
    if r.result is not null then return r.result; end if;
    if r.started_at<clock_timestamp()-interval '10 minutes' then return xern_private.fail('Round expired. Start again.'); end if;
    elapsed:=extract(epoch from clock_timestamp()-r.started_at);
    data:=r.state;
    if p_game in ('case','target') and p_action='hit' then
      if data ? 'last_hit' and extract(epoch from clock_timestamp()-(data->>'last_hit')::timestamptz)<.12 then
        return xern_private.fail('Wait for the next hit');
      end if;
      hits:=(data->>'hits')::integer+1;
      data:=data||jsonb_build_object('hits',hits,'last_hit',clock_timestamp());
      if hits<5 then
        update xern_private.airdrop_rounds set state=data where owner_id=uid and game=p_game;
        return jsonb_build_object('ok',true,'active',true,'round_id',r.id,'state',data);
      end if;
      reward:=case when p_game='case' then case when elapsed<=8 then 350 when elapsed<=15 then 200 else 80 end
        else case when elapsed<=10 then 50 when elapsed<=20 then 30 else 10 end end;
      outcome:=jsonb_build_object('seconds',round(elapsed,1),'hits',hits);
    elsif p_game='reaction' and p_action='finish' then
      if coalesce(p_input->>'milliseconds','') !~ '^[0-9]{1,6}$' then return xern_private.fail('Invalid reaction time'); end if;
      reaction_ms:=(p_input->>'milliseconds')::integer;
      wait_ms:=(data->>'wait_ms')::integer;
      if reaction_ms<80 or elapsed*1000<wait_ms+reaction_ms-100 then return xern_private.fail('Wait for green before tapping'); end if;
      reward:=case when reaction_ms<=250 then 60 when reaction_ms<=400 then 40 when reaction_ms<=700 then 25 else 10 end;
      outcome:=jsonb_build_object('milliseconds',reaction_ms);
    elsif p_game='deck' and p_action='pick' then
      if coalesce(p_input->>'card','') !~ '^[0-5]$' then return xern_private.fail('Choose a card'); end if;
      choice:=(p_input->>'card')::integer;
      select coalesce(array_agg(value::integer),'{}') into opened from jsonb_array_elements_text(data->'opened');
      select coalesce(array_agg(value::integer),'{}') into matched from jsonb_array_elements_text(data->'matched');
      if choice=any(matched) then return xern_private.fail('That pair is already matched'); end if;
      if cardinality(opened)=2 then opened:='{}'; end if;
      if choice=any(opened) then return xern_private.fail('Choose another card'); end if;
      opened:=array_append(opened,choice);
      tries:=(data->>'tries')::integer;
      data:=jsonb_set(data,array['revealed',choice::text],data->'board'->choice,true);
      if cardinality(opened)=2 then
        tries:=tries+1;
        if data->'board'->opened[1]=data->'board'->opened[2] then matched:=matched||opened; end if;
      end if;
      data:=data||jsonb_build_object('opened',opened,'matched',matched,'tries',tries);
      update xern_private.airdrop_rounds set state=data where owner_id=uid and game=p_game;
      if cardinality(matched)<6 and tries<6 then
        return jsonb_build_object('ok',true,'active',true,'round_id',r.id,'state',data-'board');
      end if;
      reward:=25+40*(cardinality(matched)/2)+case when cardinality(matched)=6 and tries=3 then 100 else 0 end;
      outcome:=jsonb_build_object('pairs',cardinality(matched)/2,'tries',tries,'board',data->'board','state',data-'board');
    else return xern_private.fail('Invalid round action');
    end if;
  end if;
  update public.profiles set money=money+reward where id=uid returning money into wallet;
  outcome:=coalesce(outcome,'{}')||jsonb_build_object('ok',true,'active',false,'round_id',r.id,'reward',reward,'money',wallet,
    'next_at',(select last_claim_at from public.airdrop_claims where owner_id=uid and game=p_game)+make_interval(secs=>rules.seconds),'plays_today',used);
  update xern_private.airdrop_rounds set result=outcome where owner_id=uid and game=p_game;
  return outcome;
end
$$;
revoke all on function xern_private.airdrop_round(text,text,jsonb) from public,anon,authenticated;
grant execute on function xern_private.airdrop_round(text,text,jsonb) to authenticated;
create function public.airdrop_round(p_game text,p_action text,p_input jsonb default '{}'::jsonb)
returns jsonb language sql set search_path='' as $$select xern_private.airdrop_round(p_game,p_action,p_input)$$;
revoke all on function public.airdrop_round(text,text,jsonb) from public,anon;
grant execute on function public.airdrop_round(text,text,jsonb) to authenticated;
-- Old clients can resume using the updated page, preventing the legacy random reward bypass.
create or replace function xern_private.airdrop_play(p_game text) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); previous public.airdrop_claims; rules record;
  today date:=(now() at time zone 'America/New_York')::date; used integer; reward integer; wait interval;
begin
  if p_game is null or p_game not in ('tap','stack') then return xern_private.fail('Reload Xern to play the updated airdrop games'); end if;
  select * into rules from (values ('case',3600,100,80,350),('tap',5,25,1,5),('deck',2700,100,25,150),
    ('spin',1800,100,35,185),('stack',480,100,15,60),('bounce',60,3,10,30),
    ('target',45,3,8,25),('reaction',45,3,10,30)) r(game,seconds,quota,low,high) where game=p_game;
  if not found then return xern_private.fail('Unknown airdrop game'); end if;
  wait:=make_interval(secs=>rules.seconds);
  perform 1 from public.profiles where id=uid for update;
  select * into previous from public.airdrop_claims where owner_id=uid and game=p_game;
  used:=case when previous.day_utc=today then previous.plays_today else 0 end;
  if used>=rules.quota or previous.last_claim_at+wait>now() then
    return xern_private.fail('Next reward is on cooldown')||jsonb_build_object('next_at',previous.last_claim_at+wait,'plays_today',used);
  end if;
  reward:=rules.low+floor(random()*(rules.high-rules.low+1))::integer;
  insert into public.airdrop_claims values(uid,p_game,now(),used+1,today)
  on conflict(owner_id,game) do update set last_claim_at=excluded.last_claim_at,plays_today=excluded.plays_today,day_utc=excluded.day_utc;
  update public.profiles set money=money+reward where id=uid;
  return jsonb_build_object('ok',true,'reward',reward,'next_at',now()+wait,'plays_today',used+1);
end
$$;
notify pgrst,'reload schema';
