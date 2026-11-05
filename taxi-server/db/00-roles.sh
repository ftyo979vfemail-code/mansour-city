#!/bin/sh
# Creates the two roles PostgREST uses. Runs before 01-schema.sql on first start.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
create role web_anon nologin;
create role authenticator login noinherit password '${AUTHENTICATOR_PASSWORD}';
grant web_anon to authenticator;
SQL
