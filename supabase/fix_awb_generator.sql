-- FIX: booking failed with "function gen_random_bytes(integer) does not exist".
-- Run once in Supabase -> SQL Editor. Makes the AWB generator use a built-in random function.
create or replace function public.new_awb() returns text language sql volatile set search_path = pg_catalog as $$
  select '7' || lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))::bit(48)::bigint) % 100000000000)::text, 11, '0')
$$;
revoke execute on function public.new_awb() from public, anon, authenticated;
