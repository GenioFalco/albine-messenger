-- Group management: rename title (member add/remove already work today via
-- existing policies — "owner/admin can add members, or self at creation" on
-- conversation_members already covers post-creation adds, and "owner/admin
-- can remove members" already covers removal; neither needed a new policy).
--
-- `conversations` had no UPDATE policy at all before this — title editing
-- was impossible for anyone. Scoped to the conversation's owner/admin via
-- the existing is_conversation_admin() helper. Direct conversations are
-- unaffected in practice: create_direct_conversation() never sets a role,
-- so both members default to 'member' and is_conversation_admin() is always
-- false for them — there is no path to renaming a 1:1 chat's (null) title.
create policy "owner/admin can rename conversation"
  on conversations for update
  using (is_conversation_admin(id, auth.uid()))
  with check (is_conversation_admin(id, auth.uid()));
