-- Fresh Xern V2 database. All game writes go through authenticated RPCs.
create schema xern_private;
revoke all on schema xern_private from public, anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,24}$'),
  money bigint not null default 250 check (money >= 0),
  gold bigint not null default 0 check (gold >= 0),
  team_buff_expires_at timestamptz,
  gift_at timestamptz,
  streak integer not null default 0,
  income_at timestamptz not null default now(),
  income_remainder numeric not null default 0,
  mine_remainder numeric not null default 0
);
create unique index profiles_username_ci on public.profiles (lower(username));
create function xern_private.create_player() returns trigger
language plpgsql security definer set search_path = '' as $$
declare handle text := new.raw_user_meta_data->>'username';
begin
  if (new.raw_app_meta_data->>'xern_registration') is distinct from 'true' or handle is null or handle !~ '^[A-Za-z0-9_]{3,24}$'
     or lower(new.email) is distinct from lower(handle)||'@players.example.com' then
    raise exception 'invalid Xern username';
  end if;
  insert into public.profiles(id,username) values(new.id,handle);
  return new;
end
$$;
create trigger xern_create_player after insert on auth.users
for each row execute function xern_private.create_player();

create table public.airdrop_claims (
  owner_id uuid references public.profiles on delete cascade,
  game text,
  last_claim_at timestamptz not null,
  plays_today integer not null,
  day_utc date not null,
  primary key(owner_id,game)
);
create table xern_private.presents (
  owner_id uuid references public.profiles on delete cascade,
  day date,
  color text,
  reward integer not null,
  primary key(owner_id,day,color)
);
create table xern_private.transfers (
  sender uuid references public.profiles on delete cascade,
  request_id uuid,
  recipient uuid references public.profiles on delete cascade,
  amount bigint not null,
  fee bigint not null,
  primary key(sender,request_id)
);
create table public.stock_quotes (
  symbol text primary key, name text not null,
  price numeric(14,2) not null check(price > 0),
  base_price numeric(14,2) not null,
  depth integer not null default 10000,
  price_24h numeric(14,2) not null
);
insert into public.stock_quotes(symbol,name,price,base_price,price_24h)
select symbol,name,price,price,price from (values
 ('XERG','Xerg Industries',20),('FERN','Fern Holdings',9),('BTC','Bitcoin',1000),
 ('AMMO','Ammo Works',35),('XPPL','Xpple',60),('TXLA','Txla Motors',95),
 ('NVDX','NVDX Graphics',125),('MXDF','MXDF',26),('SPCX','Space Xern',80),
 ('R6S','Rainbow Six',45),('BMH','BMH',14),('FRNW','Fern Worldwide',12),
 ('XIKY','Xiky',24),('STBX','Starbox',35),('MCX','MCX',55)
) as seed(symbol,name,price);
create table public.stock_history (
  symbol text references public.stock_quotes,
  price numeric(14,2) not null,
  created_at timestamptz not null default clock_timestamp()
);
create index stock_history_recent on public.stock_history(symbol,created_at desc);
insert into public.stock_history(symbol,price,created_at)
select symbol,price,now()-i*interval '1 hour' from public.stock_quotes cross join generate_series(0,24) i;
create table public.holdings (
  owner_id uuid references public.profiles on delete cascade, symbol text references public.stock_quotes,
  shares bigint not null check(shares >= 0), cost bigint not null check(cost >= 0),
  primary key(owner_id,symbol)
);
create table public.stock_dividend_payouts (
  owner_id uuid references public.profiles on delete cascade,
  day date, amount bigint not null, paid_at timestamptz not null default now(),
  primary key(owner_id,day)
);
create table xern_private.casino_rounds (
  owner_id uuid references public.profiles on delete cascade,
  game text,
  bet bigint not null, state jsonb not null,
  updated_at timestamptz not null default now(),
  primary key(owner_id,game)
);
create table xern_private.signup_limits (
  client text primary key, window_at timestamptz not null, attempts integer not null
);
create table xern_private.owner_accounts (
  id uuid primary key references public.profiles on delete cascade
);
create table xern_private.owner_content (kind text primary key, body text not null);
insert into xern_private.owner_content values
('announcement','Welcome to Xern! Build your fortune, make allies, and claim the world.'),
('intro','Jaeden, owner of Xern, created this game. Please send a message if you find a bug or want to report a player.');
create table xern_private.owner_messages (
  id bigint generated always as identity primary key,
  sender uuid references public.profiles on delete cascade,
  message text not null, created_at timestamptz not null default now()
);
create index owner_messages_sender on xern_private.owner_messages(sender,created_at desc);

create table public.land_claims (
  country_key text primary key,
  country_name text not null,
  owner_id uuid not null references public.profiles on delete cascade,
  owner_name text not null,
  paid integer not null default 0,
  area_km2 numeric not null default 20.234282,
  created_at timestamptz not null default now()
);
create index land_claims_owner on public.land_claims(owner_id,country_key);
create table xern_private.terrain (y integer primary key, pixels bytea not null);
create table xern_private.land_sales (
  owner_id uuid primary key references public.profiles on delete cascade,
  status text not null, sold integer not null default 0, proceeds bigint not null default 0
);
create table xern_private.unit_catalog (
  unit_name text primary key, rarity text not null, unit_type text not null,
  speed integer not null, health integer not null, attack_value integer not null,
  claim_power integer not null, gold_per_hour integer not null, buy_cost integer not null,
  upgrade_cost integer not null
);
insert into xern_private.unit_catalog values
 ('Patchrunner','common','medic',35,65,12,13,15,100,500),
 ('Dust Scout','common','trooper',40,55,24,13,15,100,500),
 ('Ironhide','common','tanker',27,95,17,13,15,100,500),
 ('Pulsekeeper','rare','medic',52,115,26,7,35,300,1000),
 ('Night Ranger','rare','trooper',64,95,45,7,35,300,1000),
 ('Bulwark Prime','rare','tanker',43,165,33,7,35,300,1000),
 ('Aether Medic','epic','medic',65,170,44,6,75,800,2500),
 ('Riftblade','epic','trooper',75,145,75,6,75,800,2500),
 ('Siegeborn','epic','tanker',56,240,55,6,75,800,2500),
 ('Phoenix Warden','legendary','medic',82,250,70,4,150,2000,5000),
 ('Storm Marshal','legendary','trooper',96,220,110,4,150,2000,5000),
 ('Titan Bastion','legendary','tanker',70,350,85,4,150,2000,5000),
 ('Deimos','mythical','tanker',110,500,180,3,300,10000,10000);
