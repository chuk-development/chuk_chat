-- Fix RLS performance: wrap auth.uid() in (select ...) to prevent per-row re-evaluation.
-- See: https://supabase.com/docs/guides/database/database-linter?lint=0003_auth_rls_initplan

-- Helper: recreate a policy with (select auth.uid()) instead of auth.uid()
-- We drop and recreate each affected policy.

------------------------------------------------------------
-- profiles
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can select own profile" ON public.profiles;
CREATE POLICY "Users can select own profile" ON public.profiles
  FOR SELECT USING (id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT WITH CHECK (id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING (id = (select auth.uid()));

------------------------------------------------------------
-- theme_settings
------------------------------------------------------------
DROP POLICY IF EXISTS "Theme select own" ON public.theme_settings;
CREATE POLICY "Theme select own" ON public.theme_settings
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Theme upsert own" ON public.theme_settings;
CREATE POLICY "Theme upsert own" ON public.theme_settings
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Theme update own" ON public.theme_settings;
CREATE POLICY "Theme update own" ON public.theme_settings
  FOR UPDATE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- encrypted_chats
------------------------------------------------------------
DROP POLICY IF EXISTS "Users insert their chats" ON public.encrypted_chats;
CREATE POLICY "Users insert their chats" ON public.encrypted_chats
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users read their chats" ON public.encrypted_chats;
CREATE POLICY "Users read their chats" ON public.encrypted_chats
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users delete their chats" ON public.encrypted_chats;
CREATE POLICY "Users delete their chats" ON public.encrypted_chats
  FOR DELETE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own chats" ON public.encrypted_chats;
CREATE POLICY "Users can update their own chats" ON public.encrypted_chats
  FOR UPDATE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- user_preferences
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view their own preferences" ON public.user_preferences;
CREATE POLICY "Users can view their own preferences" ON public.user_preferences
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own preferences" ON public.user_preferences;
CREATE POLICY "Users can insert their own preferences" ON public.user_preferences
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own preferences" ON public.user_preferences;
CREATE POLICY "Users can update their own preferences" ON public.user_preferences
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete their own preferences" ON public.user_preferences;
CREATE POLICY "Users can delete their own preferences" ON public.user_preferences
  FOR DELETE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- user_model_providers
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view their own provider preferences" ON public.user_model_providers;
CREATE POLICY "Users can view their own provider preferences" ON public.user_model_providers
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own provider preferences" ON public.user_model_providers;
CREATE POLICY "Users can insert their own provider preferences" ON public.user_model_providers
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own provider preferences" ON public.user_model_providers;
CREATE POLICY "Users can update their own provider preferences" ON public.user_model_providers
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete their own provider preferences" ON public.user_model_providers;
CREATE POLICY "Users can delete their own provider preferences" ON public.user_model_providers
  FOR DELETE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- subscriptions
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own subscriptions" ON public.subscriptions;
CREATE POLICY "Users can view own subscriptions" ON public.subscriptions
  FOR SELECT USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- usage_logs
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own usage logs" ON public.usage_logs;
CREATE POLICY "Users can view own usage logs" ON public.usage_logs
  FOR SELECT USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- customization_preferences
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can insert own customization preferences" ON public.customization_preferences;
CREATE POLICY "Users can insert own customization preferences" ON public.customization_preferences
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can read own customization preferences" ON public.customization_preferences;
CREATE POLICY "Users can read own customization preferences" ON public.customization_preferences
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update own customization preferences" ON public.customization_preferences;
CREATE POLICY "Users can update own customization preferences" ON public.customization_preferences
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete own customization preferences" ON public.customization_preferences;
CREATE POLICY "Users can delete own customization preferences" ON public.customization_preferences
  FOR DELETE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- projects
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view their own projects" ON public.projects;
CREATE POLICY "Users can view their own projects" ON public.projects
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can create their own projects" ON public.projects;
CREATE POLICY "Users can create their own projects" ON public.projects
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own projects" ON public.projects;
CREATE POLICY "Users can update their own projects" ON public.projects
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete their own projects" ON public.projects;
CREATE POLICY "Users can delete their own projects" ON public.projects
  FOR DELETE USING (user_id = (select auth.uid()));

------------------------------------------------------------
-- project_chats
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view project chats for their own projects" ON public.project_chats;
CREATE POLICY "Users can view project chats for their own projects" ON public.project_chats
  FOR SELECT USING (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

DROP POLICY IF EXISTS "Users can add chats to their own projects" ON public.project_chats;
CREATE POLICY "Users can add chats to their own projects" ON public.project_chats
  FOR INSERT WITH CHECK (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

DROP POLICY IF EXISTS "Users can remove chats from their own projects" ON public.project_chats;
CREATE POLICY "Users can remove chats from their own projects" ON public.project_chats
  FOR DELETE USING (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

------------------------------------------------------------
-- project_files
------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view files in their own projects" ON public.project_files;
CREATE POLICY "Users can view files in their own projects" ON public.project_files
  FOR SELECT USING (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

DROP POLICY IF EXISTS "Users can upload files to their own projects" ON public.project_files;
CREATE POLICY "Users can upload files to their own projects" ON public.project_files
  FOR INSERT WITH CHECK (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

DROP POLICY IF EXISTS "Users can delete files from their own projects" ON public.project_files;
CREATE POLICY "Users can delete files from their own projects" ON public.project_files
  FOR DELETE USING (project_id IN (SELECT id FROM public.projects WHERE user_id = (select auth.uid())));

------------------------------------------------------------
-- user_sessions
------------------------------------------------------------
DROP POLICY IF EXISTS "users_own_sessions_select" ON public.user_sessions;
CREATE POLICY "users_own_sessions_select" ON public.user_sessions
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "users_own_sessions_insert" ON public.user_sessions;
CREATE POLICY "users_own_sessions_insert" ON public.user_sessions
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "users_own_sessions_update" ON public.user_sessions;
CREATE POLICY "users_own_sessions_update" ON public.user_sessions
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "users_own_sessions_delete" ON public.user_sessions;
CREATE POLICY "users_own_sessions_delete" ON public.user_sessions
  FOR DELETE USING (user_id = (select auth.uid()));
