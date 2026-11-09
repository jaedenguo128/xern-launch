create function xern_private.plot_coordinates(key text) returns integer[] language plpgsql immutable set search_path='' as $$
declare xy integer[];
begin
  if key is null or key !~ '^plot:(0|[1-9][0-9]{0,3}):(0|[1-9][0-9]{0,3})$' then return null; end if;
  xy:=array[split_part(key,':',2)::integer,split_part(key,':',3)::integer];
  if xy[1]>=8897 or xy[2]>=2832 then return null; end if;
  return xy;
end
$$;
create function xern_private.plot_neighbors(key text) returns setof text language sql immutable set search_path='' as $$
  select 'plot:'||x||':'||y from (select xern_private.plot_coordinates(key) xy) p
  cross join lateral (values(xy[1]-1,xy[2]),(xy[1]+1,xy[2]),(xy[1],xy[2]-1),(xy[1],xy[2]+1)) n(x,y)
  where x between 0 and 8896 and y between 0 and 2831
$$;
create function xern_private.plot_distance(a text,b text) returns integer language sql immutable set search_path='' as $$
  select abs(xy[1]-zw[1])+abs(xy[2]-zw[2])
  from (select xern_private.plot_coordinates(a) xy,xern_private.plot_coordinates(b) zw) p
$$;
create function xern_private.safe_plot(key text) returns boolean language sql stable set search_path='' as $$
  select coalesce(bool_and(get_bit(t.pixels,point.x)=1) and count(*)=9,false)
  from (select xern_private.plot_coordinates(key) xy) p
  cross join (values(.05),(.5),(.95)) dx(v) cross join (values(.05),(.5),(.95)) dy(v)
  cross join lateral (select floor((xy[1]+dx.v)*3000/8897)::integer x,
    floor((.5-asin(1-2*(xy[2]+dy.v)::double precision/2832)/pi())*1100)::integer y) point
  join xern_private.terrain t on t.y=point.y
$$;
create function xern_private.home_plot(uid uuid) returns text language sql stable set search_path='' as $$
  select country_key from public.land_claims where owner_id=uid order by created_at,country_key limit 1
$$;
create function xern_private.sales_active(uid uuid) returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from xern_private.land_sales where owner_id=uid and status='running')
$$;
create function xern_private.repair_deployments(uid uuid) returns void language plpgsql set search_path='' as $$
declare home text:=xern_private.home_plot(uid);
begin
  update public.team_units u set stationed_plot_key=home where u.owner_id=uid and u.stationed_plot_key is not null
    and not exists(select 1 from public.land_claims l where l.country_key=u.stationed_plot_key and l.owner_id=uid);
  delete from public.warfare_marches m where m.owner_id=uid and
    not exists(select 1 from public.land_claims l where l.country_key=m.current_plot_key and l.owner_id=uid);
  delete from public.warfare_assets a where a.owner_id=uid and
    not exists(select 1 from public.land_claims l where l.country_key=a.plot_key and l.owner_id=uid);
  if home is null then delete from public.warfare_rally_orders where owner_id=uid; end if;
end
$$;
create function xern_private.land_trade(p_action text,p_plot_keys text[],p_plot_names text[]) returns jsonb
language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; reach integer;
begin
  if p_action is distinct from 'buy' or cardinality(p_plot_keys) is distinct from 20
     or cardinality(p_plot_names) is distinct from 20 or (select count(distinct k) from unnest(p_plot_keys) k)<>20
     or exists(select 1 from unnest(p_plot_keys) k where not xern_private.safe_plot(k)) then return xern_private.fail('invalid_plot'); end if;
  with recursive connected(k) as (
    select p_plot_keys[1] union
    select neighbor from connected c cross join lateral xern_private.plot_neighbors(c.k) neighbor where neighbor=any(p_plot_keys)
  ) select count(*) into reach from connected;
  if reach<>20 then return xern_private.fail('not_connected'); end if;
  perform pg_advisory_xact_lock(18002);
  if xern_private.home_plot(uid) is not null or xern_private.sales_active(uid) then return xern_private.fail('homebase_exists'); end if;
  if exists(select 1 from public.land_claims where country_key=any(p_plot_keys)) then return xern_private.fail('already_owned'); end if;
  select * into player from public.profiles where id=uid for update;
  if player.money<100 then return xern_private.fail('insufficient_funds'); end if;
  insert into public.land_claims(country_key,country_name,owner_id,owner_name,paid)
    select k,left(coalesce(nullif(n,''),'Homebase'),100),uid,player.username,5 from unnest(p_plot_keys,p_plot_names) p(k,n);
  update public.profiles set money=money-100,income_at=now() where id=uid returning money into player.money;
  update public.team_units set stationed_plot_key=p_plot_keys[1] where owner_id=uid;
  insert into public.warfare_marches(unit_id,owner_id,current_plot_key,active,mode)
    select id,uid,p_plot_keys[1],true,'explore' from public.team_units where owner_id=uid
    on conflict(unit_id) do update set current_plot_key=excluded.current_plot_key,active=true,mode='explore',target_plot_key=null,last_step_at=now();
  return jsonb_build_object('ok',true,'money',player.money);
