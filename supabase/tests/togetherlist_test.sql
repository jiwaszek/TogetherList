-- TogetherList backend tests.
-- Runs inside one transaction and rolls back, so it is safe against a dev DB.
--   Local:     scripts/test-backend.sh  (embedded Postgres + local_supabase_stub.sql)
--   Supabase:  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/togetherlist_test.sql
-- Every assertion failure aborts with a descriptive message.

\set ON_ERROR_STOP 1
begin;

create schema tests;
grant usage on schema tests to authenticated, anon;

create table tests.ctx (k text primary key, v text);
grant all on tests.ctx to authenticated;

create function tests.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.put(k text, v text) returns void language sql as $$
  insert into tests.ctx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
create function tests.get(k text) returns text language sql as $$ select v from tests.ctx where tests.ctx.k = get.k $$;

create function tests.throws(p_sql text, p_expect text) returns void language plpgsql as $$
declare v_failed boolean := false; v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    v_failed := true; v_msg := sqlerrm;
  end;
  if not v_failed then
    raise exception 'expected error "%" but statement succeeded: %', p_expect, p_sql;
  end if;
  if v_msg not ilike '%' || p_expect || '%' then
    raise exception 'expected error "%" but got "%" for: %', p_expect, v_msg, p_sql;
  end if;
end $$;

grant execute on all functions in schema tests to authenticated, anon;

-- Fixed identities
--   A = Alice (list owner), B = Bob (partner), C = Carol (third user), D = Dave (stranger)
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a@example.com', '{"display_name":"Alice"}'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'b@example.com', '{"display_name":"Bob"}'),
  ('cccccccc-0000-0000-0000-00000000000c', 'c@example.com', '{"display_name":"Carol"}'),
  ('dddddddd-0000-0000-0000-00000000000d', 'd@example.com', '{}');

