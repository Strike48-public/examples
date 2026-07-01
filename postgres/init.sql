-- Runs once, as the postgres superuser, on first cluster init.
-- Databases for Keycloak and for Matrix Studio (Ecto repos + pgvector).
-- Mirrors the role/db layout the dev VM uses (db-provision.nix).

CREATE ROLE keycloak LOGIN PASSWORD 'keycloak';
CREATE DATABASE keycloak OWNER keycloak;

-- Studio backend: MatrixData/Asoc/Watchtower/Strikekit repos share `elixir`.
-- elixir_user is a superuser so the boot migrator has free rein.
CREATE ROLE elixir_user LOGIN PASSWORD 'elixir_password' SUPERUSER;
CREATE DATABASE elixir OWNER elixir_user;

-- Matrix RAG repo has its own database.
CREATE ROLE rag LOGIN PASSWORD 'password';
CREATE DATABASE rag OWNER rag;

\connect elixir
CREATE EXTENSION IF NOT EXISTS vector;

\connect rag
CREATE EXTENSION IF NOT EXISTS vector;
