create or replace function xern_private.stock_price_integral(price numeric) returns numeric
language sql immutable set search_path='' as $$
  select case when price<1 then price-0.5
    when price>100000000 then 100000000::numeric*price-5000000000000000::numeric
    else price*price/2 end
$$;
update public.stock_quotes set price=greatest(1,round(price)),price_24h=greatest(1,round(price_24h));
update xern_private.stock_liquidity m set anchor_supply=m.supply,anchor_price=q.price,
  slope=4*q.price*q.price/greatest(1000000,q.depth*400),last_price=q.price,depth=q.depth
from public.stock_quotes q where q.symbol=m.symbol;

create or replace function xern_private.stock_quote(p_symbol text,p_side text,p_amount bigint) returns jsonb
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
    market.slope:=4*quote.price*quote.price/greatest(1000000,quote.depth*400);
  elsif market.last_price<>quote.price or market.depth<>quote.depth then
    market.anchor_supply:=market.supply;market.anchor_price:=quote.price;
    market.slope:=4*quote.price*quote.price/greatest(1000000,quote.depth*400);
  end if;
  total:=xern_private.stock_order_total(market.anchor_price,market.anchor_supply,market.slope,market.supply,
    case p_side when 'buy' then p_amount else -p_amount end);
  value:=case p_side when 'buy' then ceil(total) else floor(total) end;
  if p_side='buy' then
    high:=least(1000000000,floor(wallet))::bigint;
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
  next_price:=round(greatest(1,least(100000000,end_price)),0);
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

create or replace function xern_private.stock_market_tick() returns void language plpgsql set search_path='' as $$
begin
  with changes as (
    update public.stock_quotes q set price=greatest(1,round((q.price*.998+q.base_price*.002)*(1+(random()::numeric-.5)*.05),0)),
      price_24h=coalesce((select h.price from public.stock_history h where h.symbol=q.symbol
        and h.created_at<=now()-interval '1 day' order by h.created_at desc limit 1),q.base_price)
    returning symbol,price
  ) insert into public.stock_history(symbol,price) select symbol,price from changes;
  delete from public.stock_history where created_at<now()-interval '7 days';
  delete from xern_private.signup_limits where window_at<now()-interval '1 day';
end
$$;

create or replace function xern_private.next_exploration_plot(p_unit_id bigint,p_owner_id uuid,p_anchor text)
returns text language plpgsql set search_path='' as $$
declare center integer[]:=xern_private.plot_coordinates(p_anchor); ring integer; chosen text; ring_owned boolean; inner_radius integer; outer_radius integer;
begin
  if center is null then return null; end if;
  insert into xern_private.exploration_rings(unit_id,anchor) values(p_unit_id,p_anchor)
  on conflict(unit_id) do update set anchor=excluded.anchor,
    radius=case when exploration_rings.anchor=excluded.anchor then exploration_rings.radius else 1 end
  returning radius into ring;
  -- A wider, irregular frontier grows outward while following connected land.
  for attempt in 1..16 loop
    inner_radius:=greatest(0,ring-2);
    outer_radius:=ring+2;
    with offsets as (
      select dx,dy*direction dy from generate_series(-outer_radius,outer_radius) dx
      cross join lateral generate_series(
        case when dx*dx>inner_radius*inner_radius then 0
          else floor(sqrt((inner_radius*inner_radius-dx*dx)::numeric))::integer+1 end,
        floor(sqrt((outer_radius*outer_radius-dx*dx)::numeric))::integer
      ) dy
      cross join (values(-1),(1)) signs(direction)
      where dy>0 or direction=1
    ), candidates as (
      select 'plot:'||(center[1]+dx)||':'||(center[2]+dy) k,dx*dx+dy*dy distance
      from offsets where center[1]+dx between 0 and 8896 and center[2]+dy between 0 and 2831
)
    select
      (array_agg(k order by distance+
        abs(mod(hashtextextended(k||':'||p_unit_id,0),1000))::numeric/1000*greatest(9,ring*4),
        hashtextextended(k||':'||p_unit_id,0),k) filter (
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

notify pgrst,'reload schema';