-- ---------------------------------------------------------------- profiles
do $$ begin
  assert (select display_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-00000000000a') = 'Alice',
    'profile created from sign-up metadata';
  assert (select display_name from public.profiles where id = 'dddddddd-0000-0000-0000-00000000000d') = 'New user',
    'default display name';
  raise notice 'ok - profiles created by trigger';
end $$;

-- ------------------------------------------------------- lists and items
do $$
declare v_groceries uuid; v_secret uuid;
begin
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  insert into public.lists (name, owner_id) values ('Groceries', 'aaaaaaaa-0000-0000-0000-00000000000a') returning id into v_groceries;
  insert into public.lists (name, owner_id) values ('Secret gifts', 'aaaaaaaa-0000-0000-0000-00000000000a') returning id into v_secret;
  perform tests.put('groceries', v_groceries::text);
  perform tests.put('secret', v_secret::text);

  assert (select role from public.list_members where list_id = v_groceries and user_id = auth.uid()) = 'owner',
    'creator gets owner membership';

  insert into public.items (id, list_id, name, quantity, unit) values
    ('11111111-0000-0000-0000-000000000001', v_groceries, 'Milk', 2, 'l'),
    ('11111111-0000-0000-0000-000000000002', v_groceries, 'Bread', null, null);
  insert into public.items (id, list_id, name) values
    ('11111111-0000-0000-0000-000000000009', v_secret, 'Watch for Bob');

  -- cannot create a list on behalf of someone else
  perform tests.throws(format($q$insert into public.lists (name, owner_id) values ('x', %L)$q$,
    'bbbbbbbb-0000-0000-0000-00000000000b'), 'row-level security');
  raise notice 'ok - owner creates lists and items';
end $$;

-- --------------------------------------------- strangers see nothing
do $$ begin
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  assert (select count(*) from public.lists) = 0, 'B sees no lists before joining';
  assert (select count(*) from public.items) = 0, 'B sees no items before joining';
  assert (select count(*) from public.list_members) = 0, 'B sees no memberships';
  assert (select count(*) from public.profiles where id <> auth.uid()) = 0, 'B sees no other profiles';
  perform tests.throws(format($q$insert into public.items (id, list_id, name) values (gen_random_uuid(), %L, 'hack')$q$,
    tests.get('groceries')), 'row-level security');
  perform tests.throws(format($q$select * from public.create_invitation(%L)$q$, tests.get('groceries')), 'not_list_owner');
  raise notice 'ok - non-members cannot read or write';
end $$;

-- -------------------------------------------------------- invitations
do $$
declare v_token text; v_prev record; v_cnt int;
begin
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  select token into v_token from public.create_invitation(tests.get('groceries')::uuid);
  assert length(v_token) = 64, 'token is 64 hex chars';
  perform tests.put('token', v_token);

  -- owner sees invitation metadata but never the hash
  assert (select count(*) from public.invitations) = 1, 'owner sees invitation row';
  perform tests.throws('select token_hash from public.invitations', 'permission denied');
  select status into v_prev from public.preview_invitation(v_token);
  assert v_prev.status = 'own_invitation', 'inviter previewing own invitation';
  perform tests.throws(format('select * from public.accept_invitation(%L)', v_token), 'invitation_own');

  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  assert (select count(*) from public.invitations) = 0, 'non-owner cannot list invitations';
  select * into v_prev from public.preview_invitation(v_token);
  assert v_prev.status = 'valid', 'B preview valid';
  assert v_prev.list_name = 'Groceries' and v_prev.inviter_name = 'Alice', 'preview shows list + inviter';
  assert v_prev.item_count = 2 and v_prev.member_count = 1, 'preview counts';
  -- preview has no side effects
  assert (select count(*) from public.lists) = 0, 'preview does not grant access';

  select status into v_prev from public.preview_invitation('not-a-real-token');
  assert v_prev.status = 'invalid', 'unknown token -> invalid';
  perform tests.throws($q$select * from public.accept_invitation('not-a-real-token')$q$, 'invitation_invalid');

  -- accept, then accept again (idempotent)
  select * into v_prev from public.accept_invitation(v_token);
  assert v_prev.status = 'joined' and v_prev.list_id = tests.get('groceries')::uuid, 'B joined';
  select * into v_prev from public.accept_invitation(v_token);
  assert v_prev.status = 'already_member', 'second accept is idempotent';
  select status into v_prev from public.preview_invitation(v_token);
  assert v_prev.status = 'already_member', 'preview after joining';

  perform tests.as_admin();
  select count(*) into v_cnt from public.list_members
    where list_id = tests.get('groceries')::uuid and user_id = 'bbbbbbbb-0000-0000-0000-00000000000b';
  assert v_cnt = 1, 'exactly one membership row';
  assert (select use_count from public.invitations where list_id = tests.get('groceries')::uuid) = 1, 'use_count counted once';
  assert exists (select 1 from public.connections
    where user_low = 'aaaaaaaa-0000-0000-0000-00000000000a' and user_high = 'bbbbbbbb-0000-0000-0000-00000000000b'),
    'connection A-B created';
  raise notice 'ok - invitation preview + atomic idempotent accept';
end $$;

-- ------------------------------------------- shared vs private lists
do $$ begin
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  assert (select array_agg(name) from public.lists) = array['Groceries'], 'B sees only the shared list';
  assert (select count(*) from public.items) = 2, 'B sees only shared items';
  assert not exists (select 1 from public.items where id = '11111111-0000-0000-0000-000000000009'), 'private item hidden';
  assert (select display_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-00000000000a') = 'Alice',
    'B can see connected profile';
  assert (select count(*) from public.my_connections()) = 1, 'B has one connection';
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  assert (select display_name from public.my_connections()) = 'Bob', 'A sees connection to Bob';
  raise notice 'ok - connecting does not expose private lists';
end $$;

-- ------------------------------------------------ item collaboration
do $$
declare v_item record; v_n int;
begin
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  -- spoofed authorship / timestamps are overwritten by the server
  insert into public.items (id, list_id, name, created_by, created_at, version)
  values ('22222222-0000-0000-0000-000000000001', tests.get('groceries')::uuid, 'Eggs',
          'aaaaaaaa-0000-0000-0000-00000000000a', '2000-01-01', 99);
  select * into v_item from public.items where id = '22222222-0000-0000-0000-000000000001';
  assert v_item.created_by = 'bbbbbbbb-0000-0000-0000-00000000000b', 'created_by forced to caller';
  assert v_item.created_at > now() - interval '1 minute', 'created_at is server time';
  assert v_item.version = 1, 'version starts at 1';

  -- retrying the same queued insert does not duplicate
  insert into public.items (id, list_id, name) values
    ('22222222-0000-0000-0000-000000000001', tests.get('groceries')::uuid, 'Eggs')
    on conflict (id) do nothing;
  assert (select count(*) from public.items where name = 'Eggs') = 1, 'idempotent insert';

  -- check off
  update public.items set is_purchased = true where id = '11111111-0000-0000-0000-000000000001';
  select * into v_item from public.items where id = '11111111-0000-0000-0000-000000000001';
  assert v_item.is_purchased and v_item.purchased_by = 'bbbbbbbb-0000-0000-0000-00000000000b'
     and v_item.purchased_at is not null, 'purchase metadata set by server';
  update public.items set is_purchased = false where id = '11111111-0000-0000-0000-000000000001';
  select * into v_item from public.items where id = '11111111-0000-0000-0000-000000000001';
  assert not v_item.is_purchased and v_item.purchased_by is null, 'unchecking clears purchase metadata';

  -- members cannot move items, rename or delete the list, or hard delete items
  perform tests.throws(format($q$update public.items set list_id = %L where id = '11111111-0000-0000-0000-000000000001'$q$,
    tests.get('secret')), 'permission denied');
  perform tests.throws($q$delete from public.items where id = '11111111-0000-0000-0000-000000000001'$q$, 'permission denied');
  update public.lists set name = 'Hacked' where id = tests.get('groceries')::uuid;
  get diagnostics v_n = row_count;
  assert v_n = 0, 'member cannot rename list';
  delete from public.lists where id = tests.get('groceries')::uuid;
  get diagnostics v_n = row_count;
  assert v_n = 0, 'member cannot delete list';
  perform tests.throws(format($q$select public.remove_member(%L, 'aaaaaaaa-0000-0000-0000-00000000000a')$q$,
    tests.get('groceries')), 'not_list_owner');

  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  assert (select created_by from public.items where id = '22222222-0000-0000-0000-000000000001')
    = 'bbbbbbbb-0000-0000-0000-00000000000b', 'owner sees B''s item';
  update public.lists set name = 'Weekly groceries' where id = tests.get('groceries')::uuid;
  get diagnostics v_n = row_count;
  assert v_n = 1, 'owner can rename';
  perform tests.throws(format($q$update public.lists set owner_id = 'bbbbbbbb-0000-0000-0000-00000000000b' where id = %L$q$,
    tests.get('groceries')), 'permission denied');
  raise notice 'ok - member permissions enforced server-side';
end $$;

-- --------------------------------------------------- conflict handling
do $$
declare v_item record; v_n int;
begin
  -- Field-level patches: A edits name, B edits quantity -> both survive.
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  update public.items set name = 'Sourdough bread' where id = '11111111-0000-0000-0000-000000000002';
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  update public.items set quantity = 2 where id = '11111111-0000-0000-0000-000000000002';
  select * into v_item from public.items where id = '11111111-0000-0000-0000-000000000002';
  assert v_item.name = 'Sourdough bread' and v_item.quantity = 2, 'non-overlapping field edits merge';
  assert v_item.version = 3, 'version increments per write';

  -- Same field: the last write to reach the server wins.
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  update public.items set note = 'from A' where id = '11111111-0000-0000-0000-000000000002';
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  update public.items set note = 'from B' where id = '11111111-0000-0000-0000-000000000002';
  assert (select note from public.items where id = '11111111-0000-0000-0000-000000000002') = 'from B', 'last write wins';

  -- Delete wins: A tombstones, B's queued edit (sent with the client's
  -- "deleted_at is null" guard) affects nothing, and an unguarded edit fails.
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  update public.items set deleted_at = now() where id = '11111111-0000-0000-0000-000000000002';
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  update public.items set name = 'zombie' where id = '11111111-0000-0000-0000-000000000002' and deleted_at is null;
  get diagnostics v_n = row_count;
  assert v_n = 0, 'guarded edit of deleted item is a no-op';
  perform tests.throws($q$update public.items set name = 'zombie', deleted_at = null where id = '11111111-0000-0000-0000-000000000002'$q$,
    'item_deleted');
  -- a retried insert with the same id cannot resurrect it either
  insert into public.items (id, list_id, name) values
    ('11111111-0000-0000-0000-000000000002', tests.get('groceries')::uuid, 'zombie')
    on conflict (id) do nothing;
  select * into v_item from public.items where id = '11111111-0000-0000-0000-000000000002';
  assert v_item.deleted_at is not null and v_item.name = 'Sourdough bread', 'tombstone is permanent';
  raise notice 'ok - conflict resolution (field LWW, delete wins, no resurrection)';
end $$;

-- ---------------------------------------- third user via same invitation
do $$
declare v_res record;
begin
  perform tests.as_user('cccccccc-0000-0000-0000-00000000000c');
  select * into v_res from public.accept_invitation(tests.get('token'));
  assert v_res.status = 'joined', 'C joined';
  assert (select count(*) from public.list_members where list_id = tests.get('groceries')::uuid) = 3, 'three members';
  assert (select display_name from public.profiles where id = 'bbbbbbbb-0000-0000-0000-00000000000b') = 'Bob',
    'co-members can see each other';
  assert (select array_agg(display_name) from public.my_connections()) = array['Alice'],
    'C is connected to the inviter only';

  perform tests.as_user('dddddddd-0000-0000-0000-00000000000d');
  assert (select count(*) from public.profiles where id <> auth.uid()) = 0, 'stranger still sees nobody';
  raise notice 'ok - third user joins through the same invitation';
end $$;

-- ----------------------------------------------- expired & revoked
do $$
declare v_token text; v_prev record;
begin
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  select token into v_token from public.create_invitation(tests.get('secret')::uuid, 1);
  perform tests.as_admin();
  update public.invitations set expires_at = now() - interval '1 second'
    where token_hash = sha256(convert_to(v_token, 'UTF8'));

  perform tests.as_user('dddddddd-0000-0000-0000-00000000000d');
  select * into v_prev from public.preview_invitation(v_token);
  assert v_prev.status = 'expired' and v_prev.list_name is null, 'expired preview hides list details';
  perform tests.throws(format('select * from public.accept_invitation(%L)', v_token), 'invitation_expired');

  -- an existing member retrying an expired invitation still gets success
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  select * into v_prev from public.accept_invitation(tests.get('token'));
  perform tests.as_admin();
  update public.invitations set expires_at = now() - interval '1 second'
    where token_hash = sha256(convert_to(tests.get('token'), 'UTF8'));
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  select * into v_prev from public.accept_invitation(tests.get('token'));
  assert v_prev.status = 'already_member', 'retry after expiry stays idempotent';
  -- membership outlives the invitation
  assert (select count(*) from public.lists) = 1, 'membership survives invitation expiry';

  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  select token into v_token from public.create_invitation(tests.get('groceries')::uuid);
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  perform tests.throws(format($q$select public.revoke_invitation((select id from public.invitations limit 1))$q$), 'invitation_not_found');
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.revoke_invitation((select id from public.invitations where revoked_at is null and expires_at > now()
    and list_id = tests.get('groceries')::uuid));
  perform tests.as_user('dddddddd-0000-0000-0000-00000000000d');
  select status into v_prev from public.preview_invitation(v_token);
  assert v_prev.status = 'revoked', 'revoked preview';
  perform tests.throws(format('select * from public.accept_invitation(%L)', v_token), 'invitation_revoked');
  raise notice 'ok - expired / revoked invitations rejected';
end $$;

-- ------------------------------------------- sharing with connections
do $$ begin
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.add_connection_to_list(tests.get('secret')::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b');
  perform public.add_connection_to_list(tests.get('secret')::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'); -- idempotent
  perform tests.throws(format($q$select public.add_connection_to_list(%L, 'dddddddd-0000-0000-0000-00000000000d')$q$,
    tests.get('secret')), 'not_connected');
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  assert (select count(*) from public.lists) = 2, 'B now sees the second list';
  perform tests.throws(format($q$select public.add_connection_to_list(%L, 'cccccccc-0000-0000-0000-00000000000c')$q$,
    tests.get('groceries')), 'not_list_owner');
  -- B leaves the second list
  perform public.leave_list(tests.get('secret')::uuid);
  assert (select count(*) from public.lists) = 1, 'B left the list';
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform tests.throws(format('select public.leave_list(%L)', tests.get('groceries')), 'owner_cannot_leave');
  raise notice 'ok - share with existing connection, leave list';
end $$;

-- ---------------------------------------------------- remove member
do $$
declare v_n int;
begin
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.remove_member(tests.get('groceries')::uuid, 'cccccccc-0000-0000-0000-00000000000c');
  perform tests.throws(format($q$select public.remove_member(%L, 'aaaaaaaa-0000-0000-0000-00000000000a')$q$,
    tests.get('groceries')), 'owner_cannot_be_removed');
  perform tests.as_user('cccccccc-0000-0000-0000-00000000000c');
  assert (select count(*) from public.lists) = 0, 'removed member loses the list';
  assert (select count(*) from public.items) = 0, 'removed member loses items';
  -- offline edit arriving after removal does nothing / is rejected
  update public.items set name = 'late' where id = '11111111-0000-0000-0000-000000000001';
  get diagnostics v_n = row_count;
  assert v_n = 0, 'late update after removal ignored';
  perform tests.throws(format($q$insert into public.items (id, list_id, name) values (gen_random_uuid(), %L, 'late')$q$,
    tests.get('groceries')), 'row-level security');
  -- C stays connected to A (removal is per list)
  assert (select count(*) from public.my_connections()) = 1, 'removal keeps the connection';
  raise notice 'ok - removing a member revokes access';
end $$;

-- ------------------------------------------------------- disconnect
-- Setup: Carol owns "Carol's party" shared with A and B.
--        Bob owns "Bob's list" shared with A.
--        A disconnects from B.
-- Expect: B loses A's lists, A loses B's lists, both keep Carol's list.
do $$
declare v_party uuid; v_bob uuid; v_tok text; v_r record;
begin
  perform tests.as_user('cccccccc-0000-0000-0000-00000000000c');
  insert into public.lists (name, owner_id) values ('Carol''s party', auth.uid()) returning id into v_party;
  perform tests.put('party', v_party::text);
  insert into public.items (id, list_id, name) values ('33333333-0000-0000-0000-000000000001', v_party, 'Balloons');
  select token into v_tok from public.create_invitation(v_party);
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.accept_invitation(v_tok);
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  perform public.accept_invitation(v_tok);
  insert into public.lists (name, owner_id) values ('Bob''s list', auth.uid()) returning id into v_bob;
  perform tests.put('boblist', v_bob::text);
  perform public.add_connection_to_list(v_bob, 'aaaaaaaa-0000-0000-0000-00000000000a');

  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  assert (select count(*) from public.lists) = 4, 'A: 2 own + party + Bob''s';
  select * into v_r from public.disconnect('bbbbbbbb-0000-0000-0000-00000000000b');
  assert v_r.lists_revoked = 2, 'two memberships revoked';
  assert (select array_agg(name order by name) from public.lists)
    = array['Carol''s party', 'Secret gifts', 'Weekly groceries'], 'A keeps own + third-party list';
  assert (select count(*) from public.my_connections()) = 1, 'A still connected to Carol only';

  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  assert (select array_agg(name order by name) from public.lists)
    = array['Bob''s list', 'Carol''s party'], 'B keeps own + third-party list';
  assert (select count(*) from public.items where list_id = tests.get('groceries')::uuid) = 0, 'B lost A''s items';
  assert (select count(*) from public.list_members where list_id = v_party) = 3, 'unrelated list keeps all members';
  -- Bob can still see Alice's profile because they still share Carol's list
  assert exists (select 1 from public.profiles where id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 'co-member visibility remains';
  assert (select count(*) from public.my_connections()) = 1, 'B connected to Carol only';
  raise notice 'ok - disconnect revokes only between the two users';
end $$;

-- ------------------------------------------------ ownership transfer
do $$ begin
  perform tests.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  perform tests.throws(format($q$select public.transfer_ownership(%L, 'dddddddd-0000-0000-0000-00000000000d')$q$,
    tests.get('boblist')), 'new_owner_not_member');
  perform tests.as_user('cccccccc-0000-0000-0000-00000000000c');
  perform public.transfer_ownership(tests.get('party')::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a');
  assert (select owner_id from public.lists where id = tests.get('party')::uuid) = 'aaaaaaaa-0000-0000-0000-00000000000a',
    'ownership transferred';
  assert (select role from public.list_members where list_id = tests.get('party')::uuid and user_id = auth.uid()) = 'member',
    'old owner becomes member';
  perform tests.throws(format('select * from public.create_invitation(%L)', tests.get('party')), 'not_list_owner');
  -- transfer back for the account deletion test
  perform tests.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.transfer_ownership(tests.get('party')::uuid, 'cccccccc-0000-0000-0000-00000000000c');
  raise notice 'ok - ownership transfer';
end $$;

-- --------------------------------------------------- delete account
do $$
declare v_private uuid;
begin
  perform tests.as_user('cccccccc-0000-0000-0000-00000000000c');
  insert into public.lists (name, owner_id) values ('Carol private', auth.uid()) returning id into v_private;
  perform tests.put('carolprivate', v_private::text);
  perform tests.throws(format($q$select public.delete_account(jsonb_build_object(%L, 'dddddddd-0000-0000-0000-00000000000d'))$q$,
    tests.get('party')), 'new_owner_not_member');
  perform public.delete_account(jsonb_build_object(tests.get('party'), 'bbbbbbbb-0000-0000-0000-00000000000b'));

  perform tests.as_admin();
  assert not exists (select 1 from auth.users where id = 'cccccccc-0000-0000-0000-00000000000c'), 'auth user deleted';
  assert not exists (select 1 from public.profiles where id = 'cccccccc-0000-0000-0000-00000000000c'), 'profile deleted';
  assert not exists (select 1 from public.lists where id = tests.get('carolprivate')::uuid), 'untransferred list deleted';
  assert (select owner_id from public.lists where id = tests.get('party')::uuid) = 'bbbbbbbb-0000-0000-0000-00000000000b',
    'transferred list survives with new owner';
  assert (select created_by from public.items where id = '33333333-0000-0000-0000-000000000001') is null,
    'items keep existing with anonymised creator';
  assert not exists (select 1 from public.connections where 'cccccccc-0000-0000-0000-00000000000c' in (user_low, user_high)),
    'connections removed';
  raise notice 'ok - account deletion with transfer';
end $$;

-- ------------------------------------------------- purchases: setup
-- E = Eve (owner of "Flat"), F = Frank (member), G = Grace (outsider)
do $$
declare v_flat uuid; v_token text;
begin
  perform tests.as_admin();
  insert into auth.users (id, email, raw_user_meta_data) values
    ('eeeeeeee-0000-0000-0000-00000000000e', 'e@example.com', '{"display_name":"Eve"}'),
    ('ffffffff-0000-0000-0000-00000000000f', 'f@example.com', '{"display_name":"Frank"}'),
    ('99999999-0000-0000-0000-000000000009', 'g@example.com', '{"display_name":"Grace"}');

  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  assert (select currency from public.profiles where id = auth.uid()) = 'PLN', 'default currency is PLN';
  update public.profiles set currency = 'EUR' where id = auth.uid();
  assert (select currency from public.profiles where id = auth.uid()) = 'EUR', 'currency can be changed';
  perform tests.throws($q$update public.profiles set currency = 'euro' where id = auth.uid()$q$, 'check constraint');
  update public.profiles set currency = 'PLN' where id = auth.uid();

  insert into public.lists (name, owner_id) values ('Flat', auth.uid()) returning id into v_flat;
  perform tests.put('flat', v_flat::text);
  insert into public.items (id, list_id, name, quantity, unit) values
    ('55555555-0000-0000-0000-000000000001', v_flat, 'Milk', 2, 'l'),
    ('55555555-0000-0000-0000-000000000002', v_flat, 'Bread', null, null),
    ('55555555-0000-0000-0000-000000000003', v_flat, 'Soap', null, null);
  select token into v_token from public.create_invitation(v_flat);

  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.accept_invitation(v_token);
  raise notice 'ok - currency setting';
end $$;

-- ------------------------------------------------------- categories
do $$
declare v_version int;
begin
  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  select version into v_version from public.items where id = '55555555-0000-0000-0000-000000000003';
  update public.items set category = 'pantry' where id = '55555555-0000-0000-0000-000000000003';
  assert (select category from public.items where id = '55555555-0000-0000-0000-000000000003') = 'pantry',
    'member sets a category';
  assert (select version from public.items where id = '55555555-0000-0000-0000-000000000003') = v_version + 1,
    'category change bumps the version';
  update public.items set category = null where id = '55555555-0000-0000-0000-000000000003';
  perform tests.throws($q$update public.items set category = 'Not valid!' where id = '55555555-0000-0000-0000-000000000003'$q$,
    'check constraint');
  perform tests.as_user('99999999-0000-0000-0000-000000000009');
  update public.items set category = 'pantry' where id = '55555555-0000-0000-0000-000000000003';
  perform tests.as_admin();
  assert (select category from public.items where id = '55555555-0000-0000-0000-000000000003') is null,
    'non-members cannot change categories';
  raise notice 'ok - item categories';
end $$;

-- --------------------------------------------- purchases: record + split
do $$
declare v_flat uuid := tests.get('flat')::uuid;
begin
  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.record_purchase(
    '66666666-0000-0000-0000-000000000001', v_flat, 100.00, 'PLN',
    'ffffffff-0000-0000-0000-00000000000f',
    array['eeeeeeee-0000-0000-0000-00000000000e', 'ffffffff-0000-0000-0000-00000000000f']::uuid[],
    array['55555555-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000002']::uuid[],
    '  Weekly shop  ');
  -- retried request: no error, no duplicate
  perform public.record_purchase(
    '66666666-0000-0000-0000-000000000001', v_flat, 100.00, 'PLN',
    'ffffffff-0000-0000-0000-00000000000f',
    array['eeeeeeee-0000-0000-0000-00000000000e', 'ffffffff-0000-0000-0000-00000000000f']::uuid[],
    array['55555555-0000-0000-0000-000000000001']::uuid[]);

  assert (select count(*) from public.expenses) = 1, 'one expense after a retry';
  assert (select list_name || '|' || amount || '|' || currency || '|' || note from public.expenses)
    = 'Flat|100.00|PLN|Weekly shop', 'expense fields stored and note trimmed';
  assert (select created_by from public.expenses) = auth.uid(), 'creator set by the server';
  assert (select array_agg(amount order by user_id) from public.expense_shares) = array[50.00, 50.00]::numeric[],
    'equal split';
  assert (select array_agg(name order by name) from public.expense_items) = array['Bread', 'Milk'],
    'item snapshot';
  assert (select count(*) from public.items where list_id = v_flat and deleted_at is not null) = 2,
    'bought items leave the list';
  assert (select deleted_at from public.items where id = '55555555-0000-0000-0000-000000000003') is null,
    'unselected items stay';

  -- leftover cents: 0.05 between two people -> 0.03 + 0.02 (lowest id gets the extra cent)
  perform public.record_purchase(
    '66666666-0000-0000-0000-000000000002', v_flat, 0.05, 'PLN',
    'eeeeeeee-0000-0000-0000-00000000000e',
    array['ffffffff-0000-0000-0000-00000000000f', 'eeeeeeee-0000-0000-0000-00000000000e',
          'eeeeeeee-0000-0000-0000-00000000000e']::uuid[]);
  assert (select array_agg(amount order by user_id) from public.expense_shares
          where expense_id = '66666666-0000-0000-0000-000000000002') = array[0.03, 0.02]::numeric[],
    'cents distributed, duplicates ignored';
  raise notice 'ok - record purchase, split, idempotency';
end $$;

-- ------------------------------------------- purchases: validation + RLS
do $$
declare v_flat uuid := tests.get('flat')::uuid;
begin
  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 0, 'PLN', auth.uid(), array[auth.uid()])$q$, v_flat), 'invalid_amount');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 1.234, 'PLN', auth.uid(), array[auth.uid()])$q$, v_flat), 'invalid_amount');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 5, 'zl', auth.uid(), array[auth.uid()])$q$, v_flat), 'invalid_currency');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 5, 'PLN', auth.uid(), '{}')$q$, v_flat), 'invalid_participants');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 5, 'PLN', auth.uid(), array['99999999-0000-0000-0000-000000000009'::uuid])$q$, v_flat), 'participant_not_member');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 5, 'PLN', '99999999-0000-0000-0000-000000000009', array[auth.uid()])$q$, v_flat), 'participant_not_member');
  perform tests.throws($q$insert into public.expenses (id, list_name, amount, currency) values (gen_random_uuid(), 'x', 1, 'PLN')$q$, 'permission denied');
  perform tests.throws($q$update public.expense_shares set amount = 0$q$, 'permission denied');
  assert (select count(*) from public.expenses) = 2, 'members see the list''s expenses';

  perform tests.as_user('99999999-0000-0000-0000-000000000009');
  perform tests.throws(format($q$select public.record_purchase(gen_random_uuid(), %L, 5, 'PLN', auth.uid(), array[auth.uid()])$q$, v_flat), 'not_list_member');
  assert (select count(*) from public.expenses) = 0, 'outsider sees no expenses';
  assert (select count(*) from public.expense_shares) = 0, 'outsider sees no shares';
  assert (select count(*) from public.expense_items) = 0, 'outsider sees no items';
  perform tests.throws($q$select public.delete_expense('66666666-0000-0000-0000-000000000001')$q$, 'expense_not_found');
  raise notice 'ok - purchase validation and visibility';
