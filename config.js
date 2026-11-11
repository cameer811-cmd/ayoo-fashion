
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://jfmhbmcrcbatoregunmk.supabase.co';

const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_OTT_w1yFksyXThP7j0KmhA_mHYiMyUi';

export const supabase = createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);

window.ayooSupabase = supabase;
