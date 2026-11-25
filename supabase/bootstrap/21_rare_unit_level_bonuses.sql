create or replace function xern_private.team_level_unit(p_unit_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
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
    speed=speed+case when unit.unit_name='Deimos' then 4 when unit.rarity='legendary' then 3 else 2 end,
    health=health+case when unit.unit_name='Deimos' then 30 when unit.rarity='legendary' then 20 else 10 end,
    attack_value=attack_value+case when unit.unit_name='Deimos' then 12 when unit.rarity='legendary' then 8 else 5 end,
    gold_per_hour=gold_per_hour+case when unit.unit_name='Deimos' then 12 when unit.rarity='legendary' then 8 else 5 end
    where id=p_unit_id returning * into unit;
  update public.profiles set money=money-price where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'unit',to_jsonb(unit),'level',unit.level);
end
$$;

-- Settle existing income before applying the additional earned-level bonuses.
do $$
declare owner uuid;
begin
  perform pg_advisory_xact_lock(18002);
  for owner in select distinct owner_id from public.team_units where level>1 and (rarity='legendary' or unit_name='Deimos') order by owner_id loop
    perform xern_private.collect_gold(owner);
  end loop;
  update public.team_units set
    speed=speed+(level-1)*case when unit_name='Deimos' then 2 else 1 end,
    health=health+(level-1)*case when unit_name='Deimos' then 20 else 10 end,
    attack_value=attack_value+(level-1)*case when unit_name='Deimos' then 7 else 3 end,
    gold_per_hour=gold_per_hour+(level-1)*case when unit_name='Deimos' then 7 else 3 end
  where level>1 and (rarity='legendary' or unit_name='Deimos');
end $$;
