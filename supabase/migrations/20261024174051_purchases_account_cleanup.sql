-- Deleting an account also deletes purchases nobody is linked to any more
-- (no payer, no creator and no one in the split). Purchases that still
-- involve someone else stay, so their balances and history survive.

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

  delete from public.expenses e
  where e.paid_by is null and e.created_by is null
    and not exists (select 1 from public.expense_shares s where s.expense_id = e.id);
end;
$$;
