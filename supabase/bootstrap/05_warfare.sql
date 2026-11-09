create function xern_private.weekend() returns boolean language sql stable set search_path='' as $$
  select extract(isodow from now() at time zone 'America/New_York') in (6,7)
$$;
create function xern_private.allied(a uuid,b uuid) returns boolean language sql stable set search_path='' as $$
  select a=b or (not xern_private.weekend() and exists(
    select 1 from public.xern_clan_members m join public.xern_clan_members n using(clan_id) where m.user_id=a and n.user_id=b))
$$;
create function xern_private.order_unit(uid uuid,p_unit_id bigint,command text,target text default null)
returns jsonb language plpgsql set search_path='' as $$
declare unit public.team_units; origin text; home text; move_mode text:=command; moving boolean:=true;
begin
  perform pg_advisory_xact_lock(18002);
  select * into unit from public.team_units where id=p_unit_id and owner_id=uid;
  if not found or unit.stationed_plot_key is null or xern_private.sales_active(uid) then return xern_private.fail('Station your troop first'); end if;
  home:=xern_private.home_plot(uid);
  if home is null then return xern_private.fail('You do not own land'); end if;
  select current_plot_key into origin from public.warfare_marches where unit_id=unit.id;
  origin:=coalesce(origin,unit.stationed_plot_key);
  case command
    when 'hold' then moving:=false;
    when 'explore' then target:=null;
    when 'rally' then
      if not xern_private.safe_plot(target) then return xern_private.fail('Choose a land plot for your rally'); end if;
      move_mode:='march';
    when 'recall' then target:=home;
    when 'dismiss' then
      -- Keep one unlocked copy, but remove it from the map when it is the last.
      if unit.unit_count>1 then update public.team_units set unit_count=unit_count-1 where id=unit.id;
      else
        update public.team_units set stationed_plot_key=null where id=unit.id;
        delete from public.warfare_marches where unit_id=unit.id;
      end if;
      return xern_private.ok();
    else return xern_private.fail('Unknown command');
  end case;
  insert into public.warfare_marches(unit_id,owner_id,current_plot_key,target_plot_key,active,mode)
  values(unit.id,uid,origin,target,moving,move_mode)
  on conflict(unit_id) do update set target_plot_key=excluded.target_plot_key,active=excluded.active,mode=excluded.mode,last_step_at=now();
  return xern_private.ok();
end
$$;
create function xern_private.warfare_set_explore(p_unit_id bigint) returns jsonb language sql set search_path='' as $$
  select xern_private.order_unit(xern_private.player(),p_unit_id,'explore')
$$;
create function xern_private.warfare_set_march(p_unit_id bigint,p_target_plot_key text) returns jsonb language sql set search_path='' as $$
  select xern_private.order_unit(xern_private.player(),p_unit_id,'rally',p_target_plot_key)
$$;
create function xern_private.warfare_command(p_unit_id bigint,p_command text) returns jsonb language sql set search_path='' as $$
  select xern_private.order_unit(xern_private.player(),p_unit_id,p_command)
$$;
create function xern_private.warfare_set_colony_rally(p_target_plot_key text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); unit public.team_units; troops integer:=0;
begin
  if not xern_private.safe_plot(p_target_plot_key) then return xern_private.fail('Choose a land plot for your rally'); end if;
  perform pg_advisory_xact_lock(18002);
  for unit in select * from public.team_units where owner_id=uid and stationed_plot_key is not null loop
    if (xern_private.order_unit(uid,unit.id,'rally',p_target_plot_key)->>'ok')::boolean then troops:=troops+unit.unit_count; end if;
  end loop;
  if troops=0 then return xern_private.fail('No stationed troops'); end if;
  insert into public.warfare_rally_orders values(uid,p_target_plot_key,now())
  on conflict(owner_id) do update set target_plot_key=excluded.target_plot_key,updated_at=now();
  return jsonb_build_object('ok',true,'troops',troops);
