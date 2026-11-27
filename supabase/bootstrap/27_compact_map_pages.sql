-- A compact page bypasses the REST row cap without exposing additional data.
-- Serve map projections from a narrow ordered index rather than random heap reads.
create index if not exists land_claims_map_page on public.land_claims(country_key)
  include(owner_id,owner_name,paid,area_km2,country_name);
create function xern_private.warfare_map_page(p_after text default null,p_limit integer default 10000)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  perform xern_private.player();
  if p_limit is null or p_limit not between 1 and 10000 or
    (p_after is not null and xern_private.plot_coordinates(p_after) is null) then
    return xern_private.fail('Invalid map cursor');
  end if;
  with page as materialized (
    select country_key,owner_id,owner_name,paid,area_km2,country_name from public.land_claims
    where country_key>coalesce(p_after,'') order by country_key limit p_limit
  ), owners as materialized (
    select owner_id,max(owner_name) name,row_number() over(order by owner_id)-1 slot
    from page group by owner_id
  )
  select jsonb_build_object('ok',true,
    'owners',coalesce((select jsonb_agg(jsonb_build_array(owner_id,name) order by slot) from owners),'[]'::jsonb),
    'plots',coalesce((select jsonb_agg(jsonb_build_array(country_key,slot)||
      case when paid=0 and area_km2=20.234282 and country_name='Explored territory' then '[]'::jsonb
        else jsonb_build_array(paid,area_km2,country_name) end order by country_key)
      from page join owners using(owner_id)),'[]'::jsonb),
    'next',case when (select count(*) from page)=p_limit then (select max(country_key) from page) end)
  into result;
  return result;
end
$$;
revoke all on function xern_private.warfare_map_page(text,integer) from public,anon;
grant execute on function xern_private.warfare_map_page(text,integer) to authenticated;
create function public.warfare_map_page(p_after text default null,p_limit integer default 10000)
returns jsonb language sql stable set search_path='' as $$select xern_private.warfare_map_page(p_after,p_limit)$$;
revoke all on function public.warfare_map_page(text,integer) from public,anon;
grant execute on function public.warfare_map_page(text,integer) to authenticated;
notify pgrst,'reload schema';
