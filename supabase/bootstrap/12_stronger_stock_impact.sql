create or replace function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=xern_private.player(); quote public.stock_quotes; holding public.holdings; wallet bigint;
  value bigint; next_price numeric;
begin
  if p_amount is null or p_amount not between 1 and 1000000000 then return xern_private.fail('whole_shares_required'); end if;
  if p_side is null or p_side not in ('buy','sell') then return xern_private.fail('Invalid trade side'); end if;
  select money into wallet from public.profiles where id=uid for update;
  select * into quote from public.stock_quotes where symbol=p_symbol for update;
  if not found then return xern_private.fail('Unknown stock'); end if;
  select * into holding from public.holdings where owner_id=uid and symbol=p_symbol;
  if p_amount*quote.price>9007199254740991 then return xern_private.fail('Trade amount too large'); end if;
  value:=round(p_amount*quote.price);
  if value<1 then return xern_private.fail('too_small'); end if;
  if p_side='buy' then
    if wallet<value then return xern_private.fail('Not enough Xergs'); end if;
    insert into public.holdings values(uid,p_symbol,p_amount,value)
    on conflict(owner_id,symbol) do update set shares=holdings.shares+excluded.shares,cost=holdings.cost+excluded.cost;
    wallet:=wallet-value;
  else
    if coalesce(holding.shares,0)<p_amount then return xern_private.fail('Not enough shares'); end if;
    update public.holdings set shares=shares-p_amount,cost=floor(cost::numeric*(shares-p_amount)/shares)
      where owner_id=uid and symbol=p_symbol;
    wallet:=wallet+value;
  end if;
  update public.profiles set money=wallet where id=uid;
  next_price:=greatest(0.10,least(100000000,round(quote.price+
    (case p_side when 'buy' then 1 else -1 end)*least(2,quote.price*0.04,2*p_amount*quote.price*quote.price/greatest(1000000,quote.depth*400)),2)));
  if next_price<>quote.price then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value);
end
$$;