end $$;

-- ------------------------------------------------------- settlements
do $$ begin
  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  -- Eve records that Frank paid her back
  perform public.record_settlement('77777777-0000-0000-0000-000000000001',
    'ffffffff-0000-0000-0000-00000000000f', 'eeeeeeee-0000-0000-0000-00000000000e', 50, 'PLN');
  perform public.record_settlement('77777777-0000-0000-0000-000000000001',
    'ffffffff-0000-0000-0000-00000000000f', 'eeeeeeee-0000-0000-0000-00000000000e', 50, 'PLN');
  assert (select count(*) from public.settlements) = 1, 'settlement idempotent';
  perform tests.throws($q$select public.record_settlement(gen_random_uuid(), 'ffffffff-0000-0000-0000-00000000000f', 'cccccccc-0000-0000-0000-00000000000c', 5, 'PLN')$q$, 'not_settlement_party');
  perform tests.throws($q$select public.record_settlement(gen_random_uuid(), auth.uid(), auth.uid(), 5, 'PLN')$q$, 'invalid_participants');
  perform tests.throws($q$select public.record_settlement(gen_random_uuid(), auth.uid(), 'ffffffff-0000-0000-0000-00000000000f', -5, 'PLN')$q$, 'invalid_amount');

  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  assert (select count(*) from public.settlements) = 1, 'the other party sees it';
  perform tests.throws($q$select public.delete_settlement('77777777-0000-0000-0000-000000000001')$q$, 'settlement_not_found');

  perform tests.as_user('99999999-0000-0000-0000-000000000009');
  assert (select count(*) from public.settlements) = 0, 'outsider sees no settlements';
  perform tests.throws($q$select public.record_settlement(gen_random_uuid(), auth.uid(), 'eeeeeeee-0000-0000-0000-00000000000e', 5, 'PLN')$q$, 'not_connected');

  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  perform public.delete_settlement('77777777-0000-0000-0000-000000000001');
  assert (select count(*) from public.settlements) = 0, 'creator deletes settlement';
  raise notice 'ok - settlements';