end
$$;
create function xern_private.xern_set_war_doctrine(p_doctrine text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player();
begin
  if p_doctrine is null or p_doctrine not in ('stationary','defensive','aggressive') then return xern_private.fail('Invalid doctrine'); end if;
  insert into public.xern_war_doctrines values(uid,p_doctrine)
  on conflict(owner_id) do update set doctrine=excluded.doctrine;
  return xern_private.ok();
end
$$;
create function xern_private.warfare_visible_troops() returns setof public.team_units language sql stable set search_path='' as $$
  select u.* from public.team_units u
  where xern_private.player() is not null and u.stationed_plot_key is not null
    and exists(select 1 from public.land_claims l where l.country_key=u.stationed_plot_key and l.owner_id=u.owner_id)
  order by u.id
$$;
create function xern_private.warfare_register_safe_plots(p_keys text[]) returns jsonb language sql stable set search_path='' as $$
  -- The server owns the complete terrain bitmap. Client uploads cannot change it.
  select jsonb_build_object('ok',xern_private.player() is not null)
$$;

create table xern_private.asset_catalog (
  kind text primary key, price integer not null, hours integer, hp integer not null, attack integer not null
);
alter table xern_private.asset_catalog enable row level security;
insert into xern_private.asset_catalog values
  ('tank',5000,1,650,160),('tower',4000,null,340,85),('bush',2500,null,230,45),
  ('radar',6500,null,0,0),('truck',7000,1,260,40),('fortress',9000,null,950,65),('mine',8500,null,0,0);
create function xern_private.warfare_market_slots() returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('ok',true,
    'capacity',(select count(*)/1000 from public.land_claims where owner_id=p.uid),
    'used',(select count(*) from public.warfare_assets where owner_id=p.uid and (expires_at is null or expires_at>now())))
  from (select xern_private.player() uid) p
$$;
create function xern_private.warfare_buy_asset(p_kind text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); item xern_private.asset_catalog; player public.profiles; slots jsonb; placement text;
begin
  select * into item from xern_private.asset_catalog where kind=p_kind;
  if not found then return xern_private.fail('Unknown equipment'); end if;
  perform pg_advisory_xact_lock(18002);
  slots:=xern_private.warfare_market_slots();
  if (slots->>'used')::integer >= (slots->>'capacity')::integer or xern_private.sales_active(uid) then return xern_private.fail('No equipment slots available'); end if;
  player:=xern_private.collect_gold(uid);
  if player.money<item.price then return xern_private.fail('Not enough Xergs'); end if;
  select l.country_key into placement from public.land_claims l where l.owner_id=uid
    and not exists(select 1 from public.warfare_assets a where a.plot_key=l.country_key and (a.expires_at is null or a.expires_at>now()))
    order by l.country_key limit 1;
  if placement is null then return xern_private.fail('No free owned plot'); end if;
  insert into public.warfare_assets(owner_id,kind,plot_key,expires_at)
    values(uid,p_kind,placement,now()+make_interval(hours=>item.hours));
  update public.profiles set money=money-item.price where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'plot_key',placement);
