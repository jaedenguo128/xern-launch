create function xern_private.stock_order_total(p_anchor_price numeric,p_anchor_supply numeric,p_slope numeric,p_supply numeric,p_delta numeric)
returns numeric language sql immutable set search_path='' as $$
  select abs((xern_private.stock_price_integral(p_anchor_price+p_slope*(p_supply+p_delta-p_anchor_supply))-
    xern_private.stock_price_integral(p_anchor_price+p_slope*(p_supply-p_anchor_supply)))/p_slope)
$$;
revoke all on function xern_private.stock_order_total(numeric,numeric,numeric,numeric,numeric) from public,anon,authenticated;

-- Rebase existing markets once so the gentler impact also applies to active stocks.
update xern_private.stock_liquidity m set anchor_supply=m.supply,anchor_price=q.price,
  slope=q.price*q.price/greatest(1000000,q.depth*400),last_price=q.price,depth=q.depth
from public.stock_quotes q where q.symbol=m.symbol;

create function xern_private.stock_quote(p_symbol text,p_side text,p_amount bigint) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); quote public.stock_quotes; market xern_private.stock_liquidity;
  wallet bigint; owned numeric; total numeric; value numeric; low bigint:=0; high bigint; middle bigint;
begin
  if p_amount is null or p_amount not between 1 and 1000000000 or p_side is null or p_side not in ('buy','sell') then
    return xern_private.fail('Enter a positive whole number of shares');
  end if;
  select money into wallet from public.profiles where id=uid;
  select * into quote from public.stock_quotes where symbol=p_symbol;
  if not found then return xern_private.fail('Unknown stock'); end if;
  select coalesce(sum(shares),0) into owned from public.holdings where owner_id=uid and symbol=p_symbol;
  select * into market from xern_private.stock_liquidity where symbol=p_symbol;
  if not found then
    select coalesce(sum(shares),0) into market.supply from public.holdings where symbol=p_symbol;
    market.anchor_supply:=market.supply;market.anchor_price:=quote.price;
    market.slope:=quote.price*quote.price/greatest(1000000,quote.depth*400);
  elsif market.last_price<>quote.price or market.depth<>quote.depth then
    market.anchor_supply:=market.supply;market.anchor_price:=quote.price;
    market.slope:=quote.price*quote.price/greatest(1000000,quote.depth*400);
  end if;
  total:=xern_private.stock_order_total(market.anchor_price,market.anchor_supply,market.slope,market.supply,
    case p_side when 'buy' then p_amount else -p_amount end);
  value:=case p_side when 'buy' then ceil(total) else floor(total) end;
  if p_side='buy' then
    high:=least(1000000000,floor(wallet/0.10))::bigint;
    while low<high loop
      middle:=low+(high-low+1)/2;
      if ceil(xern_private.stock_order_total(market.anchor_price,market.anchor_supply,market.slope,market.supply,middle))<=wallet then
        low:=middle;
      else high:=middle-1;
      end if;
    end loop;
  else low:=least(1000000000,floor(owned))::bigint;
  end if;
  return jsonb_build_object('ok',true,'value',value,'shares',p_amount,'average_price',value/p_amount,
    'can_trade',value<=9007199254740991 and case p_side when 'buy' then value<=wallet else p_amount<=owned end,
    'affordable_shares',low);
end
$$;
revoke all on function xern_private.stock_quote(text,text,bigint) from public,anon;
grant execute on function xern_private.stock_quote(text,text,bigint) to authenticated;
create function public.stock_quote(p_symbol text,p_side text,p_amount bigint) returns jsonb
language sql stable set search_path='' as $$select xern_private.stock_quote(p_symbol,p_side,p_amount)$$;
revoke all on function public.stock_quote(text,text,bigint) from public,anon;
grant execute on function public.stock_quote(text,text,bigint) to authenticated;

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
      quote.price*quote.price/greatest(1000000,quote.depth*400),quote.price,quote.depth
    from public.holdings where symbol=p_symbol
    on conflict(symbol) do nothing;
  select * into market from xern_private.stock_liquidity where symbol=p_symbol for update;
  -- Scheduled market moves start a new curve at the current holdings and quote.
  if market.last_price<>quote.price or market.depth<>quote.depth then
    market.anchor_supply:=market.supply;
    market.anchor_price:=quote.price;
    market.slope:=quote.price*quote.price/greatest(1000000,quote.depth*400);
    market.depth:=quote.depth;
  end if;
  next_supply:=market.supply+case p_side when 'buy' then p_amount else -p_amount end;
  if next_supply<0 then return xern_private.fail('Market holdings need reconciliation'); end if;
  start_price:=market.anchor_price+market.slope*(market.supply-market.anchor_supply);
  end_price:=market.anchor_price+market.slope*(next_supply-market.anchor_supply);
  total:=xern_private.stock_order_total(market.anchor_price,market.anchor_supply,market.slope,market.supply,next_supply-market.supply);
  if total>9007199254740991 then return xern_private.fail('Trade amount too large'); end if;
  -- Directional rounding prevents small repeated trades from minting whole Xergs.
  value:=case p_side when 'buy' then ceil(total) else floor(total) end;
  if p_side='buy' then
    if wallet<value then return xern_private.fail('Not enough Xergs for this order. Try a smaller quantity or Buy Max'); end if;
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

notify pgrst,'reload schema';
