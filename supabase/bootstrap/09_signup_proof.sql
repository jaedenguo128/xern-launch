-- Auth inserts user metadata before it applies custom app metadata. Prove a
-- registration came from the rate-limited Edge Function with a one-use nonce.
create table xern_private.signup_proofs (
  proof uuid primary key,
  username text not null,
  expires_at timestamptz not null default now()+interval '5 minutes'
);
alter table xern_private.signup_proofs enable row level security;

create function xern_private.prepare_signup(p_username text,p_proof uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  if p_username is null or p_username !~ '^[A-Za-z0-9_]{3,24}$' or p_proof is null then return false; end if;
  delete from xern_private.signup_proofs where expires_at<=now();
  insert into xern_private.signup_proofs(proof,username) values(p_proof,p_username);
  return true;
end
$$;
create function public.xern_prepare_signup(p_username text,p_proof uuid) returns boolean
language sql set search_path='' as $$
  select xern_private.prepare_signup(p_username,p_proof)
$$;
revoke all on function xern_private.prepare_signup(text,uuid) from public,anon,authenticated;
revoke all on function public.xern_prepare_signup(text,uuid) from public,anon,authenticated;
grant execute on function xern_private.prepare_signup(text,uuid) to service_role;
grant execute on function public.xern_prepare_signup(text,uuid) to service_role;

create or replace function xern_private.create_player() returns trigger
language plpgsql security definer set search_path='' as $$
declare handle text:=new.raw_user_meta_data->>'username';
  nonce text:=new.raw_user_meta_data->>'xern_proof';
begin
  if handle is null or handle !~ '^[A-Za-z0-9_]{3,24}$'
    or lower(new.email) is distinct from lower(handle)||'@players.example.com'
    or nonce is null or nonce !~ '^[0-9a-f-]{36}$' then
    raise exception 'Invalid Xern registration';
  end if;
  delete from xern_private.signup_proofs where proof=nonce::uuid and username=handle and expires_at>now();
  if not found then raise exception 'Xern registration proof is missing or expired'; end if;
  insert into public.profiles(id,username) values(new.id,handle);
  return new;
end
$$;

-- The three-second world job records a run each time. Bound that history so
-- it cannot grow indefinitely on the free project.
select cron.schedule('xern-v2-cron-cleanup','15 3 * * *',
  $$delete from cron.job_run_details where end_time < now()-interval '2 days'$$);
notify pgrst,'reload schema';
