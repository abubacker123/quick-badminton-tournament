-- Quick Badminton Tournament: migrate existing Player IDs to Firstname_Number format.
-- IMPORTANT: Run once in Supabase SQL Editor after taking a database backup.
-- Existing player rows are renumbered in registration order. All match, payment,
-- and tournament-entry foreign keys cascade automatically, preserving history.
begin;

-- Recreate the player foreign keys with ON UPDATE CASCADE so ID changes preserve references.
alter table public.tournament_entries drop constraint if exists tournament_entries_player_id_fkey;
alter table public.matches drop constraint if exists matches_winner_player_id_fkey;
alter table public.matches drop constraint if exists matches_winner_player2_id_fkey;
alter table public.matches drop constraint if exists matches_loser_player_id_fkey;
alter table public.matches drop constraint if exists matches_loser_player2_id_fkey;
alter table public.payments drop constraint if exists payments_player_id_fkey;

alter table public.tournament_entries add constraint tournament_entries_player_id_fkey
  foreign key (player_id) references public.players(id) on delete cascade on update cascade;
alter table public.matches add constraint matches_winner_player_id_fkey
  foreign key (winner_player_id) references public.players(id) on update cascade;
alter table public.matches add constraint matches_winner_player2_id_fkey
  foreign key (winner_player2_id) references public.players(id) on update cascade;
alter table public.matches add constraint matches_loser_player_id_fkey
  foreign key (loser_player_id) references public.players(id) on update cascade;
alter table public.matches add constraint matches_loser_player2_id_fkey
  foreign key (loser_player2_id) references public.players(id) on update cascade;
alter table public.payments add constraint payments_player_id_fkey
  foreign key (player_id) references public.players(id) on update cascade;

create sequence if not exists public.player_registration_number_seq start 1;

-- Rename all existing players in original registration order.
with numbered as (
  select id as old_id,
         (upper(left(regexp_replace(split_part(trim(name), ' ', 1), '[^A-Za-z0-9]', '', 'g'), 1)) ||
          substr(regexp_replace(split_part(trim(name), ' ', 1), '[^A-Za-z0-9]', '', 'g'), 2) || '_' ||
          row_number() over (order by created_at, id)::text) as new_id
  from public.players
)
update public.players p
set id = numbered.new_id
from numbered
where p.id = numbered.old_id;

-- Ensure the next registration receives the next number after existing players.
select setval('public.player_registration_number_seq',
              greatest((select count(*) from public.players), 1),
              (select count(*) > 0 from public.players));

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

commit;
