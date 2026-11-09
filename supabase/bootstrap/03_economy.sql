create function xern_private.gift_status() returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('ok',true,'streak',streak,
    'seconds_left',greatest(0,ceil(extract(epoch from gift_at+interval '1 day'-now()))),
    'next_reward',100+least(30,case when gift_at>now()-interval '2 days' then streak else 0 end)*25)
  from public.profiles where id=xern_private.player()
$$;
create function xern_private.claim_daily_gift() returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); player public.profiles; reward integer; next_streak integer;
begin
  select * into player from public.profiles where id=uid for update;
  if player.gift_at>now()-interval '1 day' then
    return xern_private.fail('too_soon') || jsonb_build_object('seconds_left',ceil(extract(epoch from player.gift_at+interval '1 day'-now())));
  end if;
  next_streak:=case when player.gift_at>now()-interval '2 days' then player.streak+1 else 1 end;
  reward:=100+least(30,next_streak-1)*25;
  update public.profiles set money=money+reward, gift_at=now(), streak=next_streak where id=uid returning money into player.money;
  return jsonb_build_object('ok',true,'money',player.money,'reward',reward,'streak',next_streak,'next_reward',100+least(30,next_streak)*25);
end
$$;

create function xern_private.airdrop_play(p_game text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); previous public.airdrop_claims; rules record;
  today date:=(now() at time zone 'America/New_York')::date; used integer; reward integer; wait interval;
begin
  select * into rules from (values ('case',3600,100,80,350),('tap',5,25,1,5),('deck',2700,100,25,150),
    ('spin',1800,100,35,185),('stack',480,100,15,60),('bounce',60,3,10,30),
    ('target',45,3,8,25),('reaction',45,3,10,30)) r(game,seconds,quota,low,high) where game=p_game;
  if not found then return xern_private.fail('Unknown airdrop game'); end if;
  wait:=make_interval(secs=>rules.seconds);
  perform 1 from public.profiles where id=uid for update;
  select * into previous from public.airdrop_claims where owner_id=uid and game=p_game;
  used:=case when previous.day_utc=today then previous.plays_today else 0 end;
  if used>=rules.quota or previous.last_claim_at+wait>now() then
    return xern_private.fail('Next reward is on cooldown')||jsonb_build_object('next_at',previous.last_claim_at+wait,'plays_today',used);
  end if;
  reward:=rules.low+floor(random()*(rules.high-rules.low+1))::integer;
  insert into public.airdrop_claims values(uid,p_game,now(),used+1,today)
  on conflict(owner_id,game) do update set last_claim_at=excluded.last_claim_at,plays_today=excluded.plays_today,day_utc=excluded.day_utc;
  update public.profiles set money=money+reward where id=uid;
  return jsonb_build_object('ok',true,'reward',reward,'next_at',now()+wait,'plays_today',used+1);
end
$$;
create function xern_private.xern_christmas_status() returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('ok',true,'day',(now() at time zone 'UTC')::date,
    'opened',coalesce(jsonb_agg(color order by color),'[]'::jsonb),'net',coalesce(sum(reward),0))
  from xern_private.presents where owner_id=xern_private.player() and day=(now() at time zone 'UTC')::date
$$;
create function xern_private.xern_christmas_open(p_color text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); today date:=(now() at time zone 'UTC')::date; wallet bigint; reward integer;
begin
  if p_color is null or p_color not in ('red','green','blue') then return xern_private.fail('Unknown present'); end if;
  select money into wallet from public.profiles where id=uid for update;
  if exists(select 1 from xern_private.presents where owner_id=uid and day=today and color=p_color) then return xern_private.fail('Present already opened'); end if;
  reward:=case when random()<0.07 then -least(wallet,1+floor(random()*300)::integer) else 1+floor(random()*1000)::integer end;
  insert into xern_private.presents values(uid,today,p_color,reward);
  update public.profiles set money=money+reward where id=uid returning money into wallet;
  return xern_private.xern_christmas_status()||jsonb_build_object('money',wallet,'reward',reward);
end
$$;

