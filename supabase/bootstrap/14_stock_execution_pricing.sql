create table xern_private.stock_liquidity (
  symbol text primary key references public.stock_quotes on delete cascade,
  supply numeric not null,
  anchor_supply numeric not null,
  anchor_price numeric not null,
  slope numeric not null check (slope>0),
  last_price numeric not null,
  depth numeric not null
);
alter table xern_private.stock_liquidity enable row level security;
revoke all on xern_private.stock_liquidity from public,anon,authenticated;

-- Integral of a linear quote, with the game's existing minimum and maximum prices.
create function xern_private.stock_price_integral(price numeric) returns numeric
language sql immutable set search_path='' as $$
  select case when price<0.10 then 0.10*price-0.005
    when price>100000000 then 100000000::numeric*price-5000000000000000::numeric
    else price*price/2 end
$$;
revoke all on function xern_private.stock_price_integral(numeric) from public,anon,authenticated;

create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); quote public.stock_quotes; holding public.holdings;
  market xern_private.stock_liquidity; wallet bigint; value bigint; total numeric;
  next_supply numeric; start_price numeric; end_price numeric; next_price numeric;
begin
  if p_amount is null or p_amount not between 1 and 1000000000 then return xern_private.fail('whole_shares_required'); end if;
  if p_side is null or p_side not in ('buy','sell') then return xern_private.fail('Invalid trade side'); end if;
  select money into wallet from public.profiles where id=uid for update;
  select * into quote from public.stock_quotes where symbol=p_symbol for update;
  if not found then return xern_private.fail('Unknown stock'); end if;
  select * into holding from public.holdings where owner_id=uid and symbol=p_symbol;
  if p_side='sell' and coalesce(holding.shares,0)<p_amount then return xern_private.fail('Not enough shares'); end if;
  -- The quote row serializes traders and initialization, including different players.
  insert into xern_private.stock_liquidity(symbol,supply,anchor_supply,anchor_price,slope,last_price,depth)
    select p_symbol,coalesce(sum(shares),0),coalesce(sum(shares),0),quote.price,
      4*quote.price*quote.price/greatest(1000000,quote.depth*400),quote.price,quote.depth
    from public.holdings where symbol=p_symbol
    on conflict(symbol) do nothing;
  select * into market from xern_private.stock_liquidity where symbol=p_symbol for update;
  -- Scheduled market moves start a new curve at the current holdings and quote.
  if market.last_price<>quote.price or market.depth<>quote.depth then
    market.anchor_supply:=market.supply;
    market.anchor_price:=quote.price;
    market.slope:=4*quote.price*quote.price/greatest(1000000,quote.depth*400);
    market.depth:=quote.depth;
  end if;
  next_supply:=market.supply+case p_side when 'buy' then p_amount else -p_amount end;
  if next_supply<0 then return xern_private.fail('Market holdings need reconciliation'); end if;
  start_price:=market.anchor_price+market.slope*(market.supply-market.anchor_supply);
  end_price:=market.anchor_price+market.slope*(next_supply-market.anchor_supply);
  total:=abs((xern_private.stock_price_integral(end_price)-xern_private.stock_price_integral(start_price))/market.slope);
  if total>9007199254740991 then return xern_private.fail('Trade amount too large'); end if;
  -- Directional rounding prevents small repeated trades from minting whole Xergs.
  value:=case p_side when 'buy' then ceil(total) else floor(total) end;
  if p_side='buy' then
    if wallet<value then return xern_private.fail('Not enough Xergs including price impact'); end if;
    insert into public.holdings values(uid,p_symbol,p_amount,value)
      on conflict(owner_id,symbol) do update set shares=holdings.shares+excluded.shares,cost=holdings.cost+excluded.cost;
    wallet:=wallet-value;
  else
    update public.holdings set shares=shares-p_amount,cost=floor(cost::numeric*(shares-p_amount)/shares)
      where owner_id=uid and symbol=p_symbol;
    wallet:=wallet+value;
  end if;
  update public.profiles set money=wallet where id=uid;
  next_price:=round(greatest(0.10,least(100000000,end_price)),2);
  update xern_private.stock_liquidity set supply=next_supply,anchor_supply=market.anchor_supply,
    anchor_price=market.anchor_price,slope=market.slope,last_price=next_price,depth=market.depth where symbol=p_symbol;
  if next_price<>quote.price then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value,
    'average_price',value::numeric/p_amount,'price',next_price);
end
$$;
