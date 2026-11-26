create or replace function xern_private.stock_flat_quote(p_uid uuid,p_symbol text,p_side text,p_amount bigint)
returns jsonb language plpgsql stable set search_path='' as $$
declare q public.stock_quotes; m xern_private.stock_liquidity; h public.holdings;
  position xern_private.stock_position_basis; wallet bigint; others numeric; basis numeric;
  new_supply numeric; next_price numeric; raw_price numeric; raw_next numeric; unit_price numeric; sell_price numeric; value numeric; maximum bigint;
begin
  if p_amount is null or p_amount not between 1 and 1000000000 or p_side is null or p_side not in ('buy','sell') then
    return xern_private.fail('Enter a positive whole number of shares');
  end if;
  select * into q from public.stock_quotes where symbol=p_symbol;
  if not found then return xern_private.fail('Unknown stock'); end if;
  select money into wallet from public.profiles where id=p_uid;
  select * into h from public.holdings where owner_id=p_uid and symbol=p_symbol;
  select * into m from xern_private.stock_liquidity where symbol=p_symbol;
  if not found then
    select coalesce(sum(shares),0) into m.supply from public.holdings where symbol=p_symbol;
    m.anchor_supply:=m.supply;m.anchor_price:=q.price;
    m.slope:=4*q.price*q.price/greatest(1000000,q.depth*400);m.depth:=q.depth;
  else
    -- Market ticks translate the curve; they must not amplify trade impact.
    m.anchor_price:=m.anchor_price+(q.price-m.last_price);
    if m.depth<>q.depth then
      m.anchor_price:=m.anchor_price+m.slope*(m.supply-m.anchor_supply);
      m.anchor_supply:=m.supply;
      m.slope:=m.slope*greatest(1000000,m.depth*400)/greatest(1000000,q.depth*400);
      m.depth:=q.depth;
    end if;
  end if;
  others:=coalesce((select total from xern_private.stock_movements where symbol=p_symbol),0)-
    coalesce((select total from xern_private.stock_player_impact where owner_id=p_uid and symbol=p_symbol),0);
  select * into position from xern_private.stock_position_basis where owner_id=p_uid and symbol=p_symbol;
  basis:=case when found then position.basis_value+coalesce(h.shares,0)*(others-position.other_index) else coalesce(h.cost,0) end;
  new_supply:=m.supply+case p_side when 'buy' then p_amount else -p_amount end;
  raw_price:=greatest(1,least(100000000,m.anchor_price+m.slope*(m.supply-m.anchor_supply)));
  raw_next:=greatest(1,least(100000000,m.anchor_price+m.slope*(new_supply-m.anchor_supply)));
  next_price:=round(raw_next);
  if p_side='buy' then
    unit_price:=q.price;
    maximum:=least(1000000000,floor(wallet/q.price))::bigint;
  else
    -- Own purchases cannot raise the cash-out price. Other players and market moves can.
    sell_price:=greatest(0,least(next_price,basis/nullif(h.shares,0)));
    unit_price:=floor(sell_price);
    maximum:=least(1000000000,floor(coalesce(h.shares,0)))::bigint;
  end if;
  value:=floor(case p_side when 'buy' then unit_price*p_amount else sell_price*p_amount end);
  return jsonb_build_object('ok',true,'value',value,'unit_price',unit_price,'shares',p_amount,
    'price',next_price,'can_trade',value<=9007199254740991 and case p_side when 'buy' then value<=wallet else p_amount<=coalesce(h.shares,0) and new_supply>=0 end,
    'affordable_shares',maximum,'movement',raw_next-raw_price,'other_index',others,'basis_value',basis,'supply',new_supply,
    'anchor_supply',m.anchor_supply,'anchor_price',m.anchor_price,'slope',m.slope,'depth',m.depth);
end
$$;


create or replace function xern_private.stock_quote(p_symbol text,p_side text,p_amount bigint) returns jsonb
language sql stable security definer set search_path='' as $$
  select xern_private.stock_flat_quote(xern_private.player(),p_symbol,p_side,p_amount)-
    array['movement','other_index','basis_value','supply','anchor_supply','anchor_price','slope','depth']