create function xern_private.xern_gift_player(p_username text,p_amount bigint,p_request_id uuid) returns jsonb
language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); recipient_id uuid; fee bigint; wallet bigint;
begin
  if p_amount is null or p_amount not between 1 and 1000000000000 or p_request_id is null then return xern_private.fail('Enter a valid transfer amount'); end if;
  select id into recipient_id from public.profiles where lower(username)=lower(btrim(p_username));
  if recipient_id is null or recipient_id=uid then return xern_private.fail('Choose another existing player'); end if;
  perform 1 from public.profiles where id in(uid,recipient_id) order by id for update;
  select money into wallet from public.profiles where id=uid;
  if exists(select 1 from xern_private.transfers where sender=uid and request_id=p_request_id) then
    if not exists(select 1 from xern_private.transfers where sender=uid and request_id=p_request_id and recipient=recipient_id and amount=p_amount) then
      return xern_private.fail('Transfer ID already used');
    end if;
    return jsonb_build_object('ok',true,'money',wallet);
  end if;
  fee:=(p_amount+1999)/2000;
  if wallet<p_amount+fee then return xern_private.fail('Not enough Xergs to cover the gift and fee'); end if;
  update public.profiles set money=money-p_amount-fee where id=uid returning money into wallet;
  update public.profiles set money=money+p_amount where id=recipient_id;
  insert into xern_private.transfers values(uid,p_request_id,recipient_id,p_amount,fee);
  return jsonb_build_object('ok',true,'money',wallet);
end
$$;

create function xern_private.stock_trade(p_symbol text,p_side text,p_amount bigint) returns jsonb language plpgsql set search_path='' as $$
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
    (case p_side when 'buy' then 1 else -1 end)*least(1,quote.price*0.02,p_amount*quote.price/greatest(1000000,quote.depth*400)),2)));
  if next_price<>quote.price then
    update public.stock_quotes set price=next_price where symbol=p_symbol;
    insert into public.stock_history(symbol,price) values(p_symbol,next_price);
  end if;
  return jsonb_build_object('ok',true,'money',wallet,'shares',p_amount,'value',value);
end
$$;
create function xern_private.stock_claim_dividends() returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); today date:=(now() at time zone 'UTC')::date; paid bigint; wallet bigint;
begin
  select money into wallet from public.profiles where id=uid for update;
  select floor(coalesce(sum(h.shares*q.price),0)*0.005) into paid
    from public.holdings h join public.stock_quotes q using(symbol) where h.owner_id=uid;
  if paid>0 then
    insert into public.stock_dividend_payouts(owner_id,day,amount) values(uid,today,paid) on conflict do nothing;
    if found then update public.profiles set money=money+paid where id=uid returning money into wallet; else paid:=0; end if;
  end if;
  return jsonb_build_object('ok',true,'paid',paid,'money',wallet);
end
$$;
create function xern_private.stock_market_tick() returns void language plpgsql set search_path='' as $$
begin
  with changes as (
    update public.stock_quotes q set price=greatest(.10,round((q.price*.998+q.base_price*.002)*(1+(random()-.5)*.05),2)),
      price_24h=coalesce((select h.price from public.stock_history h where h.symbol=q.symbol
        and h.created_at<=now()-interval '1 day' order by h.created_at desc limit 1),q.base_price)
    returning symbol,price
  ) insert into public.stock_history(symbol,price) select symbol,price from changes;
  delete from public.stock_history where created_at<now()-interval '7 days';
  delete from xern_private.signup_limits where window_at<now()-interval '1 day';
end
$$;

create function xern_private.hand_score(cards integer[]) returns integer language sql immutable set search_path='' as $$
  with totals as (
    select coalesce(sum(case when i%13=0 then 11 else least(10,i%13+1) end),0)::integer as score,
      count(*) filter(where i%13=0)::integer as aces from unnest(cards) i
  )
  select score-least(aces,greatest(0,(score-12)/10))*10 from totals
$$;
create function xern_private.casino_action(p_game text,p_action text,p_bet bigint default null,p_pick integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); wallet bigint; round xern_private.casino_rounds;
  payout bigint:=0; result jsonb:='{}'; active boolean:=false; player integer[]; dealer integer[]; deck integer[];
  mines integer[]; revealed integer[]; total integer; slot integer; dice integer; steps integer;
  multipliers numeric[]:=array[10,5,2,1.4,.8,.2,.8,1.4,2,5,10];
