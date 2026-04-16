-- Add unique constraint on user_beats to prevent duplicate assignments
-- Required for upsert to work correctly
ALTER TABLE user_beats ADD CONSTRAINT user_beats_user_beat_unique UNIQUE (user_id, beat_id);