$$;
create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint,p_expected_price numeric,p_expected_value bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); q public.stock_quotes; h public.holdings; d jsonb;
  wallet bigint; value bigint; basis numeric; next_price numeric; change numeric;
begin
  perform 1 from public.profiles where id=uid for update;
  select * into q from public.stock_quotes where symbol=p_symbol for update;
  if not found then return xern_private.fail('Unknown stock'); end if;
  d:=xern_private.stock_flat_quote(uid,p_symbol,p_side,p_amount);
  if not coalesce((d->>'ok')::boolean,false) then return d; end if;
  if (p_expected_price is not null and p_expected_price<>(d->>'unit_price')::numeric) or
     (p_expected_value is not null and p_expected_value<>(d->>'value')::numeric) then
    return xern_private.fail('price_changed')||jsonb_build_object('unit_price',(d->>'unit_price')::numeric,'value',(d->>'value')::numeric);
  end if;
  if not (d->>'can_trade')::boolean then
    return xern_private.fail(case when p_side='buy' then 'Not enough Xergs. Use Buy Max or a smaller quantity' else 'Not enough shares' end);
  end if;
  select * into h from public.holdings where owner_id=uid and symbol=p_symbol;
  value:=(d->>'value')::numeric::bigint;
  if p_side='buy' then
    insert into public.holdings values(uid,p_symbol,p_amount,value)
      on conflict(owner_id,symbol) do update set shares=holdings.shares+excluded.shares,cost=holdings.cost+excluded.cost;
    basis:=(d->>'basis_value')::numeric+value;
    update public.profiles set money=money-value where id=uid returning money into wallet;
  else
    update public.holdings set shares=shares-p_amount,cost=floor(cost::numeric*(shares-p_amount)/shares) where owner_id=uid and symbol=p_symbol;
    basis:=(d->>'basis_value')::numeric*(h.shares-p_amount)/h.shares;
    update public.profiles set money=money+value where id=uid returning money into wallet;
  end if;
  insert into xern_private.stock_position_basis values(uid,p_symbol,basis,(d->>'other_index')::numeric)
    on conflict(owner_id,symbol) do update set basis_value=excluded.basis_value,other_index=excluded.other_index;
  next_price:=(d->>'price')::numeric;
  insert into xern_private.stock_liquidity(symbol,supply,anchor_supply,anchor_price,slope,last_price,depth)
    values(p_symbol,(d->>'supply')::numeric,(d->>'anchor_supply')::numeric,(d->>'anchor_price')::numeric,
      (d->>'slope')::numeric,next_price,(d->>'depth')::numeric)
    on conflict(symbol) do update set supply=excluded.supply,anchor_supply=excluded.anchor_supply,
      anchor_price=excluded.anchor_price,slope=excluded.slope,last_price=excluded.last_price,depth=excluded.depth;
  change:=(d->>'movement')::numeric;
  insert into xern_private.stock_movements values(p_symbol,change)
    on conflict(symbol) do update set total=stock_movements.total+excluded.total;
  insert into xern_private.stock_player_impact values(uid,p_symbol,change)
    on conflict(owner_id,symbol) do update set total=stock_player_impact.total+excluded.total;
  if next_price<>q.price then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value,
    'unit_price',(d->>'unit_price')::numeric,'price',next_price);
end
$$;

revoke all on function xern_private.stock_trade(text,text,bigint,numeric,bigint) from public,anon;
grant execute on function xern_private.stock_trade(text,text,bigint,numeric,bigint) to authenticated;
create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint,p_expected_price numeric) returns jsonb
language sql security definer set search_path='' as $$
select xern_private.stock_trade(p_symbol,p_side,p_amount,p_expected_price,null::bigint)
$$;
create function public.stock_trade(p_symbol text,p_side text,p_amount bigint,p_expected_price numeric,p_expected_value bigint) returns jsonb
language sql set search_path='' as $$
select xern_private.stock_trade(p_symbol,p_side,p_amount,p_expected_price,p_expected_value)
$$;
revoke all on function public.stock_trade(text,text,bigint,numeric,bigint) from public,anon;
grant execute on function public.stock_trade(text,text,bigint,numeric,bigint) to authenticated;
notify pgrst,'reload schema';
