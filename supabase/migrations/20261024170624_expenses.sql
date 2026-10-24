-- Shopping trips, splitting costs and settling up.
-- ---------------------------------------------------------------------------
--   expenses        one shopping trip: total, currency, who paid, which list.
--                   Survives deletion of the list (list_name is kept).
--   expense_shares  how the total is split: one row per participant.
--   expense_items   what was bought (a snapshot of the checked-out items).
--   settlements     "A paid B back": money sent between two people.
--
-- Rules
--   * Recording a purchase is atomic: the expense, its shares and the item
--     snapshot are written, and the bought items leave the list, together.
--   * The payer and everyone in the split must be members of the list.
--   * You can see an expense if you paid, created it, are in its split, or
--     are a member of its list. Leaving the list keeps your own debts visible.
--   * Only the creator or the payer can delete an expense; only the creator
--     can delete a settlement.
--   * Clients never write these tables directly, only through the functions.
-- ---------------------------------------------------------------------------

-- ============================ Currency ======================================

alter table public.profiles
  add column currency text not null default 'PLN' check (currency ~ '^[A-Z]{3}$');
grant update (currency) on public.profiles to authenticated;

-- ============================ Tables ========================================

create table public.expenses (
  id          uuid primary key,                       -- generated on the client
  list_id     uuid references public.lists (id) on delete set null,
  list_name   text not null,
  amount      numeric(12, 2) not null check (amount > 0 and amount < 10000000),
  currency    text not null check (currency ~ '^[A-Z]{3}$'),
  paid_by     uuid references public.profiles (id) on delete set null,
  created_by  uuid references public.profiles (id) on delete set null,
  note        text check (note is null or char_length(note) <= 200),
  created_at  timestamptz not null default now()
);
create index expenses_list_idx on public.expenses (list_id);
create index expenses_paid_by_idx on public.expenses (paid_by);
create index expenses_created_by_idx on public.expenses (created_by);

create table public.expense_shares (
  expense_id  uuid not null references public.expenses (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  amount      numeric(12, 2) not null check (amount >= 0),
  primary key (expense_id, user_id)
);
create index expense_shares_user_idx on public.expense_shares (user_id);

create table public.expense_items (
  expense_id  uuid not null references public.expenses (id) on delete cascade,
  item_id     uuid not null,
  name        text not null,
  quantity    numeric(12, 3),
  unit        text,
  primary key (expense_id, item_id)
);

create table public.settlements (
  id          uuid primary key,                       -- generated on the client
  from_user   uuid not null references public.profiles (id) on delete cascade,
  to_user     uuid not null references public.profiles (id) on delete cascade,
  amount      numeric(12, 2) not null check (amount > 0 and amount < 10000000),
  currency    text not null check (currency ~ '^[A-Z]{3}$'),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  check (from_user <> to_user)
);
create index settlements_from_idx on public.settlements (from_user);
create index settlements_to_idx on public.settlements (to_user);
create index settlements_created_by_idx on public.settlements (created_by);

-- ============================ Helpers =======================================

create or replace function private.can_see_expense(p_expense uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.expenses e
    where e.id = p_expense
      and (e.paid_by = auth.uid()
           or e.created_by = auth.uid()
           or private.is_list_member(e.list_id)
           or exists (select 1 from public.expense_shares s
                      where s.expense_id = e.id and s.user_id = auth.uid()))
  );
$$;

-- Profiles are also visible between people who share an expense or a
-- settlement, so names stay readable after someone leaves a list.
create or replace function private.can_see_profile(p_user uuid)
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
      )
      or exists (
        select 1 from public.expense_shares a
        join public.expense_shares b on b.expense_id = a.expense_id
        where a.user_id = auth.uid() and b.user_id = p_user
      )
      or exists (
        select 1 from public.expenses e
        join public.expense_shares s on s.expense_id = e.id
        where (e.paid_by = p_user and s.user_id = auth.uid())
           or (e.paid_by = auth.uid() and s.user_id = p_user)
      )
      or exists (
        select 1 from public.settlements st
        where (st.from_user = auth.uid() and st.to_user = p_user)
           or (st.to_user = auth.uid() and st.from_user = p_user)
      );
$$;

-- ============================ Row Level Security ============================

alter table public.expenses       enable row level security;
alter table public.expense_shares enable row level security;
alter table public.expense_items  enable row level security;
alter table public.settlements    enable row level security;

create policy expenses_select on public.expenses for select to authenticated
  using (private.can_see_expense(id));
create policy expense_shares_select on public.expense_shares for select to authenticated
  using (private.can_see_expense(expense_id));
create policy expense_items_select on public.expense_items for select to authenticated
  using (private.can_see_expense(expense_id));
create policy settlements_select on public.settlements for select to authenticated
  using ((select auth.uid()) in (from_user, to_user));

revoke all on public.expenses, public.expense_shares, public.expense_items, public.settlements
  from anon, authenticated;
grant select on public.expenses, public.expense_shares, public.expense_items, public.settlements
  to authenticated;

