create table xern_private.rally_fronts (
  unit_id bigint primary key references public.team_units on delete cascade,
  target text not null,
  head text not null,
  phase integer not null default 0
);
alter table xern_private.rally_fronts enable row level security;
revoke all on xern_private.rally_fronts from public,anon,authenticated;
CREATE OR REPLACE FUNCTION xern_private.rally_front_plot(p_unit bigint, p_owner uuid, p_current text, p_target text, p_origin text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare front xern_private.rally_fronts; chosen text; xy integer[]; goal integer[]; origin integer[];
  width integer; cycle integer; dy_scale numeric; forward boolean:=false;
begin
  goal:=xern_private.plot_coordinates(p_target);
  if goal is null then return null; end if;
  insert into xern_private.rally_fronts(unit_id,target,head) values(p_unit,p_target,p_current)
    on conflict(unit_id) do update set target=excluded.target,
      head=case when rally_fronts.target=excluded.target then rally_fronts.head else excluded.head end,
      phase=case when rally_fronts.target=excluded.target then rally_fronts.phase else 0 end
    returning * into front;
  if not exists(select 1 from public.land_claims where country_key=front.head and owner_id=p_owner) then front.head:=p_current; end if;
  xy:=xern_private.plot_coordinates(front.head);origin:=xern_private.plot_coordinates(p_origin);
  if xy is null then return null; end if;
  if front.head=p_target then return p_target; end if;
  dy_scale:=greatest(0.5,abs(
    asin(greatest(-1.0,least(1.0,1-2*(xy[2]+1.5)/2832.0)))-
    asin(greatest(-1.0,least(1.0,1-2*(xy[2]+0.5)/2832.0)))
  )*180/pi()/(360.0/8897)*1.60/1.70);
  width:=greatest(2,least(32,ceil(dy_scale)::integer+floor(sqrt(
    ((xy[1]-origin[1])::numeric)^2+((xy[2]-origin[2])*dy_scale)^2)/6)::integer+2));
  cycle:=greatest(5,least(40,width*2+1));
  if front.phase%cycle<>0 then
    with nearby as (
      select 'plot:'||(xy[1]+dx)||':'||(xy[2]+dy) k,dx,dy
      from generate_series(-width,width) dx cross join generate_series(-greatest(1,floor(width/dy_scale)::integer),greatest(1,floor(width/dy_scale)::integer)) dy
      where xy[1]+dx between 0 and 8896 and xy[2]+dy between 0 and 2831
        and dx*dx+(dy*dy_scale)^2<=width*width
    )
    select k into chosen from nearby
    where not exists(select 1 from public.land_claims l where l.country_key=k and xern_private.allied(p_owner,l.owner_id))
      and exists(select 1 from xern_private.plot_neighbors(k) neighbor
        join public.land_claims l on l.country_key=neighbor and l.owner_id=p_owner)
      and xern_private.safe_plot(k)
    order by dx*dx+(dy*dy_scale)^2+
      abs(mod(hashtextextended(k||':'||p_unit,0),1000))::numeric/1000*4,k limit 1;
  end if;
  if chosen is null then
    select k into chosen from xern_private.plot_neighbors(front.head) k
    cross join lateral (select xern_private.plot_coordinates(k) pos) p
    where xern_private.plot_distance(k,p_target)<xern_private.plot_distance(front.head,p_target)
      and xern_private.safe_plot(k)
      and not exists(select 1 from public.land_claims l where l.country_key=k and l.owner_id<>p_owner and xern_private.allied(p_owner,l.owner_id))
    order by (pos[1]-goal[1])::numeric^2+((pos[2]-goal[2])*dy_scale)^2,
      hashtextextended(k||':'||p_unit,0) limit 1;
    forward:=true;
  end if;
  if chosen is not null then
    update xern_private.rally_fronts set phase=front.phase+1,
      head=case when forward and not exists(select 1 from public.land_claims l where l.country_key=chosen and l.owner_id<>p_owner)
        then chosen else front.head end where unit_id=p_unit;
  end if;
  return chosen;
end
$function$
;
revoke all on function xern_private.rally_front_plot(bigint,uuid,text,text,text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION xern_private.advance_troops(uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
        chosen:=xern_private.rally_front_plot(march.unit_id,march.owner_id,previous,march.target_plot_key,
          coalesce(march.stationed_plot_key,previous));
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
$function$
;
