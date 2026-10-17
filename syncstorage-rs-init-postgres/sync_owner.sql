-- The Sync server's own role (POSTGRES_SYNC_USER), which is no superuser, given the Sync
-- database's objects by db_init.sh at every start as the container's superuser
-- (POSTGRES_USER), before the migrations and again after them: the right to create them in
-- public (the migrations and db_init.sql run as this role), and those of a database from
-- before it, which the migrations and this container created as POSTGRES_USER (tables,
-- the functions and types of the migrations, check_user_limit, ffs_drop_admin_tables, the
-- admin UI's tables of before). Nothing on the admin UI's database (DATABASES.md).
-- Only GRANT, REVOKE and ALTER ... OWNER, which run no code of the objects' owner, over the
-- catalogs, with pg_catalog alone in the search path: nothing the Sync server's role put in
-- public stands in for a name here. What reads or writes the tables runs as that role.
SET search_path = pg_catalog, pg_temp;
GRANT CONNECT, TEMPORARY ON DATABASE @POSTGRES_DATABASE@ TO @SYNC_USER@;
GRANT USAGE, CREATE ON SCHEMA public TO @SYNC_USER@;
-- the others connect only with a grant (the admin UI's reader has one, its other role none)
REVOKE ALL ON DATABASE @POSTGRES_DATABASE@ FROM PUBLIC;

DO $$
DECLARE
    sync_role CONSTANT regrole := '@SYNC_USER@'::regrole;
    r record;
BEGIN
    -- tables, views, sequences but those of a column (they go with their table); in each
    -- loop not the members of an extension (they stay its owner's)
    FOR r IN SELECT c.oid::regclass AS name, c.relkind FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') AND c.relowner <> sync_role
          AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                   AND d.objid = c.oid AND d.deptype IN ('a', 'i')))
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO %I', CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
            WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END, r.name, sync_role);
    END LOOP;
    FOR r IN SELECT p.oid::regprocedure AS name, p.prokind FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proowner <> sync_role
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO %I', CASE r.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE'
            ELSE 'FUNCTION' END, r.name, sync_role);
    END LOOP;
    -- types of their own (post_bso...), not the row types of tables nor the arrays
    FOR r IN SELECT t.oid::regtype AS name, t.typtype FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typowner <> sync_role AND t.typtype IN ('c', 'e', 'd', 'r')
          AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO %I', CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.name, sync_role);
    END LOOP;
END
$$;
