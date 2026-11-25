create table xern_private.stock_movements (
  symbol text primary key references public.stock_quotes on delete cascade,
  total numeric not null default 0
);
create table xern_private.stock_player_impact (
  owner_id uuid references public.profiles on delete cascade,
  symbol text references public.stock_quotes on delete cascade,
  total numeric not null default 0,
  primary key(owner_id,symbol)
);
create table xern_private.stock_position_basis (
  owner_id uuid,
  symbol text,
  basis_value numeric not null,
  other_index numeric not null,
  primary key(owner_id,symbol),
  foreign key(owner_id,symbol) references public.holdings(owner_id,symbol) on delete cascade
);
alter table xern_private.stock_movements enable row level security;
alter table xern_private.stock_player_impact enable row level security;
alter table xern_private.stock_position_basis enable row level security;
revoke all on xern_private.stock_movements,xern_private.stock_player_impact,xern_private.stock_position_basis from public,anon,authenticated;

create function xern_private.stock_flat_quote(p_uid uuid,p_symbol text,p_side text,p_amount bigint)
returns jsonb language plpgsql stable set search_path='' as $$
declare q public.stock_quotes; m xern_private.stock_liquidity; h public.holdings;
  position xern_private.stock_position_basis; wallet bigint; others numeric; basis numeric;
  new_supply numeric; next_price numeric; unit_price numeric; value numeric; maximum bigint;
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
  elsif m.last_price<>q.price or m.depth<>q.depth then
    m.anchor_supply:=m.supply;m.anchor_price:=q.price;
    m.slope:=4*q.price*q.price/greatest(1000000,q.depth*400);m.depth:=q.depth;
  end if;
  others:=coalesce((select total from xern_private.stock_movements where symbol=p_symbol),0)-
    coalesce((select total from xern_private.stock_player_impact where owner_id=p_uid and symbol=p_symbol),0);
  select * into position from xern_private.stock_position_basis where owner_id=p_uid and symbol=p_symbol;
  basis:=case when found then position.basis_value+coalesce(h.shares,0)*(others-position.other_index) else coalesce(h.cost,0) end;
  new_supply:=m.supply+case p_side when 'buy' then p_amount else -p_amount end;
  next_price:=round(greatest(1,least(100000000,m.anchor_price+m.slope*(new_supply-m.anchor_supply))));
  if p_side='buy' then
    unit_price:=q.price;
    maximum:=least(1000000000,floor(wallet/q.price))::bigint;
  else
    -- Own purchases cannot raise the cash-out price. Other players and market moves can.
    unit_price:=floor(greatest(0,least(next_price,basis/nullif(h.shares,0))));
    maximum:=least(1000000000,floor(coalesce(h.shares,0)))::bigint;
  end if;
  value:=unit_price*p_amount;
  return jsonb_build_object('ok',true,'value',value,'unit_price',unit_price,'shares',p_amount,
    'price',next_price,'can_trade',value<=9007199254740991 and case p_side when 'buy' then value<=wallet else p_amount<=coalesce(h.shares,0) and new_supply>=0 end,
    'affordable_shares',maximum,'other_index',others,'basis_value',basis,'supply',new_supply,
    'anchor_supply',m.anchor_supply,'anchor_price',m.anchor_price,'slope',m.slope,'depth',m.depth);
end
$$;
revoke all on function xern_private.stock_flat_quote(uuid,text,text,bigint) from public,anon,authenticated;

create or replace function xern_private.stock_quote(p_symbol text,p_side text,p_amount bigint) returns jsonb
language sql stable security definer set search_path='' as $$
  select xern_private.stock_flat_quote(xern_private.player(),p_symbol,p_side,p_amount)-
    array['other_index','basis_value','supply','anchor_supply','anchor_price','slope','depth']
$$;

create function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint,p_expected_price numeric) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); q public.stock_quotes; h public.holdings; d jsonb;
  wallet bigint; value bigint; basis numeric; next_price numeric; change numeric;
begin
  perform 1 from public.profiles where id=uid for update;
  select * into q from public.stock_quotes where symbol=p_symbol for update;
  if not found then return xern_private.fail('Unknown stock'); end if;
  d:=xern_private.stock_flat_quote(uid,p_symbol,p_side,p_amount);
  if not coalesce((d->>'ok')::boolean,false) then return d; end if;
  if p_expected_price is not null and p_expected_price<>(d->>'unit_price')::numeric then
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
  change:=next_price-q.price;
  insert into xern_private.stock_movements values(p_symbol,change)
    on conflict(symbol) do update set total=stock_movements.total+excluded.total;
  insert into xern_private.stock_player_impact values(uid,p_symbol,change)
    on conflict(owner_id,symbol) do update set total=stock_player_impact.total+excluded.total;
  if change<>0 then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value,
    'unit_price',(d->>'unit_price')::numeric,'price',next_price);
end
$$;

revoke all on function xern_private.stock_trade(text,text,bigint,numeric) from public,anon;
grant execute on function xern_private.stock_trade(text,text,bigint,numeric) to authenticated;
create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint) returns jsonb
language sql security definer set search_path='' as $$select xern_private.stock_trade(p_symbol,p_side,p_amount,null::numeric)$$;
create function public.stock_trade(p_symbol text,p_side text,p_amount bigint,p_expected_price numeric) returns jsonb
language sql set search_path='' as $$select xern_private.stock_trade(p_symbol,p_side,p_amount,p_expected_price)$$;
revoke all on function public.stock_trade(text,text,bigint,numeric) from public,anon;
grant execute on function public.stock_trade(text,text,bigint,numeric) to authenticated;

create or replace function xern_private.stock_market_tick() returns void language plpgsql set search_path='' as $$
begin
  perform 1 from public.stock_quotes order by symbol for update;
  with previous as materialized (select symbol,price from public.stock_quotes),
  changes as (
    update public.stock_quotes q set price=greatest(1,round((q.price*.998+q.base_price*.002)*(1+(random()::numeric-.5)*.05))),
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
