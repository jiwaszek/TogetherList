-- TogetherList backend schema
-- ---------------------------------------------------------------------------
-- Model
--   profiles      one row per auth user (display name). Created by trigger.
--   lists         a shopping list. Exactly one owner (lists.owner_id).
--   list_members  who can access a list. The owner also has a row (role 'owner').
--   items         shopping items. Client-generated UUIDs; soft-deleted (tombstones).
--   invitations   expiring, revocable, multi-use invitation to ONE list.
--                 Only a SHA-256 hash of the token is stored.
--   connections   undirected "these two people are connected" edge.
--                 Created when someone accepts an invitation (acceptor <-> inviter).
--
-- Access rules (enforced here, never only in the UI)
--   * You can read a list, its members and its items only if you are a member.
--   * Any member can create / edit / check off / delete items.
--   * Only the owner can rename or delete a list, create or revoke invitations,
--     add a connection to the list, remove members, or transfer ownership.
--   * A member (not owner) can leave a list.
--   * Connecting does NOT grant access to anything except the list in the
--     invitation. Other lists are shared one by one by their owner.
--   * Disconnecting A and B removes B from every list owned by A and A from every
--     list owned by B. Lists owned by someone else are not touched.
--
-- All multi-step writes go through SECURITY DEFINER functions so they are atomic.
-- ---------------------------------------------------------------------------

