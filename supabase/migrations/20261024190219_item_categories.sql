-- Store section picked by hand for an item. NULL means the app guesses it
-- from the name (Polish and English keyword lists on the device), so most
-- rows never need a value.

alter table public.items
  add column category text check (category is null or category ~ '^[a-z_]{1,32}$');

grant update (category) on public.items to authenticated;