end $$;

-- ------------------------------- purchases survive leaving and list deletion
do $$
declare v_flat uuid := tests.get('flat')::uuid;
begin
  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.leave_list(v_flat);
  assert (select count(*) from public.expenses) = 2, 'participant still sees their expenses after leaving';
  assert (select display_name from public.profiles where id = 'eeeeeeee-0000-0000-0000-00000000000e') = 'Eve',
    'names stay visible through shared expenses';
  perform public.record_settlement(gen_random_uuid(),
    auth.uid(), 'eeeeeeee-0000-0000-0000-00000000000e', 10, 'PLN');

  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  perform tests.throws($q$select public.delete_expense('66666666-0000-0000-0000-000000000001')$q$, 'expense_not_found');
  delete from public.lists where id = v_flat;
  assert (select count(*) from public.expenses where list_id is null and list_name = 'Flat') = 2,
    'expenses outlive the list';

  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.delete_expense('66666666-0000-0000-0000-000000000001');
  assert (select count(*) from public.expenses) = 1, 'payer deletes an expense';
  perform tests.as_admin();
  assert not exists (select 1 from public.expense_shares where expense_id = '66666666-0000-0000-0000-000000000001'),
    'shares deleted with the expense';
  raise notice 'ok - purchases outlive membership and lists';
