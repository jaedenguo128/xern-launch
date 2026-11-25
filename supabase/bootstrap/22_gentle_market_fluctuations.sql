-- Independent gentle server moves: 35% chance per stock per scheduled tick.
create or replace function xern_private.stock_market_tick() returns void language plpgsql set search_path='' as $$
begin
  perform 1 from public.stock_quotes order by symbol for update;
  with previous as materialized (select symbol,price from public.stock_quotes),
  changes as (
    update public.stock_quotes q set price=case when random()<.35 then greatest(1,least(100000000,q.price+(case when random()<.5 then -1 else 1 end)*greatest(1,floor(q.price*.005)))) else q.price end,
      price_24h=coalesce((select h.price from public.stock_history h where h.symbol=q.symbol
        and h.created_at<=now()-interval '1 day' order by h.created_at desc limit 1),q.base_price)
    from previous where previous.symbol=q.symbol
    returning q.symbol,q.price,q.price-previous.price as change
  ), movements as (
    insert into xern_private.stock_movements(symbol,total) select symbol,change from changes
    on conflict(symbol) do update set total=stock_movements.total+excluded.total
    returning symbol
  ) insert into public.stock_history(symbol,price) select symbol,price from changes;
  delete from public.stock_history where created_at<now()-interval '7 days';
  delete from xern_private.signup_limits where window_at<now()-interval '1 day';
end
$$;
notify pgrst,'reload schema';
