-- Follow-up from the Supabase security and performance advisors.

-- ============================ Private helpers ===============================
-- The RLS helper functions are SECURITY DEFINER. In `public` they were also
-- reachable as /rest/v1/rpc/* endpoints. `private` is not exposed by the Data
-- API. Policies reference functions by OID, so they keep working unchanged.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

alter function public.is_list_member(uuid)  set schema private;
alter function public.is_list_owner(uuid)   set schema private;
alter function public.can_see_profile(uuid) set schema private;

-- ============================ Foreign-key indexes ===========================
-- Used by ON DELETE SET NULL / CASCADE when an account is deleted.

create index items_created_by_idx       on public.items (created_by);
create index items_updated_by_idx       on public.items (updated_by);
create index items_purchased_by_idx     on public.items (purchased_by);
create index list_members_added_by_idx  on public.list_members (added_by);
create index invitations_created_by_idx on public.invitations (created_by);
