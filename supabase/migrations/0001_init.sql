-- Albine Messenger — initial schema
-- Portable Postgres/RLS: only relies on Supabase Auth (auth.uid()), Realtime
-- (logical replication) and Storage (S3-compatible) — no proprietary lock-in
-- beyond those three explicitly-chosen building blocks.
--
-- Safe to re-run: starts by dropping its own tables/function if a previous
-- partial run left anything behind.

drop function if exists create_direct_conversation(uuid);
drop function if exists is_conversation_member(uuid, uuid);
drop function if exists is_conversation_admin(uuid, uuid);
drop table if exists push_subscriptions cascade;
drop table if exists messages cascade;
drop table if exists conversation_members cascade;
drop table if exists conversations cascade;
drop table if exists profiles cascade;

-- ============================================================================
-- Tables first — policies below reference each other across tables, so every
-- table must exist before any policy is created.
-- ============================================================================

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null,
  avatar_url text,
  identity_pubkey text not null,        -- base64-encoded X25519 public key (32 bytes)
  identity_pubkey_alg text not null default 'x25519',
  created_at timestamptz not null default now()
);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('direct', 'group')),
  title text,                             -- null for direct conversations
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table conversation_members (
  conversation_id uuid references conversations(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  wrapped_group_key text,               -- base64-encoded sealed group key; null for 'direct'
  wrapped_group_key_alg text default 'sealedbox_x25519',
  key_version int not null default 1,     -- bumped on rotation (post-v1)
  primary key (conversation_id, user_id)
);
create index conversation_members_user_id_idx on conversation_members (user_id);

-- messages: ciphertext only. Schema is wide from day one (M2/M3 columns
-- already present) so retrofitting groups/media later never requires
-- migrating a live table with dependent RLS policies.
create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  ciphertext text not null,               -- base64-encoded
  nonce text not null,                    -- base64-encoded (24 bytes for direct, 24 for group AEAD)
  sender_ephemeral_pubkey text,           -- reserved for future ratcheting, null in v1
  content_type text not null default 'text' check (content_type in ('text', 'image', 'file', 'system')),
  key_version int not null default 1,
  media_object_path text,                  -- Storage path; null until M3
  media_wrapped_key text,
  media_nonce text,
  media_size_bytes bigint,
  media_mime_hint text,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz
);
create index messages_conversation_created_idx on messages (conversation_id, created_at desc);

-- push_subscriptions: standard Web Push subscription record (RFC 8291).
-- Not used until M4, created now so the schema doesn't need another migration.
create table push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_key text not null,
  device_label text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- ============================================================================
-- RLS helper functions. SECURITY DEFINER + owned by the migration role means
-- these run with RLS bypassed *inside the function body only* (Postgres
-- exempts a table's owner from its own RLS unless FORCE ROW LEVEL SECURITY
-- is set, which we don't use). Policies below call these instead of
-- re-querying conversation_members directly from within a policy defined ON
-- conversation_members itself — doing that directly causes Postgres to
-- re-evaluate that same policy for the subquery, which re-triggers it again,
-- forever ("infinite recursion detected in policy for relation
-- conversation_members", code 42P17).
-- ============================================================================

create or replace function is_conversation_member(p_conversation_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = p_user_id
  );
$$;

create or replace function is_conversation_admin(p_conversation_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id
      and user_id = p_user_id
      and role in ('owner', 'admin')
  );
$$;

alter table profiles enable row level security;

create policy "profiles readable by authenticated"
  on profiles for select
  using (auth.uid() is not null);

create policy "profiles insert self"
  on profiles for insert
  with check (auth.uid() = id);

create policy "profiles update self"
  on profiles for update
  using (auth.uid() = id);

alter table conversations enable row level security;

create policy "select conversations you belong to"
  on conversations for select
  using (is_conversation_member(id, auth.uid()));

create policy "insert conversation as creator"
  on conversations for insert
  with check (created_by = auth.uid());

alter table conversation_members enable row level security;

create policy "members can see membership of their conversations"
  on conversation_members for select
  using (is_conversation_member(conversation_id, auth.uid()));

create policy "owner/admin can add members, or self at creation"
  on conversation_members for insert
  with check (
    is_conversation_admin(conversation_id, auth.uid())
    or user_id = auth.uid()
  );

create policy "members can update own membership row"
  on conversation_members for update
  using (user_id = auth.uid());

create policy "owner/admin can remove members"
  on conversation_members for delete
  using (is_conversation_admin(conversation_id, auth.uid()));

alter table messages enable row level security;

create policy "select messages in your conversations"
  on messages for select
  using (is_conversation_member(conversation_id, auth.uid()));

create policy "insert messages into your conversations as yourself"
  on messages for insert
  with check (
    sender_id = auth.uid()
    and is_conversation_member(conversation_id, auth.uid())
  );

create policy "soft-delete/edit own messages"
  on messages for update
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

alter table push_subscriptions enable row level security;

create policy "manage own subscriptions"
  on push_subscriptions for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================================
-- realtime: broadcast row changes on messages/conversation_members so clients
-- get live updates without polling
-- ============================================================================
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table conversation_members;

-- ============================================================================
-- helper RPC: create a direct conversation between two users atomically
-- (avoids a race where the conversation exists but member rows don't)
-- ============================================================================
create or replace function create_direct_conversation(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_id uuid;
  new_id uuid;
begin
  select c.id into existing_id
  from conversations c
  where c.kind = 'direct'
    and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = auth.uid())
    and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = other_user_id)
  limit 1;

  if existing_id is not null then
    return existing_id;
  end if;

  insert into conversations (kind, created_by) values ('direct', auth.uid())
  returning id into new_id;

  insert into conversation_members (conversation_id, user_id) values
    (new_id, auth.uid()),
    (new_id, other_user_id);

  return new_id;
end;
$$;