-- ============================ Functions =====================================

-- Records a shopping trip and takes the bought items off the list.
-- Idempotent on p_id, so the offline queue can retry it safely.
-- The total is split equally in whole cents; leftover cents go to the
-- participants with the lowest user ids, so the shares always add up.
create or replace function public.record_purchase(
  p_id uuid,
  p_list_id uuid,
  p_amount numeric,
  p_currency text,
  p_paid_by uuid,
  p_participants uuid[],
  p_item_ids uuid[] default '{}',
  p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := public.require_auth();
  v_name   text;
  v_people uuid[];
  v_n      integer;
  v_cents  bigint;
begin
  if exists (select 1 from public.expenses e where e.id = p_id) then
    return;
  end if;
  select l.name into v_name from public.lists l where l.id = p_list_id;
  if v_name is null or not private.is_list_member(p_list_id) then
    raise exception 'not_list_member' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount >= 10000000 or round(p_amount, 2) <> p_amount then
    raise exception 'invalid_amount' using errcode = 'P0001';
  end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception 'invalid_currency' using errcode = 'P0001';
  end if;

  select array_agg(distinct u order by u) into v_people
  from unnest(coalesce(p_participants, '{}')) as u where u is not null;
  v_n := coalesce(array_length(v_people, 1), 0);
  if v_n = 0 then
    raise exception 'invalid_participants' using errcode = 'P0001';
  end if;
  if p_paid_by is null or exists (
    select 1 from unnest(v_people || p_paid_by) as u(id)
    where not exists (select 1 from public.list_members m where m.list_id = p_list_id and m.user_id = u.id)
  ) then
    raise exception 'participant_not_member' using errcode = 'P0001';
  end if;

  insert into public.expenses (id, list_id, list_name, amount, currency, paid_by, created_by, note)
  values (p_id, p_list_id, v_name, p_amount, p_currency, p_paid_by, v_uid,
          nullif(btrim(coalesce(p_note, '')), ''));

  v_cents := (p_amount * 100)::bigint;
  insert into public.expense_shares (expense_id, user_id, amount)
  select p_id, u.id,
         ((v_cents / v_n) + case when u.ord <= v_cents % v_n then 1 else 0 end)::numeric / 100
  from unnest(v_people) with ordinality as u(id, ord);

  insert into public.expense_items (expense_id, item_id, name, quantity, unit)
  select p_id, i.id, i.name, i.quantity, i.unit
  from public.items i
  where i.list_id = p_list_id and i.id = any(coalesce(p_item_ids, '{}')) and i.deleted_at is null;

  update public.items i set deleted_at = now()
  where i.list_id = p_list_id and i.id = any(coalesce(p_item_ids, '{}')) and i.deleted_at is null;
end;
$$;

create or replace function public.delete_expense(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  delete from public.expenses e
  where e.id = p_id and (e.created_by = v_uid or e.paid_by = v_uid);
  if not found then
    raise exception 'expense_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- Records that p_from paid p_to back. The caller must be one of the two, and
-- the other person must be someone they share a list, an expense or a
-- connection with. Idempotent on p_id.
create or replace function public.record_settlement(
  p_id uuid, p_from uuid, p_to uuid, p_amount numeric, p_currency text
)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  if exists (select 1 from public.settlements s where s.id = p_id) then
    return;
  end if;
  if v_uid is distinct from p_from and v_uid is distinct from p_to then
    raise exception 'not_settlement_party' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'invalid_participants' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount >= 10000000 or round(p_amount, 2) <> p_amount then
    raise exception 'invalid_amount' using errcode = 'P0001';
  end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception 'invalid_currency' using errcode = 'P0001';
  end if;
  if not private.can_see_profile(case when p_from = v_uid then p_to else p_from end) then
    raise exception 'not_connected' using errcode = '42501';
  end if;
  insert into public.settlements (id, from_user, to_user, amount, currency, created_by)
  values (p_id, p_from, p_to, p_amount, p_currency, v_uid);
end;
$$;

create or replace function public.delete_settlement(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_auth();
begin
  delete from public.settlements s where s.id = p_id and s.created_by = v_uid;
  if not found then
    raise exception 'settlement_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- ============================ Grants ========================================

revoke execute on function
  private.can_see_expense(uuid),
  public.record_purchase(uuid, uuid, numeric, text, uuid, uuid[], uuid[], text),
  public.delete_expense(uuid),
  public.record_settlement(uuid, uuid, uuid, numeric, text),
  public.delete_settlement(uuid)
from public, anon;
grant execute on function
  private.can_see_expense(uuid),
  public.record_purchase(uuid, uuid, numeric, text, uuid, uuid[], uuid[], text),
  public.delete_expense(uuid),
  public.record_settlement(uuid, uuid, uuid, numeric, text),
  public.delete_settlement(uuid)
to authenticated;

-- ============================ Realtime ======================================
-- Clients re-fetch expenses and settlements when either table changes.
alter publication supabase_realtime add table public.expenses, public.settlements;