-- ============================ Tables =======================================

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null default 'New user'
                check (char_length(btrim(display_name)) between 1 and 60),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.lists (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index lists_owner_idx on public.lists (owner_id);

create table public.list_members (
  list_id    uuid not null references public.lists (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       text not null check (role in ('owner', 'member')),
  joined_at  timestamptz not null default now(),
  added_by   uuid references public.profiles (id) on delete set null,
  primary key (list_id, user_id)
);
create index list_members_user_idx on public.list_members (user_id);
-- At most one owner row per list.
create unique index list_members_one_owner on public.list_members (list_id) where role = 'owner';

create table public.items (
  id            uuid primary key,                 -- generated on the client (stable across retries)
  list_id       uuid not null references public.lists (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 200),
  quantity      numeric(12, 3) check (quantity is null or quantity > 0),
  unit          text check (unit is null or char_length(unit) <= 20),
  note          text check (note is null or char_length(note) <= 500),
  is_purchased  boolean not null default false,
  purchased_at  timestamptz,
  purchased_by  uuid references public.profiles (id) on delete set null,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_by    uuid references public.profiles (id) on delete set null,
  updated_at    timestamptz not null default now(),   -- server clock, used as sync cursor
  deleted_at    timestamptz,                          -- tombstone; never cleared
  version       integer not null default 1
);
create index items_list_idx on public.items (list_id);
create index items_updated_idx on public.items (updated_at);

create table public.invitations (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.lists (id) on delete cascade,
  created_by  uuid not null references public.profiles (id) on delete cascade,
  token_hash  bytea not null unique,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked_at  timestamptz,
  use_count   integer not null default 0
);
create index invitations_list_idx on public.invitations (list_id);

create table public.connections (
  user_low    uuid not null references public.profiles (id) on delete cascade,
  user_high   uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_low, user_high),
  check (user_low < user_high)
);
create index connections_high_idx on public.connections (user_high);

-- ============================ Helpers ======================================
-- SECURITY DEFINER helpers avoid recursive RLS evaluation on list_members.

create or replace function public.is_list_member(p_list uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.list_members m
    where m.list_id = p_list and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_list_owner(p_list uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.lists l
    where l.id = p_list and l.owner_id = auth.uid()
  );
$$;

-- True when the caller can see the other user's profile:
-- self, connected, or sharing at least one list.
create or replace function public.can_see_profile(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user = auth.uid()
      or exists (
        select 1 from public.connections c
        where (c.user_low = least(p_user, auth.uid()) and c.user_high = greatest(p_user, auth.uid()))
      )
      or exists (
        select 1 from public.list_members a
        join public.list_members b on b.list_id = a.list_id
        where a.user_id = auth.uid() and b.user_id = p_user
      );
$$;

create or replace function public.require_auth()
returns uuid language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return v;
end;
$$;

-- ============================ Triggers =====================================

-- New auth user -> profile (display name from sign-up metadata).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''), 'New user')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- New list -> owner membership row (same transaction).
create or replace function public.handle_new_list()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.list_members (list_id, user_id, role, added_by)
  values (new.id, new.owner_id, 'owner', new.owner_id);
  return new;
end;
$$;

create trigger on_list_created
  after insert on public.lists
  for each row execute function public.handle_new_list();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- Lists: owner can only change the name through direct UPDATE.
create or replace function public.guard_list_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- owner_id changes only via transfer_ownership() / delete_account(),
  -- which set this flag inside their transaction.
  if new.owner_id <> old.owner_id
     and coalesce(current_setting('togetherlist.allow_owner_change', true), '') <> 'on' then
    raise exception 'owner_change_not_allowed' using errcode = '42501';
  end if;
  new.id := old.id;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end;
$$;

create trigger lists_guard before update on public.lists
  for each row execute function public.guard_list_update();

-- Items: server owns timestamps/authorship; immutable columns stay immutable;
-- a tombstoned item can never be edited or restored.
create or replace function public.guard_item_insert()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.created_by := auth.uid();
  new.updated_by := auth.uid();
  new.created_at := now();
  new.updated_at := now();
  new.deleted_at := null;
  new.version := 1;
  if new.is_purchased then
    new.purchased_at := now();
    new.purchased_by := auth.uid();
  else
    new.purchased_at := null;
    new.purchased_by := null;
  end if;
  return new;
end;
$$;

create or replace function public.guard_item_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Nested trigger = foreign-key action (e.g. ON DELETE SET NULL when an
  -- account is deleted), not a client write. Let it through untouched.
  if pg_trigger_depth() > 1 then
    return new;
  end if;
  if old.deleted_at is not null then
    raise exception 'item_deleted' using errcode = 'P0002';
  end if;
  new.id := old.id;
  new.list_id := old.list_id;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  new.updated_by := auth.uid();
  new.updated_at := now();
  new.version := old.version + 1;
  if new.deleted_at is not null then
    new.deleted_at := now();
  end if;
  if new.is_purchased is distinct from old.is_purchased then
    if new.is_purchased then
      new.purchased_at := now();
      new.purchased_by := auth.uid();
    else
      new.purchased_at := null;
      new.purchased_by := null;
    end if;
  else
    new.purchased_at := old.purchased_at;
    new.purchased_by := old.purchased_by;
  end if;
  return new;
end;
$$;

create trigger items_guard_insert before insert on public.items
  for each row execute function public.guard_item_insert();
create trigger items_guard_update before update on public.items
  for each row execute function public.guard_item_update();

-- Touch the parent list when membership changes so delta sync and realtime
-- listeners on `lists` notice.
create or replace function public.touch_list_from_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.lists set updated_at = now()
  where id = coalesce(new.list_id, old.list_id);
  return null;
end;
$$;

create trigger list_members_touch after insert or delete or update on public.list_members
  for each row execute function public.touch_list_from_member();

-- ============================ Row Level Security ===========================

alter table public.profiles     enable row level security;
alter table public.lists        enable row level security;
alter table public.list_members enable row level security;
alter table public.items        enable row level security;
alter table public.invitations  enable row level security;
alter table public.connections  enable row level security;

-- profiles
create policy profiles_select on public.profiles for select to authenticated
  using (public.can_see_profile(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- lists (owner_id check lets INSERT ... RETURNING see the row before the
-- AFTER trigger has created the owner's membership)
create policy lists_select on public.lists for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_list_member(id));
create policy lists_insert on public.lists for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy lists_update on public.lists for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy lists_delete on public.lists for delete to authenticated
  using (owner_id = (select auth.uid()));

-- list_members: read-only for clients; all writes go through functions.
create policy list_members_select on public.list_members for select to authenticated
  using (public.is_list_member(list_id));

-- items: any member may read/insert/update. No hard deletes from clients.
create policy items_select on public.items for select to authenticated
  using (public.is_list_member(list_id));
create policy items_insert on public.items for insert to authenticated
  with check (public.is_list_member(list_id));
create policy items_update on public.items for update to authenticated
  using (public.is_list_member(list_id)) with check (public.is_list_member(list_id));

-- invitations: owner can see the invitations of their lists (never the token).
create policy invitations_select on public.invitations for select to authenticated
  using (public.is_list_owner(list_id));

-- connections: you can see your own edges.
create policy connections_select on public.connections for select to authenticated
  using ((select auth.uid()) in (user_low, user_high));

-- Column-level hardening: clients never read token hashes.
revoke all on public.invitations from anon, authenticated;
grant select (id, list_id, created_by, created_at, expires_at, revoked_at, use_count)
  on public.invitations to authenticated;

-- Supabase grants ALL on new tables to anon/authenticated by default; start
-- from nothing and grant exactly what clients need.
revoke all on public.profiles, public.lists, public.list_members, public.items, public.connections
  from anon, authenticated;
grant select, update (display_name) on public.profiles to authenticated;
grant select, insert, delete on public.lists to authenticated;
grant update (name) on public.lists to authenticated;
grant select on public.list_members to authenticated;
grant select, insert on public.items to authenticated;
grant update (name, quantity, unit, note, is_purchased, deleted_at) on public.items to authenticated;
grant select on public.connections to authenticated;

-- ============================ Invitations ==================================

-- Creates an invitation for a list the caller owns. Returns the raw token ONCE.
-- Default lifetime 48 hours; clamped to 1 hour .. 7 days.
create or replace function public.create_invitation(p_list_id uuid, p_ttl_hours integer default 48)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := public.require_auth();
  v_token text;
  v_id    uuid;
  v_exp   timestamptz;
begin
  if not exists (select 1 from public.lists l where l.id = p_list_id and l.owner_id = v_uid) then
    raise exception 'not_list_owner' using errcode = '42501';
  end if;
  -- 2 x UUIDv4 = 244 bits from the server's CSPRNG.
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_exp := now() + make_interval(hours => greatest(1, least(coalesce(p_ttl_hours, 48), 168)));
  insert into public.invitations (list_id, created_by, token_hash, expires_at)
  values (p_list_id, v_uid, sha256(convert_to(v_token, 'UTF8')), v_exp)
  returning id into v_id;
  return query select v_id, v_token, v_exp;
end;
$$;

create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  update public.invitations i set revoked_at = coalesce(i.revoked_at, now())
  where i.id = p_invitation_id
    and exists (select 1 from public.lists l where l.id = i.list_id and l.owner_id = v_uid);
  if not found then
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- Preview without side effects. Never reveals anything for an unknown token.
-- status: valid | expired | revoked | already_member | own_invitation | invalid
create or replace function public.preview_invitation(p_token text)
returns table (
  status text, list_id uuid, list_name text, inviter_id uuid,
  inviter_name text, item_count integer, member_count integer, expires_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_auth();
  v_inv public.invitations;
  v_status text;
begin
  select * into v_inv from public.invitations i
  where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
  if not found then
    return query select 'invalid'::text, null::uuid, null::text, null::uuid, null::text,
                        null::integer, null::integer, null::timestamptz;
    return;
  end if;

  v_status := case
    when v_inv.revoked_at is not null then 'revoked'
    when v_inv.expires_at <= now() then 'expired'
    when v_inv.created_by = v_uid then 'own_invitation'
    when exists (select 1 from public.list_members m where m.list_id = v_inv.list_id and m.user_id = v_uid)
      then 'already_member'
    else 'valid'
  end;

  -- Expired/revoked: confirm the state but do not reveal list details.
  if v_status in ('revoked', 'expired') then
    return query select v_status, null::uuid, null::text, null::uuid,
      (select p.display_name from public.profiles p where p.id = v_inv.created_by),
      null::integer, null::integer, v_inv.expires_at;
    return;
  end if;

  return query
  select v_status, l.id, l.name, p.id, p.display_name,
    (select count(*)::integer from public.items it where it.list_id = l.id and it.deleted_at is null),
    (select count(*)::integer from public.list_members m where m.list_id = l.id),
    v_inv.expires_at
  from public.lists l
  join public.profiles p on p.id = v_inv.created_by
  where l.id = v_inv.list_id;
end;
$$;

-- Atomic + idempotent acceptance.
--   * Locks the invitation row so concurrent accepts serialize.
--   * Membership and connection inserts use ON CONFLICT DO NOTHING.
--   * Accepting twice returns 'already_member' with the same list id.
create or replace function public.accept_invitation(p_token text)
returns table (status text, list_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_auth();
  v_inv public.invitations;
  v_inserted integer;
begin
  select * into v_inv from public.invitations i
  where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'))
  for update;

  if not found then
    raise exception 'invitation_invalid' using errcode = 'P0002';
  end if;

  -- Idempotency first: someone who already joined gets success even if the
  -- invitation has since expired (e.g. a retried request).
  if exists (select 1 from public.list_members m where m.list_id = v_inv.list_id and m.user_id = v_uid) then
    if v_inv.created_by = v_uid then
      raise exception 'invitation_own' using errcode = 'P0001';
    end if;
    return query select 'already_member'::text, v_inv.list_id;
    return;
  end if;

  if v_inv.revoked_at is not null then
    raise exception 'invitation_revoked' using errcode = 'P0001';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'invitation_expired' using errcode = 'P0001';
  end if;
  if v_inv.created_by = v_uid then
    raise exception 'invitation_own' using errcode = 'P0001';
  end if;
  -- The inviter must still own the list (ownership could have been transferred).
  if not exists (select 1 from public.lists l where l.id = v_inv.list_id and l.owner_id = v_inv.created_by) then
    raise exception 'invitation_revoked' using errcode = 'P0001';
  end if;

  insert into public.list_members (list_id, user_id, role, added_by)
  values (v_inv.list_id, v_uid, 'member', v_inv.created_by)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;

  insert into public.connections (user_low, user_high)
  values (least(v_uid, v_inv.created_by), greatest(v_uid, v_inv.created_by))
  on conflict do nothing;

  if v_inserted > 0 then
    update public.invitations set use_count = use_count + 1 where id = v_inv.id;
  end if;

  return query select 'joined'::text, v_inv.list_id;
end;
$$;

-- ============================ Membership ===================================

-- Owner shares another list with someone they are already connected to.
create or replace function public.add_connection_to_list(p_list_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  if not exists (select 1 from public.lists l where l.id = p_list_id and l.owner_id = v_uid) then
    raise exception 'not_list_owner' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.connections c
    where c.user_low = least(v_uid, p_user_id) and c.user_high = greatest(v_uid, p_user_id)
  ) then
    raise exception 'not_connected' using errcode = '42501';
  end if;
  insert into public.list_members (list_id, user_id, role, added_by)
  values (p_list_id, p_user_id, 'member', v_uid)
  on conflict do nothing;
end;
$$;

create or replace function public.remove_member(p_list_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  if not exists (select 1 from public.lists l where l.id = p_list_id and l.owner_id = v_uid) then
    raise exception 'not_list_owner' using errcode = '42501';
  end if;
  if p_user_id = v_uid then
    raise exception 'owner_cannot_be_removed' using errcode = 'P0001';
  end if;
  delete from public.list_members m where m.list_id = p_list_id and m.user_id = p_user_id;
end;
$$;

create or replace function public.leave_list(p_list_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  if exists (select 1 from public.lists l where l.id = p_list_id and l.owner_id = v_uid) then
    raise exception 'owner_cannot_leave' using errcode = 'P0001';
  end if;
  -- Idempotent: leaving a list you are not in is a no-op.
  delete from public.list_members m where m.list_id = p_list_id and m.user_id = v_uid;
end;
$$;

create or replace function public.transfer_ownership(p_list_id uuid, p_new_owner uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  if not exists (select 1 from public.lists l where l.id = p_list_id and l.owner_id = v_uid) then
    raise exception 'not_list_owner' using errcode = '42501';
  end if;
  if not exists (select 1 from public.list_members m where m.list_id = p_list_id and m.user_id = p_new_owner and m.role = 'member') then
    raise exception 'new_owner_not_member' using errcode = 'P0001';
  end if;
  perform set_config('togetherlist.allow_owner_change', 'on', true);
  update public.list_members set role = 'member' where list_id = p_list_id and user_id = v_uid;
  update public.list_members set role = 'owner'  where list_id = p_list_id and user_id = p_new_owner;
  update public.lists set owner_id = p_new_owner where id = p_list_id;
  perform set_config('togetherlist.allow_owner_change', 'off', true);
end;
$$;

-- ============================ Connections ==================================

create or replace function public.my_connections()
returns table (user_id uuid, display_name text, connected_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, p.display_name, c.created_at
  from public.connections c
  join public.profiles p
    on p.id = case when c.user_low = auth.uid() then c.user_high else c.user_low end
  where auth.uid() in (c.user_low, c.user_high)
  order by p.display_name;
$$;

-- Removes the connection and revokes shared access *between these two users*:
--   * other user is removed from every list the caller owns
--   * caller is removed from every list the other user owns
-- Lists owned by third parties are untouched (both keep access there).
create or replace function public.disconnect(p_user_id uuid)
returns table (lists_revoked integer)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_auth();
  v_a integer;
  v_b integer;
begin
  delete from public.connections c
  where c.user_low = least(v_uid, p_user_id) and c.user_high = greatest(v_uid, p_user_id);

  delete from public.list_members m
  using public.lists l
  where m.list_id = l.id and l.owner_id = v_uid and m.user_id = p_user_id;
  get diagnostics v_a = row_count;

  delete from public.list_members m
  using public.lists l
  where m.list_id = l.id and l.owner_id = p_user_id and m.user_id = v_uid;
  get diagnostics v_b = row_count;

  return query select v_a + v_b;
end;
$$;

-- ============================ Account ======================================

-- Deletes the caller's account.
--   p_transfers: JSON object { "<list_id>": "<new_owner_user_id>", ... }
--   Owned lists listed there are transferred first (new owner must be a member);
--   every other owned list is deleted with its items.
--   Memberships, connections and invitations cascade. Items the user created in
--   other people's lists stay (created_by becomes NULL).
create or replace function public.delete_account(p_transfers jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_auth();
  r record;
begin
  perform set_config('togetherlist.allow_owner_change', 'on', true);
  for r in select key::uuid as list_id, value::uuid as new_owner
           from jsonb_each_text(coalesce(p_transfers, '{}'::jsonb)) loop
    if not exists (select 1 from public.lists l where l.id = r.list_id and l.owner_id = v_uid) then
      raise exception 'not_list_owner' using errcode = '42501';
    end if;
    if not exists (select 1 from public.list_members m where m.list_id = r.list_id and m.user_id = r.new_owner and m.role = 'member') then
      raise exception 'new_owner_not_member' using errcode = 'P0001';
    end if;
    update public.list_members set role = 'member' where list_id = r.list_id and user_id = v_uid;
    update public.list_members set role = 'owner'  where list_id = r.list_id and user_id = r.new_owner;
    update public.lists set owner_id = r.new_owner where id = r.list_id;
  end loop;

  delete from public.lists where owner_id = v_uid;
  delete from auth.users where id = v_uid;   -- cascades to profiles and everything else
end;
$$;

-- ============================ Grants =======================================

revoke execute on all functions in schema public from public, anon;
-- Trigger functions are never called directly.
revoke execute on function
  public.handle_new_user(), public.handle_new_list(), public.touch_updated_at(),
  public.guard_list_update(), public.guard_item_insert(), public.guard_item_update(),
  public.touch_list_from_member()
from authenticated;
grant execute on function
  public.create_invitation(uuid, integer),
  public.revoke_invitation(uuid),
  public.preview_invitation(text),
  public.accept_invitation(text),
  public.add_connection_to_list(uuid, uuid),
  public.remove_member(uuid, uuid),
  public.leave_list(uuid),
  public.transfer_ownership(uuid, uuid),
  public.my_connections(),
  public.disconnect(uuid),
  public.delete_account(jsonb),
  public.is_list_member(uuid),
  public.is_list_owner(uuid),
  public.can_see_profile(uuid),
  public.require_auth()
to authenticated;

-- ============================ Realtime =====================================
-- Clients subscribe to Postgres Changes. RLS filters INSERT/UPDATE events per
-- subscriber. DELETE events carry only the primary key, which the client uses
-- purely as a "something changed, re-sync" signal.
alter publication supabase_realtime add table
  public.items, public.lists, public.list_members, public.connections, public.profiles;
