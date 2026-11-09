-- Expose a fixed allowlist. All privileged code and hidden state live in xern_private.
revoke execute on all functions in schema xern_private from public, anon, authenticated;
do $$
declare rpc record; fn text; args text; result text; positions text; grantee text;
begin
  foreach fn in array array[
    'gift_status','claim_daily_gift','airdrop_play','xern_christmas_status','xern_christmas_open','xern_gift_player',
    'stock_trade','stock_claim_dividends','casino_action','land_trade','warfare_sell_plots',
    'xern_start_sell_all_land','xern_sell_all_land_status','team_open_crate','team_trade_units',
    'team_buy_units_xergs','team_level_unit','team_buy_boost','warfare_set_explore','warfare_set_march',
    'warfare_command','warfare_set_colony_rally','xern_set_war_doctrine','warfare_visible_troops',
    'warfare_register_safe_plots','warfare_market_slots','warfare_buy_asset','warfare_place_asset','xern_launch_strike',
    'warfare_frontier_tick','team_warfare_tick','xern_player_directory','xern_home_land_leaderboard',
    'xern_wealthiest_players_top10','xern_clan_stats','xern_clan_strength','xern_clan_action','xern_clan_weekly_payout',
    'xern_is_owner','xern_get_home_announcement','xern_get_owner_page_intro','xern_set_home_announcement',
    'xern_set_owner_page_intro','xern_send_owner_message','xern_read_owner_messages','xern_delete_owner_message',
    'xern_signup_rate_limit'
  ] loop
    select p.oid,p.pronargs,p.proretset,p.provolatile,pg_get_function_identity_arguments(p.oid) signature
      into strict rpc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='xern_private' and p.proname=fn;
    args:=pg_get_function_arguments(rpc.oid);
    result:=pg_get_function_result(rpc.oid);
    select coalesce(string_agg('$'||i,','),'') into positions from generate_series(1,rpc.pronargs) i;
    -- SECURITY DEFINER is confined to the non-exposed schema.
    execute format('alter function xern_private.%I(%s) security definer',fn,rpc.signature);
    execute format('create function public.%I(%s) returns %s language sql %s set search_path='''' as %L',fn,args,result,
      case when rpc.provolatile='s' then 'stable' else 'volatile' end,
      format('select %s xern_private.%I(%s)',case when rpc.proretset then '* from' else '' end,fn,positions));
    execute format('revoke all on function public.%I(%s) from public, anon, authenticated, service_role',fn,rpc.signature);
    grantee:=case when fn='xern_signup_rate_limit' then 'service_role'
      when fn in ('xern_get_home_announcement','xern_get_owner_page_intro') then 'authenticated, anon' else 'authenticated' end;
    execute format('grant execute on function public.%I(%s) to %s',fn,rpc.signature,grantee);
    execute format('grant execute on function xern_private.%I(%s) to %s',fn,rpc.signature,grantee);
  end loop;
end
$$;
grant usage on schema xern_private to authenticated, anon, service_role;
notify pgrst,'reload schema';
