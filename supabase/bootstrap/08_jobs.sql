create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('xern-v2-world','3 seconds','select xern_private.world_tick()');
select cron.schedule('xern-v2-mines','* * * * *','select xern_private.collect_mines()');
select cron.schedule('xern-v2-stocks','*/15 * * * *','select xern_private.stock_market_tick()');
select cron.schedule('xern-v2-clan-prize','0 * * * *','select xern_private.pay_clan_prize()');
