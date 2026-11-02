-- Quick Badminton Tournament database (Supabase / PostgreSQL)
-- Run this in Supabase SQL Editor. Create the first admin in Authentication, then add their UUID below.
create extension if not exists pgcrypto;

create table if not exists public.players (
  id text primary key,
  name text not null check (char_length(name) between 2 and 80),
  phone text not null unique,
  email text not null,
  created_at timestamptz not null default now(),
  singles_points integer not null default 0,
  doubles_points integer not null default 0,
  singles_wins integer not null default 0,
  singles_losses integer not null default 0,
  doubles_wins integer not null default 0,
  doubles_losses integer not null default 0
);


-- Human-friendly permanent player IDs: Firstname_RegistrationNumber.
create sequence if not exists public.player_registration_number_seq start 1;
create or replace function public.assign_player_registration_id()
returns trigger language plpgsql as $$
declare first_name text; registration_number bigint;
begin
  first_name := regexp_replace(split_part(trim(new.name), ' ', 1), '[^A-Za-z0-9]', '', 'g');
  if first_name = '' then first_name := 'Player'; end if;
  registration_number := nextval('public.player_registration_number_seq');
  new.id := upper(left(first_name, 1)) || substr(first_name, 2) || '_' || registration_number;
  return new;
end; $$;
drop trigger if exists players_assign_registration_id on public.players;
create trigger players_assign_registration_id before insert on public.players
for each row execute function public.assign_player_registration_id();

create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  tournament_type text not null check (tournament_type in ('singles','doubles')),
  entry_fee_paise integer not null check (entry_fee_paise >= 0),
  status text not null default 'open' check (status in ('draft','open','closed','completed')),
  starts_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.tournament_entries (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid references public.tournaments(id) on delete cascade,
  player_id text not null references public.players(id) on delete cascade on update cascade,
  payment_id uuid,
  entry_count integer not null default 1 check (entry_count > 0),
  status text not null default 'pending' check (status in ('pending','confirmed','cancelled')),
  created_at timestamptz not null default now(),
  unique(tournament_id, player_id)
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  match_type text not null check (match_type in ('singles','doubles')),
  winner_player_id text not null references public.players(id) on update cascade,
  winner_player2_id text references public.players(id) on update cascade,
  loser_player_id text not null references public.players(id) on update cascade,
  loser_player2_id text references public.players(id) on update cascade,
  tournament_id uuid references public.tournaments(id),
  played_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id),
  check (winner_player_id <> loser_player_id)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  player_id text not null references public.players(id) on update cascade,
  tournament_type text not null check (tournament_type in ('singles','doubles')),
  amount_paise integer not null check (amount_paise > 0),
  currency text not null default 'INR',
  payment_mode text not null default 'razorpay',
  status text not null default 'created' check (status in ('created','paid','failed','refunded','manual_review')),
  gateway_order_id text unique,
  gateway_payment_id text unique,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.admin_users where user_id = auth.uid());
$$;

-- Player self-registration is public; public users can only insert a new profile and read public leaderboard fields.
alter table public.players enable row level security;
alter table public.matches enable row level security;
alter table public.payments enable row level security;
alter table public.tournaments enable row level security;
alter table public.tournament_entries enable row level security;
alter table public.admin_users enable row level security;

drop policy if exists "public player registration" on public.players;
create policy "public player registration" on public.players for insert to anon, authenticated with check (true);
drop policy if exists "public leaderboard read" on public.players;
drop policy if exists "admin read players" on public.players;
create policy "admin read players" on public.players for select to authenticated using (public.is_admin());
drop policy if exists "admin update players" on public.players;
create policy "admin update players" on public.players for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin delete players" on public.players;
create policy "admin delete players" on public.players for delete to authenticated using (public.is_admin());

-- Public-safe leaderboard view: never expose phone numbers or email addresses to visitors.
create or replace view public.leaderboard_public with (security_barrier=true) as
select id,name,singles_points,doubles_points,singles_wins,singles_losses,doubles_wins,doubles_losses,created_at
from public.players;
grant select on public.leaderboard_public to anon, authenticated;

drop policy if exists "public read matches" on public.matches;
create policy "public read matches" on public.matches for select to anon, authenticated using (true);
drop policy if exists "admin manage matches" on public.matches;
create policy "admin manage matches" on public.matches for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "public read tournaments" on public.tournaments;
create policy "public read tournaments" on public.tournaments for select to anon, authenticated using (status <> 'draft' or public.is_admin());
drop policy if exists "admin manage tournaments" on public.tournaments;
create policy "admin manage tournaments" on public.tournaments for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin read payments" on public.payments;
create policy "admin read payments" on public.payments for select to authenticated using (public.is_admin());
drop policy if exists "admin update payments" on public.payments;
create policy "admin update payments" on public.payments for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- Payment inserts/updates are server-side only using the Supabase service-role key.

drop policy if exists "public read entries" on public.tournament_entries;
create policy "public read entries" on public.tournament_entries for select to anon, authenticated using (true);
drop policy if exists "admin manage entries" on public.tournament_entries;
create policy "admin manage entries" on public.tournament_entries for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin read admins" on public.admin_users;
create policy "admin read admins" on public.admin_users for select to authenticated using (user_id = auth.uid());

-- Match result is one atomic transaction: store match + award winner +1 and loser -1 in the selected format.
create or replace function public.record_match_result(p_match_type text, p_winner_id text, p_winner2_id text, p_loser_id text, p_loser2_id text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_match_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admins can record match results'; end if;
  if p_match_type not in ('singles','doubles') then raise exception 'Invalid match type'; end if;
  if p_winner_id = p_loser_id then raise exception 'Winner and loser must be different players'; end if;
  if not exists(select 1 from public.players where id=p_winner_id) or not exists(select 1 from public.players where id=p_loser_id) then raise exception 'Player ID not found'; end if;
  if p_match_type='doubles' then
    if p_winner2_id is null or p_loser2_id is null then raise exception 'Both doubles teams need two player IDs'; end if;
    if p_winner2_id in (p_winner_id,p_loser_id,p_loser2_id) or p_loser2_id in (p_winner_id,p_loser_id) then raise exception 'A player cannot appear twice in the same doubles match'; end if;
    if not exists(select 1 from public.players where id=p_winner2_id) or not exists(select 1 from public.players where id=p_loser2_id) then raise exception 'Partner player ID not found'; end if;
  else
    p_winner2_id := null; p_loser2_id := null;
  end if;
  insert into public.matches(match_type,winner_player_id,winner_player2_id,loser_player_id,loser_player2_id,recorded_by)
  values(p_match_type,p_winner_id,p_winner2_id,p_loser_id,p_loser2_id,auth.uid()) returning id into new_match_id;
  if p_match_type='singles' then
    update public.players set singles_points=singles_points+1,singles_wins=singles_wins+1 where id=p_winner_id;
    update public.players set singles_points=singles_points-1,singles_losses=singles_losses+1 where id=p_loser_id;
  else
    update public.players set doubles_points=doubles_points+1,doubles_wins=doubles_wins+1 where id in (p_winner_id,p_winner2_id);
    update public.players set doubles_points=doubles_points-1,doubles_losses=doubles_losses+1 where id in (p_loser_id,p_loser2_id);
  end if;
  return new_match_id;
end; $$;
revoke all on function public.record_match_result(text,text,text,text,text) from public;
grant execute on function public.record_match_result(text,text,text,text,text) to authenticated;

-- Admin setup: replace the UUID with the user id from Supabase Authentication > Users.
-- insert into public.admin_users(user_id) values ('PASTE-AUTH-USER-UUID-HERE');
