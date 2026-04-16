-- Push beat default weekdays to user_beats where weekdays is NULL
-- This ensures every rep-beat assignment has explicit weekdays set
-- After this, beat-level weekdays become informational only
UPDATE user_beats ub
SET weekdays = b.weekdays
FROM beats b
WHERE ub.beat_id = b.id
  AND (ub.weekdays IS NULL OR ub.weekdays = '{}');