end $$;

-- ------------------------------------ account deletion and purchases
do $$ begin
  perform tests.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.delete_account();
  perform tests.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  assert (select count(*) from public.expenses) = 1, 'a purchase that still involves Eve stays';
  assert (select count(*) from public.expense_shares) = 1, 'the deleted user''s share is gone';
  assert (select count(*) from public.settlements) = 0, 'settlements with the deleted user are gone';
  perform public.delete_account();
  perform tests.as_admin();
  assert (select count(*) from public.expenses where list_name = 'Flat') = 0, 'orphaned purchases are deleted';
  raise notice 'ok - account deletion cleans up purchases';
end $$;

-- ------------------------------------------------------- anonymous
do $$ begin
  perform set_config('role', 'anon', true);
  perform tests.throws('select * from public.lists', 'permission denied');
  perform tests.throws($q$select * from public.preview_invitation('x')$q$, 'permission denied');
  perform tests.throws($q$select public.delete_expense(gen_random_uuid())$q$, 'permission denied');
  perform tests.throws('select * from public.expenses', 'permission denied');
  perform tests.as_admin();
  -- authenticated role without a user id
  perform set_config('role', 'authenticated', true);
  perform tests.throws($q$select * from public.accept_invitation('x')$q$, 'not_authenticated');
  perform tests.as_admin();
  raise notice 'ok - anonymous access denied';
end $$;

do $$ begin raise notice 'ALL BACKEND TESTS PASSED'; end $$;
rollback;
