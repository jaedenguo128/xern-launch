create function xern_private.xern_player_directory() returns table(id uuid,username text) language sql stable set search_path='' as $$
  select p.id,p.username from public.profiles p where xern_private.player() is not null order by lower(p.username)
$$;
create function xern_private.xern_home_land_leaderboard() returns table(username text,acres bigint)
language sql stable set search_path='' as $$
  select p.username,count(*)*5000 from public.land_claims l join public.profiles p on p.id=l.owner_id
  where xern_private.player() is not null group by p.id order by count(*) desc,p.username limit 10
$$;
create function xern_private.xern_wealthiest_players_top10() returns table(username text,xergs bigint)
language sql stable set search_path='' as $$
  select p.username,p.money from public.profiles p where xern_private.player() is not null order by p.money desc,p.username limit 10
$$;
create function xern_private.clan_stats()
returns table(id bigint,name text,color text,leader_id uuid,capacity integer,"public" boolean,members bigint,plots bigint,acres bigint)
language sql stable set search_path='' as $$
  select c.id,c.name,c.color,c.leader_id,c.capacity,c.public,count(distinct m.user_id),count(l.country_key),count(l.country_key)*5000
  from xern_private.clans c left join public.xern_clan_members m on m.clan_id=c.id
  left join public.land_claims l on l.owner_id=m.user_id group by c.id
  order by count(l.country_key) desc,c.id
$$;
create function xern_private.xern_clan_stats()
returns table(id bigint,name text,color text,leader_id uuid,capacity integer,"public" boolean,members bigint,plots bigint,acres bigint)
language sql stable set search_path='' as $$
  select c.* from xern_private.clan_stats() c where xern_private.player() is not null
$$;
create function xern_private.xern_clan_strength()
returns table(clan_id bigint,troops bigint,attack bigint)
language sql stable set search_path='' as $$
  select m.clan_id,coalesce(sum(u.unit_count),0),coalesce(sum(u.unit_count*u.attack_value),0)
  from public.xern_clan_members m left join public.team_units u on u.owner_id=m.user_id
  where xern_private.player() is not null group by m.clan_id
$$;
create function xern_private.xern_clan_action(p_action text,p_name text default null,p_public boolean default null,
  p_clan bigint default null,p_target text default null)
returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player(); clan xern_private.clans; target uuid; price integer; wallet bigint;
  colors text[]:=array['#4da3ff','#36bd8c','#d883e9','#e5a130','#f05763','#8c82f0','#0bbdd6'];
begin
  perform pg_advisory_xact_lock(18002);
  select c.* into clan from xern_private.clans c join public.xern_clan_members m on m.clan_id=c.id where m.user_id=uid;
  if p_action='create' then
    if clan.id is not null then return xern_private.fail('Leave your current clan first'); end if;
    if p_name is null or length(btrim(p_name)) not between 3 and 30 then return xern_private.fail('Clan name must be 3–30 characters'); end if;
    if exists(select 1 from xern_private.clans where lower(name)=lower(btrim(p_name))) then return xern_private.fail('Clan name already taken'); end if;
    update public.profiles set money=money-100000 where id=uid and money>=100000 returning money into wallet;
    if not found then return xern_private.fail('You need 100,000 Xergs'); end if;
    insert into xern_private.clans(name,color,leader_id,public) values(btrim(p_name),colors[1+floor(random()*cardinality(colors))::integer],uid,coalesce(p_public,true))
      returning * into clan;
    insert into public.xern_clan_members values(uid,clan.id);
  elsif p_action='join' then
    if clan.id is not null then return xern_private.fail('Leave your current clan first'); end if;
    select * into clan from xern_private.clans where id=p_clan;
    if clan.id is null then return xern_private.fail('Clan not found'); end if;
    if not clan.public and not exists(select 1 from public.xern_clan_invites where invited_user=uid and clan_id=clan.id) then return xern_private.fail('An invitation is required'); end if;
    if (select count(*) from public.xern_clan_members where clan_id=clan.id)>=clan.capacity then return xern_private.fail('Clan is full'); end if;
    insert into public.xern_clan_members values(uid,clan.id);
    delete from public.xern_clan_invites where invited_user=uid;
  elsif p_action='leave' then
    if clan.id is null then return xern_private.fail('You are not in a clan'); end if;
    if clan.leader_id=uid then return xern_private.fail('Transfer leadership or disband first'); end if;
    delete from public.xern_clan_members where user_id=uid;
  else
    if clan.leader_id is distinct from uid then return xern_private.fail('Only the clan leader can do this'); end if;
    case p_action
      when 'visibility' then update xern_private.clans set public=coalesce(p_public,public) where id=clan.id;
      when 'upgrade' then
        if clan.capacity>=10 then return xern_private.fail('Clan already has 10 slots'); end if;
        price:=(clan.capacity-4)*100000;
        update public.profiles set money=money-price where id=uid and money>=price returning money into wallet;
        if not found then return xern_private.fail('Not enough Xergs'); end if;
        update xern_private.clans set capacity=capacity+1 where id=clan.id;
      when 'disband' then delete from xern_private.clans where id=clan.id;
      else
        select id into target from public.profiles where lower(username)=lower(btrim(p_target));
        if target is null or target=uid then return xern_private.fail('Choose another player'); end if;
        if p_action='invite' then
          if exists(select 1 from public.xern_clan_members where user_id=target) then return xern_private.fail('Player already has a clan'); end if;
          insert into public.xern_clan_invites(clan_id,invited_user) values(clan.id,target) on conflict do nothing;
        elsif p_action in ('kick','transfer') then
          if not exists(select 1 from public.xern_clan_members where user_id=target and clan_id=clan.id) then return xern_private.fail('Player is not in your clan'); end if;
          if p_action='kick' then delete from public.xern_clan_members where user_id=target;
          else update xern_private.clans set leader_id=target where id=clan.id; end if;
        else return xern_private.fail('Unknown clan action'); end if;
    end case;
  end if;
  return jsonb_build_object('ok',true,'money',wallet);
