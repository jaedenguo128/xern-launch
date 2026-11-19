create table xern_private.exploration_rings (
  unit_id bigint primary key references public.team_units on delete cascade,
  anchor text not null,
  radius integer not null default 1 check (radius between 1 and 9400)
);
alter table xern_private.exploration_rings enable row level security;
revoke all on xern_private.exploration_rings from public,anon,authenticated;

create function xern_private.next_exploration_plot(p_unit_id bigint,p_owner_id uuid,p_anchor text)
returns text language plpgsql set search_path='' as $$
declare center integer[]:=xern_private.plot_coordinates(p_anchor); ring integer; chosen text; ring_owned boolean;
begin
  if center is null then return null; end if;
  insert into xern_private.exploration_rings(unit_id,anchor) values(p_unit_id,p_anchor)
  on conflict(unit_id) do update set anchor=excluded.anchor,
    radius=case when exploration_rings.anchor=excluded.anchor then exploration_rings.radius else 1 end
  returning radius into ring;
  -- Generate only the cells in the next thin circular ring, rather than scan the whole territory.
  for attempt in 1..16 loop
    with offsets as (
      select dx,dy*direction dy from generate_series(-ring,ring) dx
      cross join lateral generate_series(
        case when dx*dx>(ring-1)*(ring-1) then 0
          else floor(sqrt(((ring-1)*(ring-1)-dx*dx)::numeric))::integer+1 end,
        floor(sqrt((ring*ring-dx*dx)::numeric))::integer
      ) dy
      cross join (values(-1),(1)) signs(direction)
      where dy>0 or direction=1
    ), candidates as (
      select 'plot:'||(center[1]+dx)||':'||(center[2]+dy) k,dx*dx+dy*dy distance
      from offsets where center[1]+dx between 0 and 8896 and center[2]+dy between 0 and 2831
)
    select
      (array_agg(k order by distance,hashtextextended(k||':'||p_unit_id,0),k) filter (
        where (l.owner_id is null or not xern_private.allied(p_owner_id,l.owner_id))
          and exists(select 1 from xern_private.plot_neighbors(k) neighbor
            join public.land_claims own on own.country_key=neighbor and own.owner_id=p_owner_id)
          and xern_private.safe_plot(k)
      ))[1],
      coalesce(bool_or(l.owner_id=p_owner_id),false)
    into chosen,ring_owned
    from candidates left join public.land_claims l on l.country_key=k;
    if chosen is not null then return chosen; end if;
    -- Recheck inner rings after territory loss rather than leaving an old frontier stranded.
    if not ring_owned or ring>=9400 then
      update xern_private.exploration_rings set radius=1 where unit_id=p_unit_id;
      return null;
    end if;
    ring:=ring+1;
    update xern_private.exploration_rings set radius=ring where unit_id=p_unit_id;
  end loop;
  return null;
end
$$;
revoke all on function xern_private.next_exploration_plot(bigint,uuid,text) from public,anon,authenticated;
create or replace function xern_private.advance_troops(uid uuid default null) returns jsonb language plpgsql set search_path='' as $$
declare march record; chosen text; previous text; enemy uuid; username text; a bigint[]; d bigint[]; n integer;
  claimed integer:=0; battles integer:=0;
begin
  if not pg_try_advisory_xact_lock(18002) then return jsonb_build_object('ok',true,'claimed',0,'battles',0); end if;
  perform xern_private.battle_tick();
  for march in
    select m.*,u.claim_power,u.unit_count,u.stationed_plot_key,p.team_buff_expires_at,w.doctrine,p.username player_name,
      greatest(1,u.claim_power*case w.doctrine when 'defensive' then 1.1 when 'aggressive' then .9 else 1 end/
        (case when p.team_buff_expires_at>now() then 2 else 1 end))*
        case when m.mode='explore' then 1.2 else 1 end step_seconds
    from public.warfare_marches m join public.team_units u on u.id=m.unit_id
    join public.profiles p on p.id=m.owner_id left join public.xern_war_doctrines w on w.owner_id=m.owner_id
    where m.active and (uid is null or m.owner_id=uid) and m.last_step_at<=now()-
      make_interval(secs=>greatest(1,u.claim_power*case w.doctrine when 'defensive' then 1.1 when 'aggressive' then .9 else 1 end/
        (case when p.team_buff_expires_at>now() then 2 else 1 end))*case when m.mode='explore' then 1.2 else 1 end)
    order by m.last_step_at limit 60
  loop
    update public.warfare_marches set last_step_at=case when march.mode='explore'
      then greatest(last_step_at+make_interval(secs=>march.step_seconds),now()-interval '3 seconds') else now() end
      where unit_id=march.unit_id;
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
        chosen:=xern_private.next_exploration_plot(march.unit_id,march.owner_id,
          coalesce(march.stationed_plot_key,xern_private.home_plot(march.owner_id)));
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
