-- Correct the query alias that collides with the PL/pgSQL loop record "m".
-- Update the existing function in place so its signature, grants, and other logic are preserved.
do $migration$
declare
  function_oid regprocedure := to_regprocedure('public.warfare_explore_tick()');
  definition text;
  old_query constant text := $pattern$
    \mselect\s+m\.\*\s*,\s*u\.speed\s+from\s+public\.warfare_marches\s+m\s+
    join\s+public\.team_units\s+u\s+on\s+u\.id\s*=\s*m\.unit_id\s+
    where\s+m\.owner_id\s*=\s*auth\.uid\(\)\s+and\s+m\.active\s+
    and\s+m\.mode\s*=\s*'explore'\s+and\s+u\.unit_count\s*>\s*0\s+
    and\s+m\.last_step_at\s*<\s*now\(\)\s*-\s*make_interval\(
      \s*secs\s*=>\s*greatest\(\s*2\s*,\s*10\s*-\s*least\(\s*8\s*,\s*u\.speed\s*/\s*12\s*\)\s*\)\s*\)\s+
    order\s+by\s+m\.last_step_at\s+limit\s+35\s+for\s+update\s+of\s+m\M
  $pattern$;
  new_query constant text := $query$select march_row.*, u.speed
    from public.warfare_marches march_row
    join public.team_units u on u.id = march_row.unit_id
    where march_row.owner_id = auth.uid() and march_row.active
      and march_row.mode = 'explore' and u.unit_count > 0
      and march_row.last_step_at < now() - make_interval(secs => greatest(2, 10 - least(8, u.speed / 12)))
    order by march_row.last_step_at limit 35 for update of march_row$query$;
begin
  if function_oid is null then
    raise exception 'The existing Xern backend function public.warfare_explore_tick() is required';
  end if;

  definition := pg_get_functiondef(function_oid);
  if regexp_count(definition, old_query, 1, 'ix') = 1 then
    execute regexp_replace(definition, old_query, new_query, 'ix');
  elsif strpos(definition, new_query) = 0 then
    raise exception 'Unexpected warfare_explore_tick() definition. Review the deployed function before applying this migration';
  end if;
end
$migration$;