end
$$;
create function xern_private.pay_clan_prize() returns jsonb language plpgsql set search_path='' as $$
declare today date:=(now() at time zone 'America/New_York')::date; week_start date; winner bigint;
begin
  week_start:=today-extract(dow from today)::integer;
  if not pg_try_advisory_xact_lock(18002) then return xern_private.ok(); end if;
  if exists(select 1 from xern_private.clan_payouts where week=week_start) then return xern_private.ok(); end if;
  select id into winner from xern_private.clan_stats() where plots>0 order by plots desc,id limit 1;
  -- Record the boundary even if the world starts with no eligible clans.
  insert into xern_private.clan_payouts values(week_start,winner);
  if winner is not null then
    perform 1 from public.profiles p join public.xern_clan_members m on m.user_id=p.id
      where m.clan_id=winner order by p.id for update of p;
    update public.profiles p set money=p.money+50000 from public.xern_clan_members m where m.user_id=p.id and m.clan_id=winner;
  end if;
  return jsonb_build_object('ok',true,'clan_id',winner);
end
$$;
create function xern_private.xern_clan_weekly_payout() returns jsonb language plpgsql set search_path='' as $$
begin
  perform xern_private.player();
  return xern_private.pay_clan_prize();
end
$$;
create function xern_private.xern_is_owner() returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from xern_private.owner_accounts where id=auth.uid())
$$;
create function xern_private.xern_get_home_announcement() returns text language sql stable set search_path='' as $$
  select body from xern_private.owner_content where kind='announcement'
$$;
create function xern_private.xern_get_owner_page_intro() returns text language sql stable set search_path='' as $$
  select body from xern_private.owner_content where kind='intro'
$$;
create function xern_private.update_owner_content(content_kind text,body_text text,max_length integer) returns jsonb
language plpgsql set search_path='' as $$
begin
  if not xern_private.xern_is_owner() then return xern_private.fail('Owner permission required'); end if;
  if body_text is null or length(btrim(body_text)) not between 1 and max_length then return xern_private.fail('Invalid message length'); end if;
  update xern_private.owner_content set body=btrim(body_text) where kind=content_kind;
  return xern_private.ok();
end
$$;
create function xern_private.xern_set_home_announcement(p_message text) returns jsonb language sql set search_path='' as $$
  select xern_private.update_owner_content('announcement',p_message,2000)
$$;
create function xern_private.xern_set_owner_page_intro(p_intro text) returns jsonb language sql set search_path='' as $$
  select xern_private.update_owner_content('intro',p_intro,3000)
$$;
create function xern_private.xern_send_owner_message(p_message text) returns jsonb language plpgsql set search_path='' as $$
declare uid uuid:=xern_private.player();
begin
  if p_message is null or length(btrim(p_message)) not between 1 and 2000 then return xern_private.fail('Enter a message of up to 2,000 characters'); end if;
  perform 1 from public.profiles where id=uid for update;
  if (select count(*) from xern_private.owner_messages where sender=uid and created_at>now()-interval '1 hour')>=10 then
    return xern_private.fail('Message limit reached. Try again later.');
  end if;
  insert into xern_private.owner_messages(sender,message) values(uid,btrim(p_message));
  return xern_private.ok();
end
$$;
create function xern_private.xern_read_owner_messages()
returns table(id bigint,sender_name text,message text,created_at timestamptz) language sql stable set search_path='' as $$
  select m.id,p.username,m.message,m.created_at from xern_private.owner_messages m
  join public.profiles p on p.id=m.sender where xern_private.xern_is_owner() order by m.id desc limit 200
$$;
create function xern_private.xern_delete_owner_message(p_id bigint) returns jsonb language plpgsql set search_path='' as $$
begin
  if not xern_private.xern_is_owner() then return xern_private.fail('Owner permission required'); end if;
  delete from xern_private.owner_messages where id=p_id;
  return xern_private.ok();
end
$$;
create function xern_private.xern_signup_rate_limit(p_client text) returns boolean language plpgsql set search_path='' as $$
declare n integer;
begin
  if p_client is null or p_client !~ '^[a-f0-9]{64}$' then return false; end if;
  insert into xern_private.signup_limits values(p_client,now(),1) on conflict(client) do update set
    attempts=case when signup_limits.window_at<now()-interval '1 hour' then 1 else least(signup_limits.attempts+1,1000000) end,
    window_at=case when signup_limits.window_at<now()-interval '1 hour' then now() else signup_limits.window_at end
  returning attempts into n;
  return n<=12;
end
$$;
