-- Add per-user weekday schedule to user_beats
-- When set, overrides the beat's default weekdays for this specific user
ALTER TABLE public.user_beats ADD COLUMN IF NOT EXISTS weekdays TEXT[] DEFAULT '{}';
