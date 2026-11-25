create or replace function xern_private.stock_flat_quote(p_uid uuid,p_symbol text,p_side text,p_amount bigint)
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

-- Start the stable curve at today's price without changing balances or quotes.
update xern_private.stock_liquidity m set anchor_supply=m.supply,anchor_price=q.price,
  last_price=q.price
from public.stock_quotes q where q.symbol=m.symbol;
notify pgrst,'reload schema';