begin
  if p_game is null or p_game not in ('dice','plinko','mines','blackjack') then return xern_private.fail('Unknown casino game'); end if;
  select money into wallet from public.profiles where id=uid for update;
  select * into round from xern_private.casino_rounds where owner_id=uid and game=p_game;
  if p_action='status' and round.owner_id is null then return jsonb_build_object('ok',true,'active',false,'money',wallet); end if;
  if p_action='start' then
    if round.owner_id is not null then return xern_private.fail('Finish your active round first'); end if;
    if p_bet is null or p_bet not between 1 and least(wallet,1000000000) then return xern_private.fail('Invalid bet or insufficient Xergs'); end if;
    if p_game='dice' and (p_pick is null or p_pick not between 5 and 95) then return xern_private.fail('Invalid dice target'); end if;
    wallet:=wallet-p_bet;
    if p_game='dice' then
      dice:=1+floor(random()*100)::integer;
      if dice>p_pick then payout:=floor(p_bet*98.0/(100-p_pick)); end if;
      result:=jsonb_build_object('roll',dice);
    elsif p_game='plinko' then
      select count(*) filter(where random()<.5) into slot from generate_series(1,10);
      payout:=floor(p_bet*multipliers[slot+1]);
      result:=jsonb_build_object('slot',slot,'multiplier',multipliers[slot+1]);
    elsif p_game='mines' then
      select array(select i from generate_series(0,24) i order by random() limit 3) into mines;
      revealed:=array[]::integer[];
      active:=true;
    else
      select array(select i from generate_series(0,51) i order by random()) into deck;
      player:=deck[1:2]; dealer:=deck[3:4]; deck:=deck[5:52]; active:=true;
    end if;
    round.bet:=p_bet;
  else
    if round.owner_id is null then return xern_private.fail('Start a round first'); end if;
    active:=true;
    if p_game='mines' then
      mines:=array(select jsonb_array_elements_text(round.state->'mines')::integer);
      revealed:=array(select jsonb_array_elements_text(round.state->'revealed')::integer);
      if p_action='reveal' then
        if p_pick is null or p_pick not between 0 and 24 or p_pick=any(revealed) then return xern_private.fail('Choose an unrevealed tile'); end if;
        if p_pick=any(mines) then active:=false; result:=jsonb_build_object('bomb',p_pick);
        else revealed:=array_append(revealed,p_pick);
          if cardinality(revealed)=22 then active:=false; payout:=floor(round.bet*power(1.12::numeric,22)); end if;
        end if;
      elsif p_action='cashout' and cardinality(revealed)>0 then
        active:=false; payout:=floor(round.bet*power(1.12::numeric,cardinality(revealed)));
      elsif p_action<>'status' then return xern_private.fail('Reveal a gem before cashing out'); end if;
    elsif p_game='blackjack' then
      player:=array(select jsonb_array_elements_text(round.state->'player')::integer);
      dealer:=array(select jsonb_array_elements_text(round.state->'dealer')::integer);
      deck:=array(select jsonb_array_elements_text(round.state->'deck')::integer);
      if p_action='hit' then
        player:=array_append(player,deck[1]); deck:=deck[2:];
        if xern_private.hand_score(player)>21 then active:=false; end if;
      elsif p_action='stand' then
        active:=false;
        while xern_private.hand_score(dealer)<17 loop dealer:=array_append(dealer,deck[1]); deck:=deck[2:]; end loop;
        total:=xern_private.hand_score(dealer);
        payout:=case when total>21 or xern_private.hand_score(player)>total then 2*round.bet when xern_private.hand_score(player)=total then round.bet else 0 end;
      elsif p_action<>'status' then return xern_private.fail('Choose Hit or Stand'); end if;
    end if;
  end if;
  if p_game='mines' then
    result:=result||jsonb_build_object('revealed',revealed,'cashout',floor(round.bet*power(1.12::numeric,cardinality(revealed))));
  elsif p_game='blackjack' then
    result:=jsonb_build_object('player',player,'dealer',case when active then array[-1,dealer[2]] else dealer end,
      'player_score',xern_private.hand_score(player),'dealer_score',case when not active then xern_private.hand_score(dealer) end);
  end if;
  if active and p_action<>'status' then
    insert into xern_private.casino_rounds(owner_id,game,bet,state)
      values(uid,p_game,round.bet,jsonb_build_object('mines',mines,'revealed',revealed,'player',player,'dealer',dealer,'deck',deck))
      on conflict(owner_id,game) do update set state=excluded.state,updated_at=now();
  elsif not active then
    delete from xern_private.casino_rounds where owner_id=uid and game=p_game;
  end if;
  if p_action='start' or payout>0 then
    wallet:=wallet+payout; update public.profiles set money=wallet where id=uid;
  end if;
  return result||jsonb_build_object('ok',true,'active',active,'money',wallet,'bet',round.bet,'payout',payout);
end
$$;