end
$$;
create function xern_private.warfare_sell_plots(p_count integer) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); sold integer:=0; key text; wallet bigint; proceeds bigint;
begin
  if p_count is null or p_count not between 1 and 100 then return xern_private.fail('Invalid sale amount'); end if;
  perform pg_advisory_xact_lock(18002);
  if xern_private.sales_active(uid) then return xern_private.fail('An all-land sale is running'); end if;
  perform xern_private.collect_gold(uid);
  -- A leaf is safe to remove without splitting the remaining territory. A local
  -- square that connects two neighbors also permits removal of a corner.
  for i in 1..p_count loop
    select l.country_key into key from public.land_claims l
    where l.owner_id=uid and (select count(*) from xern_private.plot_neighbors(l.country_key) n
      join public.land_claims o on o.country_key=n and o.owner_id=uid)<=1
    order by l.country_key desc limit 1;
    if key is null then
      select l.country_key into key from public.land_claims l where l.owner_id=uid and exists(
        select 1 from xern_private.plot_neighbors(l.country_key) a
        join public.land_claims la on la.country_key=a and la.owner_id=uid
        cross join xern_private.plot_neighbors(l.country_key) b
        join public.land_claims lb on lb.country_key=b and lb.owner_id=uid
        where a<b and (select count(*) from xern_private.plot_neighbors(l.country_key) n
          join public.land_claims o on o.country_key=n and o.owner_id=uid)=2
          and exists(select 1 from xern_private.plot_neighbors(a) x
            join public.land_claims ox on ox.country_key=x and ox.owner_id=uid
            where x<>l.country_key and xern_private.plot_distance(x,b)=1)
      ) order by l.country_key desc limit 1;
    end if;
    exit when key is null;
    delete from public.land_claims where country_key=key and owner_id=uid;
    sold:=sold+1;
  end loop;
  if sold=0 then return xern_private.fail('No connected edge was available to sell'); end if;
  perform xern_private.repair_deployments(uid);
  proceeds:=sold::bigint*3/2;
  update public.profiles set money=money+proceeds where id=uid returning money into wallet;
  return jsonb_build_object('ok',true,'money',wallet,'sold_squares',sold,'acres_sold',sold*5000,'proceeds',proceeds);
end
$$;
create function xern_private.xern_start_sell_all_land() returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player();
begin
  perform pg_advisory_xact_lock(18002);
  if xern_private.sales_active(uid) then return xern_private.ok(); end if;
  if xern_private.home_plot(uid) is null then return xern_private.fail('You have no land to sell'); end if;
  insert into xern_private.land_sales values(uid,'running',0,0)
    on conflict(owner_id) do update set status='running',sold=0,proceeds=0;
  update public.warfare_marches set active=false where owner_id=uid;
  return xern_private.ok();
end
$$;
create function xern_private.process_sale(uid uuid) returns void language plpgsql set search_path='' as $$
declare n integer; sale xern_private.land_sales; total_proceeds bigint;
begin
  select * into sale from xern_private.land_sales where owner_id=uid for update;
  if sale.status is distinct from 'running' then return; end if;
  perform xern_private.collect_gold(uid);
  delete from public.land_claims where owner_id=uid and country_key in (
    select country_key from public.land_claims where owner_id=uid order by country_key limit 500);
  get diagnostics n=row_count;
  total_proceeds:=(sale.sold+n)::bigint*3/2;
  update public.profiles set money=money+total_proceeds-sale.proceeds where id=uid;
  update xern_private.land_sales set sold=sale.sold+n,proceeds=total_proceeds,
    status=case when xern_private.home_plot(uid) is null then 'done' else 'running' end where owner_id=uid;
  perform xern_private.repair_deployments(uid);
