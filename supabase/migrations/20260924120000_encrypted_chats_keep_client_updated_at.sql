-- The chat payload migration (v2 -> v3) rewrites every chat once. It must not
-- move the chat in anyone's sidebar, so it sends the old updated_at plus one
-- microsecond. This trigger keeps an updated_at the client changed on purpose;
-- a normal save does not send updated_at and still gets NOW(), as before.
-- encrypted_chats only: projects and customization_preferences keep the shared
-- update_timestamp(), because their clients send updated_at on every upsert.
CREATE OR REPLACE FUNCTION public.encrypted_chats_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
    NEW.updated_at = NOW();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS encrypted_chats_updated ON public.encrypted_chats;
CREATE TRIGGER encrypted_chats_updated
  BEFORE UPDATE ON public.encrypted_chats
  FOR EACH ROW EXECUTE FUNCTION public.encrypted_chats_touch_updated_at();
