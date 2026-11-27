-- Snoredle portaal · Supabase-schema
-- Eén rij per nacht. Elke gebruiker ziet en wijzigt uitsluitend zijn eigen gegevens (Row Level Security).

create table if not exists public.nights (
  id           uuid primary key,                         -- zelfde id als in de app
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  start_at     timestamptz not null,
  end_at       timestamptz,
  summary      jsonb not null default '{}'::jsonb,        -- score, minuten, factoren, ... (klein: voor lijsten en trends)
  detail       jsonb not null default '{}'::jsonb,        -- volume, snurkperiodes, houding, hartslag, fasen, ... (groot)
  app_version  text,
  updated_at   timestamptz not null default now()
);
create index if not exists nights_user_start on public.nights (user_id, start_at desc);

create table if not exists public.profiles (
  user_id      uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  display_name text,
  consent_at   timestamptz,                               -- uitdrukkelijke toestemming gezondheidsgegevens (AVG art. 9)
  settings     jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now()
);

alter table public.nights   enable row level security;
alter table public.profiles enable row level security;

drop policy if exists "eigen nachten" on public.nights;
create policy "eigen nachten" on public.nights
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "eigen profiel" on public.profiles;
create policy "eigen profiel" on public.profiles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- updated_at automatisch bijwerken
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists nights_touch on public.nights;
create trigger nights_touch before update on public.nights for each row execute function public.touch_updated_at();
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

-- Account volledig wissen (recht op vergetelheid): verwijdert de gebruiker en via cascade al zijn nachten.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'niet aangemeld'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