end
$$;
create function xern_private.warfare_place_asset(p_id bigint,p_plot_key text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player();
begin
  perform pg_advisory_xact_lock(18002);
  if not exists(select 1 from public.land_claims where country_key=p_plot_key and owner_id=uid) then return xern_private.fail('Choose your own land'); end if;
  update public.warfare_assets set plot_key=p_plot_key where id=p_id and owner_id=uid and (expires_at is null or expires_at>now());
  if not found then return xern_private.fail('Equipment unavailable'); end if;
  return xern_private.ok();
end
$$;
create function xern_private.xern_launch_strike(p_weapon text,p_username text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); target uuid; wallet bigint; price integer; maximum integer; blocked boolean; lost integer:=0;
begin
  if p_weapon is null or p_weapon not in ('bomb','nuke') then return xern_private.fail('Unknown weapon'); end if;
  price:=case p_weapon when 'bomb' then 10000 else 22500 end;
  maximum:=case p_weapon when 'bomb' then 2000 else 10000 end;
  perform pg_advisory_xact_lock(18002);
  select id into target from public.profiles where lower(username)=lower(btrim(p_username));
  if target is null or xern_private.allied(uid,target) or xern_private.home_plot(target) is null then return xern_private.fail('Choose an enemy who owns land'); end if;
  perform 1 from public.profiles where id in (uid,target) order by id for update;
  select money into wallet from public.profiles where id=uid;
  if wallet<price then return xern_private.fail('Not enough Xergs'); end if;
  blocked:=exists(select 1 from public.warfare_assets where owner_id=target and kind='radar'
    and (expires_at is null or expires_at>now())) and random()<.5;
  if not blocked then
    perform xern_private.collect_gold(target);
    delete from public.land_claims where owner_id=target and country_key in (
      select country_key from public.land_claims where owner_id=target order by random() limit maximum);
    get diagnostics lost=row_count;
    if p_weapon='nuke' then update public.profiles set gold=greatest(0,gold-100000) where id=target; end if;
    perform xern_private.repair_deployments(target);
  end if;
  update public.profiles set money=money-price where id=uid returning money into wallet;
  return jsonb_build_object('ok',true,'blocked',blocked,'removed',lost,'money',wallet);
end
$$;
create function xern_private.force_stats(uid uuid,near_plot text) returns bigint[] language sql stable set search_path='' as $$
  with allies as (
    select uid id union
    select n.user_id from public.xern_clan_members m join public.xern_clan_members n using(clan_id)
    where m.user_id=uid and not xern_private.weekend()
      and exists(select 1 from xern_private.plot_neighbors(near_plot) k join public.land_claims l on l.country_key=k and l.owner_id=n.user_id)
  ), force as (
    select sum(u.health*u.unit_count) hp,sum(u.attack_value*u.unit_count) atk
    from public.team_units u join allies a on a.id=u.owner_id where u.stationed_plot_key is not null
    union all
    select sum(c.hp),sum(c.attack) from public.warfare_assets w join allies a on a.id=w.owner_id
    join xern_private.asset_catalog c using(kind) where w.expires_at is null or w.expires_at>now()
  )
  select array[greatest(1,coalesce(sum(hp),0))::bigint,
    greatest(1,round(coalesce(sum(atk),0)*case (select doctrine from public.xern_war_doctrines where owner_id=uid)
      when 'defensive' then 1.2 when 'aggressive' then .9 else 1 end))::bigint] from force
$$;
create function xern_private.battle_tick() returns integer language plpgsql set search_path='' as $$
declare battle public.warfare_live_battles; a_hp bigint; d_hp bigint; victor text; n integer:=0;
begin
  for battle in select * from public.warfare_live_battles where status='active' and updated_at<now()-interval '2 seconds'
    order by updated_at limit 50 for update skip locked loop
    if xern_private.allied(battle.attacker_id,battle.defender_id)
      or not exists(select 1 from public.land_claims where country_key=battle.plot_key and owner_id=battle.defender_id) then
      update public.warfare_live_battles set status='cancelled',updated_at=now() where id=battle.id;
      continue;
    end if;
    a_hp:=greatest(0,battle.attacker_hp-battle.defender_attack);
    d_hp:=greatest(0,battle.defender_hp-battle.attacker_attack);
    victor:=case when a_hp=0 then 'defender' when d_hp=0 then 'attacker' end;
    if victor='defender' then
      update public.warfare_marches set active=false,mode='hold',target_plot_key=null where owner_id=battle.attacker_id;
    end if;
    if victor='attacker' then
      perform xern_private.collect_gold(battle.defender_id);
      update public.land_claims set owner_id=battle.attacker_id,
        owner_name=(select username from public.profiles where id=battle.attacker_id),paid=0,created_at=now()
        where country_key=battle.plot_key and owner_id=battle.defender_id;
      perform xern_private.repair_deployments(battle.defender_id);
    end if;
    update public.warfare_live_battles set attacker_hp=a_hp,defender_hp=d_hp,round_no=round_no+1,
      status=case when victor is null then 'active' else 'done' end,winner=victor,updated_at=now() where id=battle.id;
    n:=n+1;
  end loop;
  delete from public.warfare_live_battles where status<>'active' and updated_at<now()-interval '2 days';
  return n;
end
$$;
create function xern_private.advance_troops(uid uuid default null) returns jsonb language plpgsql set search_path='' as $$
declare march record; chosen text; previous text; enemy uuid; username text; a bigint[]; d bigint[]; n integer;
  claimed integer:=0; battles integer:=0;
begin
  if not pg_try_advisory_xact_lock(18002) then return jsonb_build_object('ok',true,'claimed',0,'battles',0); end if;
  perform xern_private.battle_tick();
  for march in
    select m.*,u.claim_power,u.unit_count,p.team_buff_expires_at,w.doctrine,p.username player_name
    from public.warfare_marches m join public.team_units u on u.id=m.unit_id
    join public.profiles p on p.id=m.owner_id left join public.xern_war_doctrines w on w.owner_id=m.owner_id
    where m.active and (uid is null or m.owner_id=uid) and m.last_step_at<=now()-
      make_interval(secs=>greatest(1,u.claim_power*case w.doctrine when 'defensive' then 1.1 when 'aggressive' then .9 else 1 end/
        (case when p.team_buff_expires_at>now() then 2 else 1 end)))
    order by m.last_step_at limit 60
  loop
    update public.warfare_marches set last_step_at=now() where unit_id=march.unit_id;
    if xern_private.sales_active(march.owner_id) or exists(select 1 from public.warfare_live_battles
      where status='active' and march.owner_id in(attacker_id,defender_id)) then continue; end if;
    previous:=march.current_plot_key;
    for step in 1..least(8,march.unit_count) loop
      if march.mode='recall' then
        -- Redeploy directly to Homebase, preserving the squad and its equipment.
        chosen:=xern_private.home_plot(march.owner_id);
        if chosen is not null then
          update public.team_units set stationed_plot_key=chosen where id=march.unit_id;
          update public.warfare_marches set current_plot_key=chosen,active=false,mode='hold',target_plot_key=null where unit_id=march.unit_id;
        end if;
        exit;
      end if;
      if march.mode='explore' then
        select k into chosen from xern_private.plot_neighbors(previous) k
        where not exists(select 1 from public.land_claims l where l.country_key=k and xern_private.allied(march.owner_id,l.owner_id))
          and xern_private.safe_plot(k) order by k limit 1;
        if chosen is null then
          select k into chosen from (select country_key from public.land_claims where owner_id=march.owner_id order by created_at desc limit 160) own
          cross join lateral xern_private.plot_neighbors(own.country_key) k
          where not exists(select 1 from public.land_claims l where l.country_key=k and xern_private.allied(march.owner_id,l.owner_id))
            and xern_private.safe_plot(k) limit 1;
        end if;
      else
        if previous=march.target_plot_key then
          update public.warfare_marches set active=false where unit_id=march.unit_id;
          exit;
        end if;
        select k into chosen from xern_private.plot_neighbors(previous) k
        where xern_private.plot_distance(k,march.target_plot_key)<xern_private.plot_distance(previous,march.target_plot_key)
          and xern_private.safe_plot(k) and not exists(select 1 from public.land_claims l where l.country_key=k
            and l.owner_id<>march.owner_id and xern_private.allied(march.owner_id,l.owner_id))
        order by xern_private.plot_distance(k,march.target_plot_key),k limit 1;
      end if;
      exit when chosen is null;
      select owner_id into enemy from public.land_claims where country_key=chosen;
      if enemy is not null and enemy<>march.owner_id then
        a:=xern_private.force_stats(march.owner_id,chosen); d:=xern_private.force_stats(enemy,chosen);
        insert into public.warfare_live_battles(plot_key,attacker_id,defender_id,attacker_hp,defender_hp,
          attacker_max_hp,defender_max_hp,attacker_attack,defender_attack)
        values(chosen,march.owner_id,enemy,a[1],d[1],a[1],d[1],a[2],d[2]) on conflict do nothing;
        get diagnostics n=row_count; battles:=battles+n;
        exit;
      elsif enemy is null then
        insert into public.land_claims(country_key,country_name,owner_id,owner_name)
          values(chosen,'Explored territory',march.owner_id,march.player_name) on conflict do nothing;
        get diagnostics n=row_count; claimed:=claimed+n;
      end if;
      previous:=chosen;
      update public.warfare_marches set current_plot_key=previous where unit_id=march.unit_id;
    end loop;
  end loop;
  return jsonb_build_object('ok',true,'claimed',claimed,'battles',battles);
end
$$;
create function xern_private.warfare_frontier_tick() returns jsonb language sql set search_path='' as $$
  select xern_private.advance_troops(xern_private.player())
$$;
create function xern_private.team_warfare_tick(p_candidate_keys text[],p_candidate_names text[]) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; hourly bigint;
begin
  perform pg_advisory_xact_lock(18002);
  player:=xern_private.collect_gold(uid);
  select coalesce(sum(gold_per_hour*unit_count),0) into hourly from public.team_units where owner_id=uid and stationed_plot_key is not null;
  return jsonb_build_object('ok',true,'gold',player.gold,'gold_per_hour',hourly,'claimed_squares',0);
end
$$;
create function xern_private.world_tick() returns void language plpgsql set search_path='' as $$
declare uid uuid;
begin
  if not pg_try_advisory_xact_lock(18002) then return; end if;
  for uid in select owner_id from xern_private.land_sales where status='running' order by owner_id limit 10 loop
    perform xern_private.process_sale(uid);
  end loop;
  perform xern_private.advance_troops();
end
$$;
create function xern_private.collect_mines() returns void language plpgsql set search_path='' as $$
declare uid uuid;
begin
  if not pg_try_advisory_xact_lock(18002) then return; end if;
  delete from public.warfare_assets where expires_at<=now();
  for uid in select distinct owner_id from public.warfare_assets where kind='mine' order by owner_id loop
    perform xern_private.collect_gold(uid);
  end loop;
end
$$;