create table public.team_units (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles on delete cascade,
  unit_name text not null references xern_private.unit_catalog,
  rarity text not null, unit_type text not null,
  speed integer not null, health integer not null, claim_power integer not null, attack_value integer not null,
  unit_count integer not null default 1 check (unit_count between 1 and 500),
  stationed_plot_key text,
  gold_per_hour integer not null, level integer not null default 1, duplicate_tokens integer not null default 0,
  created_at timestamptz not null default now(),
  unique(owner_id,unit_name)
);
create table public.warfare_marches (
  unit_id bigint primary key references public.team_units on delete cascade,
  owner_id uuid not null references public.profiles on delete cascade,
  current_plot_key text not null, target_plot_key text,
  last_step_at timestamptz not null default now(), active boolean not null, mode text not null
);
create index warfare_marches_active on public.warfare_marches(last_step_at) where active;
create table public.warfare_rally_orders (
  owner_id uuid primary key references public.profiles on delete cascade,
  target_plot_key text not null, updated_at timestamptz not null default now()
);
create table public.xern_war_doctrines (
  owner_id uuid primary key references public.profiles on delete cascade,
  doctrine text not null check(doctrine in ('stationary','defensive','aggressive'))
);
create table public.warfare_assets (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles on delete cascade,
  kind text not null, plot_key text not null, expires_at timestamptz
);
create index warfare_assets_owner on public.warfare_assets(owner_id);
create table public.warfare_live_battles (
  id bigint generated always as identity primary key,
  attacker_id uuid not null references public.profiles on delete cascade,
  defender_id uuid not null references public.profiles on delete cascade,
  plot_key text not null,
  attacker_hp bigint not null, defender_hp bigint not null,
  attacker_max_hp bigint not null, defender_max_hp bigint not null,
  attacker_attack bigint not null, defender_attack bigint not null,
  round_no integer not null default 0,
  status text not null default 'active', winner text, updated_at timestamptz not null default now()
);
create unique index warfare_active_plot on public.warfare_live_battles(plot_key) where status='active';
create index warfare_battles_attacker on public.warfare_live_battles(attacker_id,id desc);
create index warfare_battles_defender on public.warfare_live_battles(defender_id,id desc);

create table xern_private.clans (
  id bigint generated always as identity primary key,
  name text not null,
  color text not null,
  leader_id uuid not null references public.profiles on delete cascade,
  capacity integer not null default 5 check(capacity between 5 and 10),
  public boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index clans_name_ci on xern_private.clans(lower(name));
create table public.xern_clan_members (
  user_id uuid primary key references public.profiles on delete cascade,
  clan_id bigint not null references xern_private.clans on delete cascade
);
create index clan_members_clan on public.xern_clan_members(clan_id);
create table public.xern_clan_invites (
  id bigint generated always as identity primary key,
  clan_id bigint not null references xern_private.clans on delete cascade,
  invited_user uuid not null references public.profiles on delete cascade,
  unique(clan_id,invited_user)
);
create table xern_private.clan_payouts (week date primary key, clan_id bigint);

do $$
declare tab text;
begin
  foreach tab in array array['profiles','airdrop_claims','holdings','stock_dividend_payouts','team_units','land_claims',
    'stock_quotes','stock_history','warfare_assets','warfare_live_battles','warfare_marches','warfare_rally_orders',
    'xern_war_doctrines','xern_clan_members','xern_clan_invites'] loop
    execute format('alter table public.%I enable row level security',tab);
    execute format('revoke all on table public.%I from public, anon, authenticated',tab);
    execute format('grant select on public.%I to authenticated',tab);
  end loop;
  foreach tab in array array['airdrop_claims','holdings','stock_dividend_payouts','team_units','warfare_rally_orders','xern_war_doctrines'] loop
    execute format('create policy own_rows on public.%I for select to authenticated using ((select auth.uid()) = owner_id)',tab);
  end loop;
  foreach tab in array array['land_claims','stock_quotes','stock_history','warfare_assets','warfare_marches','xern_clan_members'] loop
    execute format('create policy players_read on public.%I for select to authenticated using (true)',tab);
  end loop;
end
$$;
create policy own_profile on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy own_invite on public.xern_clan_invites for select to authenticated using ((select auth.uid()) = invited_user);
create policy own_battle on public.warfare_live_battles for select to authenticated
  using ((select auth.uid()) in (attacker_id,defender_id));

create function xern_private.player() returns uuid language plpgsql stable set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid) then
    raise exception 'Sign in to play' using errcode='42501';
  end if;
  return uid;
end
$$;
create function xern_private.ok() returns jsonb language sql immutable set search_path = '' as $$
  select '{"ok":true}'::jsonb
$$;
create function xern_private.fail(message text) returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('ok',false,'error',message)
$$;
