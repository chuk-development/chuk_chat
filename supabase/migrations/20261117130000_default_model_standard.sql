-- New accounts start in "Standard": the server picks model and providers
-- (api_server model_info/profiles.py, profiles.json in chuk_chat_model_list).
--
-- The old trigger seeded a model plus a pinned provider (kimi-k2.5 on
-- baseten in the repo file, qwen3.5-397b on together live), both retired.
-- The pinned row showed up as a "picked" model in the composer. Now only
-- selected_model_id is set, to Standard's model, and no provider is pinned.
CREATE OR REPLACE FUNCTION public.set_default_model_for_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO user_preferences (user_id, selected_model_id)
  VALUES (NEW.id, 'deepseek/deepseek-v4.1-flash-1017')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;