end
$$;
create function xern_private.xern_sell_all_land_status() returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); sale xern_private.land_sales;
begin
  if pg_try_advisory_xact_lock(18002) then perform xern_private.process_sale(uid); end if;
  select * into sale from xern_private.land_sales where owner_id=uid;
  if not found then return xern_private.fail('No queued sale'); end if;
  return jsonb_build_object('ok',true,'status',sale.status,'sold',sale.sold,'proceeds',sale.proceeds,
    'remaining',(select count(*) from public.land_claims where owner_id=uid));
end
$$;
create function xern_private.collect_gold(uid uuid) returns public.profiles language plpgsql set search_path='' as $$
declare player public.profiles; rate bigint; earned numeric; mine_earned numeric; elapsed numeric;
begin
  select * into player from public.profiles where id=uid for update;
  select coalesce(sum(u.gold_per_hour*u.unit_count),0) into rate
  from public.team_units u join public.land_claims l on l.country_key=u.stationed_plot_key and l.owner_id=uid
  where u.owner_id=uid;
  elapsed:=greatest(0,extract(epoch from now()-player.income_at));
  earned:=player.income_remainder+rate*elapsed/3600;
  select player.mine_remainder+count(*)*50*elapsed/60 into mine_earned from public.warfare_assets where owner_id=uid and kind='mine';
  update public.profiles set gold=gold+floor(earned)::bigint,money=money+floor(mine_earned)::bigint,
    income_at=now(),income_remainder=earned-floor(earned),mine_remainder=mine_earned-floor(mine_earned)
    where id=uid returning * into player;
  return player;
end
$$;
create function xern_private.team_open_crate(p_crate text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; unit public.team_units; design xern_private.unit_catalog;
  price integer; odds integer[]; roll double precision; rarity_name text; home text; duplicate boolean;
begin
  price:=case p_crate when 'bronze' then 250 when 'silver' then 750 when 'gold' then 2000 when 'astral' then 20000 end;
  if price is null then return xern_private.fail('Invalid crate'); end if;
  perform pg_advisory_xact_lock(18002);
  player:=xern_private.collect_gold(uid);
  if player.money<price then return xern_private.fail('insufficient_funds'); end if;
  odds:=case p_crate when 'bronze' then array[700,950,995] when 'silver' then array[450,830,970] else array[200,600,900] end;
  roll:=random()*1000;
  rarity_name:=case when p_crate='astral' and random()<.05 then 'mythical'
    when roll<odds[1] then 'common' when roll<odds[2] then 'rare' when roll<odds[3] then 'epic' else 'legendary' end;
  select * into design from xern_private.unit_catalog where rarity=rarity_name order by random() limit 1;
  select * into unit from public.team_units where owner_id=uid and unit_name=design.unit_name;
  duplicate:=found;
  if duplicate then
    update public.team_units set duplicate_tokens=duplicate_tokens+1 where id=unit.id returning * into unit;
  else
    if (select coalesce(sum(unit_count),0) from public.team_units where owner_id=uid)>=500 then return xern_private.fail('max_characters'); end if;
    home:=xern_private.home_plot(uid);
    insert into public.team_units(owner_id,unit_name,rarity,unit_type,speed,health,claim_power,attack_value,stationed_plot_key,gold_per_hour)
    values(uid,design.unit_name,design.rarity,design.unit_type,design.speed,design.health,design.claim_power,design.attack_value,home,design.gold_per_hour)
    returning * into unit;
    if home is not null then
      insert into public.warfare_marches(unit_id,owner_id,current_plot_key,active,mode) values(unit.id,uid,home,true,'explore');
    end if;
  end if;
  update public.profiles set money=money-price where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'gold',player.gold,'duplicate',duplicate,'unit',to_jsonb(unit));
