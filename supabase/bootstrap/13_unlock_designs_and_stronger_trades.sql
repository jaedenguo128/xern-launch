alter table public.team_units drop constraint team_units_unit_count_check;
alter table public.team_units add constraint team_units_unit_count_check check (unit_count between 0 and 500);
alter table public.team_units alter column unit_count set default 0;

create or replace function xern_private.land_trade(p_action text,p_plot_keys text[],p_plot_names text[]) returns jsonb
language plpgsql security definer set search_path='' as $$
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
  update public.team_units set stationed_plot_key=p_plot_keys[1] where owner_id=uid and unit_count>0;
  insert into public.warfare_marches(unit_id,owner_id,current_plot_key,active,mode)
    select id,uid,p_plot_keys[1],true,'explore' from public.team_units where owner_id=uid and unit_count>0
    on conflict(unit_id) do update set current_plot_key=excluded.current_plot_key,active=true,mode='explore',target_plot_key=null,last_step_at=now();
  return jsonb_build_object('ok',true,'money',player.money);
end
$$;

create or replace function xern_private.team_open_crate(p_crate text) returns jsonb language plpgsql security definer set search_path='' as $$
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
    insert into public.team_units(owner_id,unit_name,rarity,unit_type,speed,health,claim_power,attack_value,unit_count,stationed_plot_key,gold_per_hour)
    values(uid,design.unit_name,design.rarity,design.unit_type,design.speed,design.health,design.claim_power,design.attack_value,0,null,design.gold_per_hour)
    returning * into unit;
  end if;
  update public.profiles set money=money-price where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'gold',player.gold,'duplicate',duplicate,'unit',to_jsonb(unit));
end
$$;

create or replace function xern_private.trade_units(p_unit_id bigint,p_quantity integer,p_action text,with_xergs boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
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
    if p_quantity>unit.unit_count then return xern_private.fail('Not enough owned troops'); end if;
    value:=p_quantity*(price/10);
    update public.team_units set unit_count=unit_count-p_quantity,
      stationed_plot_key=case when unit_count=p_quantity then null else stationed_plot_key end where id=p_unit_id;
    if p_quantity=unit.unit_count then delete from public.warfare_marches where unit_id=p_unit_id; end if;
    update public.profiles set gold=gold+value where id=uid returning * into player;
  end if;
  return jsonb_build_object('ok',true,'money',player.money,'gold',player.gold,'amount',value);
end
$$;

create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); quote public.stock_quotes; holding public.holdings; wallet bigint;
  value bigint; next_price numeric;
begin
  if p_amount is null or p_amount not between 1 and 1000000000 then return xern_private.fail('whole_shares_required'); end if;
  if p_side is null or p_side not in ('buy','sell') then return xern_private.fail('Invalid trade side'); end if;
  select money into wallet from public.profiles where id=uid for update;
  select * into quote from public.stock_quotes where symbol=p_symbol for update;
  if not found then return xern_private.fail('Unknown stock'); end if;
  select * into holding from public.holdings where owner_id=uid and symbol=p_symbol;
  if p_amount*quote.price>9007199254740991 then return xern_private.fail('Trade amount too large'); end if;
  value:=round(p_amount*quote.price);
  if value<1 then return xern_private.fail('too_small'); end if;
  if p_side='buy' then
    if wallet<value then return xern_private.fail('Not enough Xergs'); end if;
    insert into public.holdings values(uid,p_symbol,p_amount,value)
    on conflict(owner_id,symbol) do update set shares=holdings.shares+excluded.shares,cost=holdings.cost+excluded.cost;
    wallet:=wallet-value;
  else
    if coalesce(holding.shares,0)<p_amount then return xern_private.fail('Not enough shares'); end if;
    update public.holdings set shares=shares-p_amount,cost=floor(cost::numeric*(shares-p_amount)/shares)
      where owner_id=uid and symbol=p_symbol;
    wallet:=wallet+value;
  end if;
  update public.profiles set money=wallet where id=uid;
  next_price:=greatest(0.10,least(100000000,round(quote.price+
    (case p_side when 'buy' then 1 else -1 end)*least(4,quote.price*0.08,4*p_amount*quote.price*quote.price/greatest(1000000,quote.depth*400)),2)));
  if next_price<>quote.price then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value);
end
$$;

