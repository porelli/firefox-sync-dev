-- The grants of the admin UI's reader of the Sync data (ADMIN_DB_SYNC_USER) on the Sync
-- tables, given by their owner at every start (new tables of an upgrade too), see
-- DATABASES.md. Applied by db_init.sh when ADMIN_DB_PASSWORD is set and the role exists.
-- The admin UI's database (ADMIN_DB_NAME) is its other role's (ADMIN_DB_USER): neither this
-- one nor the Sync server's role has a grant there.
-- As POSTGRES_USER, a superuser in the stack's container: GRANT runs no code of the tables'
-- owner, and every name here is schema-qualified, pg_catalog alone in the search path.
SET search_path = pg_catalog, pg_temp;

-- the tables of syncstorage-rs (accounts, nodes, max users, what each account stores);
-- also the admin UI's tables of before, which it moves into its own database
GRANT CONNECT ON DATABASE @POSTGRES_DATABASE@ TO @ADMIN_SYNC_USER@;
GRANT USAGE ON SCHEMA public TO @ADMIN_SYNC_USER@;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO @ADMIN_SYNC_USER@;
-- max users (MAX_USERS=initial:N)
GRANT UPDATE (config_value) ON public.config TO @ADMIN_SYNC_USER@;
-- resets, deleted accounts and purges: rows of users and what their storage holds
GRANT DELETE ON public.users, public.bsos, public.user_collections, public.batches, public.batch_bsos TO @ADMIN_SYNC_USER@;
GRANT EXECUTE ON FUNCTION public.ffs_drop_admin_tables() TO @ADMIN_SYNC_USER@;