end
$$;
create function xern_private.trade_units(p_unit_id bigint,p_quantity integer,p_action text,with_xergs boolean) returns jsonb
language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; unit public.team_units; price integer; value bigint; home text;
begin
  if p_quantity is null or p_quantity not between 1 and 50 or p_action is null or p_action not in ('buy','sell') then return xern_private.fail('Invalid troop trade'); end if;
  perform pg_advisory_xact_lock(18002);
  select * into unit from public.team_units where id=p_unit_id and owner_id=uid;
  if not found then return xern_private.fail('Troop not found'); end if;
  player:=xern_private.collect_gold(uid);
  select buy_cost into price from xern_private.unit_catalog where unit_name=unit.unit_name;
  if p_action='buy' then
    home:=xern_private.home_plot(uid);
    if home is null or xern_private.sales_active(uid) then return xern_private.fail('no_land'); end if;
    if (select sum(unit_count) from public.team_units where owner_id=uid)+p_quantity>500 then return xern_private.fail('max_characters'); end if;
    value:=p_quantity*price;
    if with_xergs and player.money<value then return xern_private.fail('insufficient_funds'); end if;
    if not with_xergs and player.gold<value then return xern_private.fail('insufficient_gold'); end if;
    update public.team_units set unit_count=unit_count+p_quantity,stationed_plot_key=coalesce(stationed_plot_key,home) where id=p_unit_id;
    insert into public.warfare_marches(unit_id,owner_id,current_plot_key,active,mode) values(unit.id,uid,home,true,'explore')
    on conflict(unit_id) do nothing;
    update public.profiles set money=money-case when with_xergs then value else 0 end,
      gold=gold-case when with_xergs then 0 else value end where id=uid returning * into player;
  else
    if p_quantity>=unit.unit_count then return xern_private.fail('keep_one'); end if;
    value:=p_quantity*(price/10);
    update public.team_units set unit_count=unit_count-p_quantity where id=p_unit_id;
    update public.profiles set gold=gold+value where id=uid returning * into player;
  end if;
  return jsonb_build_object('ok',true,'money',player.money,'gold',player.gold,'amount',value);
end
$$;
create function xern_private.team_buy_units_xergs(p_unit_id bigint,p_quantity integer) returns jsonb language sql set search_path='' as $$
  select xern_private.trade_units(p_unit_id,p_quantity,'buy',true)
$$;
create function xern_private.team_trade_units(p_unit_id bigint,p_quantity integer,p_action text) returns jsonb language sql set search_path='' as $$
  select xern_private.trade_units(p_unit_id,p_quantity,p_action,false)
$$;
create function xern_private.team_level_unit(p_unit_id bigint) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; unit public.team_units; price integer;
begin
  perform pg_advisory_xact_lock(18002);
  select * into unit from public.team_units where id=p_unit_id and owner_id=uid;
  if not found then return xern_private.fail('Troop not found'); end if;
  if unit.level>=20 then return xern_private.fail('max_level'); end if;
  if unit.duplicate_tokens<unit.level*10 then return xern_private.fail('no_duplicate'); end if;
  select upgrade_cost*unit.level into price from xern_private.unit_catalog where unit_name=unit.unit_name;
  player:=xern_private.collect_gold(uid);
  if player.money<price then return xern_private.fail('insufficient_funds'); end if;
  update public.team_units set level=level+1,duplicate_tokens=duplicate_tokens-level*10,
    speed=speed+2,health=health+10,attack_value=attack_value+5,gold_per_hour=gold_per_hour+5
    where id=p_unit_id returning * into unit;
  update public.profiles set money=money-price where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'unit',to_jsonb(unit),'level',unit.level);
end
$$;
create function xern_private.team_buy_boost() returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles;
begin
  select * into player from public.profiles where id=uid for update;
  if player.team_buff_expires_at>now() then return xern_private.fail('boost_already_active')||jsonb_build_object('expires_at',player.team_buff_expires_at); end if;
  if player.money<10000 then return xern_private.fail('insufficient_funds'); end if;
  update public.profiles set money=money-10000,team_buff_expires_at=now()+interval '30 minutes'
    where id=uid returning * into player;
  return jsonb_build_object('ok',true,'money',player.money,'expires_at',player.team_buff_expires_at);
end
$$;
