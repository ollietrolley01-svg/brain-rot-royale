# task/playtime-proof-new-rule

Cut from main at fafed9c, after Oliver's "count all time in the server" (091812e).

- `tools/playtime_streak_proof.py`: the playtime half no longer tests the old activity rule, which
  crashed on the removed `MinActiveSamples`. It keeps only what `tools/playtime_check.py` does not
  cover: a player who leaves is dropped, a rejoin restarts the ladder, and the profile-not-loaded fact.
  The #77 streak half is unchanged. 8 checks, 7 plants, all caught.
- `reports/playtime-streak-proof.md`: a dated note at the top; the activity-rule sections are marked
  superseded, not deleted.
