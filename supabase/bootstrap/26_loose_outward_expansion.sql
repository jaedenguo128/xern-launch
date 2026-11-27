-- Version derived geometry so existing caches rebuild lazily without changing real claims.
alter table xern_private.exploration_candidate_sets add column generator_version integer not null default 1;

create or replace function xern_private.next_exploration_plot(p_unit_id bigint,p_owner_id uuid,p_anchor text)
returns text language plpgsql set search_path='' as $$
declare center integer[]:=xern_private.plot_coordinates(p_anchor); state xern_private.exploration_rings;
  cached xern_private.exploration_candidate_sets; ring integer; chosen text;
  ring_owned boolean; inner_radius integer; outer_radius integer;
  phase double precision:=mod(hashtextextended(p_unit_id::text,47),6283)/1000.0;
begin
  if center is null then return null; end if;
  insert into xern_private.exploration_rings(unit_id,anchor) values(p_unit_id,p_anchor) on conflict do nothing;
  select * into state from xern_private.exploration_rings where unit_id=p_unit_id;
  ring:=state.radius;
  if state.anchor<>p_anchor then
    ring:=1;
    update xern_private.exploration_rings set anchor=p_anchor,radius=1 where unit_id=p_unit_id;
  end if;
  for attempt in 1..16 loop
    select * into cached from xern_private.exploration_candidate_sets where unit_id=p_unit_id;
    if not found or cached.anchor<>p_anchor or cached.radius<>ring or cached.generator_version<>2 then
      delete from xern_private.exploration_candidates where unit_id=p_unit_id;
      inner_radius:=greatest(0,ring-2);outer_radius:=ring+2;
      insert into xern_private.exploration_candidates(unit_id,plot_key,neighbors,priority,tie)
      with offsets as (
        select dx,dy*direction dy from generate_series(-outer_radius,outer_radius) dx
        cross join lateral generate_series(
          case when dx*dx>inner_radius*inner_radius then 0 else floor(sqrt((inner_radius*inner_radius-dx*dx)::numeric))::integer+1 end,
          floor(sqrt((outer_radius*outer_radius-dx*dx)::numeric))::integer
        ) dy cross join (values(-1),(1)) signs(direction)
        where dy>0 or direction=1
      ), warped as (
        -- Smooth, uneven lobes spread the front outward without completing circles.
        select round(dx*scale)::integer dx,round(dy*scale)::integer dy,dx*dx+dy*dy distance
        from offsets cross join lateral (select atan2(dy::double precision,dx::double precision) angle) a
        cross join lateral (select 1+.13*sin(3*angle+phase)+.09*cos(5*angle-phase) scale) b
      ), candidates as (
        select 'plot:'||(center[1]+dx)||':'||(center[2]+dy) k,
          center[1]+dx x,center[2]+dy y,min(distance) distance
        from warped where center[1]+dx between 0 and 8896 and center[2]+dy between 0 and 2831
        group by dx,dy
      )
      select p_unit_id,k,array(select 'plot:'||nx||':'||ny from (values(x-1,y),(x+1,y),(x,y-1),(x,y+1)) n(nx,ny)
          where nx between 0 and 8896 and ny between 0 and 2831),
        distance+abs(mod(hashtextextended(k||':'||p_unit_id,0),1000))::numeric/1000*greatest(24,ring*10),
        hashtextextended(k||':'||p_unit_id,0) from candidates;
      insert into xern_private.exploration_candidate_sets(unit_id,anchor,radius,generator_version) values(p_unit_id,p_anchor,ring,2)
        on conflict(unit_id) do update set anchor=excluded.anchor,radius=excluded.radius,generator_version=excluded.generator_version;
    end if;
    -- Stop at the first valid candidate in exactly the previous ranking order.
    -- OFFSET prevents the lateral point lookup from becoming a territory-wide join.
    with ordered as materialized (
      select plot_key,neighbors from xern_private.exploration_candidates where unit_id=p_unit_id
      order by priority,tie,plot_key
    )
    select c.plot_key into chosen from ordered c
    left join lateral (select owner_id from public.land_claims where country_key=c.plot_key offset 0) l on true
    where case
      when l.owner_id=p_owner_id then false
      when l.owner_id is not null and xern_private.allied(p_owner_id,l.owner_id) then false
      when exists(select 1 from public.land_claims own where own.country_key=any(c.neighbors) and own.owner_id=p_owner_id)
        then xern_private.safe_plot(c.plot_key)
      else false end
    limit 1;
    if chosen is not null then return chosen; end if;
    select exists(select 1 from xern_private.exploration_candidates c join public.land_claims l on l.country_key=c.plot_key
      where c.unit_id=p_unit_id and l.owner_id=p_owner_id) into ring_owned;
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


