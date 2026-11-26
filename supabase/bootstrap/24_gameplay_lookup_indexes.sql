-- Cover active gameplay lookups and foreign-key checks without changing rules.
create index if not exists holdings_symbol on public.holdings(symbol);
create index if not exists team_units_design on public.team_units(unit_name);
create index if not exists warfare_marches_owner on public.warfare_marches(owner_id);
create index if not exists clan_invites_recipient on public.xern_clan_invites(invited_user);
create index if not exists clans_leader on xern_private.clans(leader_id);
create index if not exists stock_player_impact_symbol on xern_private.stock_player_impact(symbol);
create index if not exists transfers_recipient on xern_private.transfers(recipient);
