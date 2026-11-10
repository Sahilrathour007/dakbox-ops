-- SECURITY FIX: run once in Supabase -> SQL Editor.
-- Supabase gives the public "anon" key permission on every new function automatically.
-- These staff functions must only run for logged-in staff.
revoke execute on function public.set_order_status(text,text,text) from public, anon;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
revoke execute on function public.confirm_allocations(numeric,int) from public, anon;
revoke execute on function public.new_awb() from public, anon, authenticated;
revoke execute on function public.block_edits() from public, anon, authenticated;
revoke execute on function public.on_gps_ping() from public, anon, authenticated;

grant execute on function public.set_order_status(text,text,text) to authenticated;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
grant execute on function public.confirm_allocations(numeric,int) to authenticated;

-- Stop future functions from being open to the public by default.
alter default privileges in schema public revoke execute on functions from public, anon;
