# Branch task/prove-playtime-streak

Cut from origin/main 82968cb and fast-forwarded to ac22e5e before committing. This branch independently
checks the #76 playtime awards and the #77 daily streak prize (698efa3, as changed by a2ba3b4) against
current main. It changes no game file and no existing tool. It adds:

- `reports/playtime-streak-proof.md`: the findings. The payouts and the streak day hold. The "dead or
  spectating counts as playing" claim was reversed on purpose by a2ba3b4, and that now leaves a
  spectating, losing player mostly unpaid. `playtime_check.py`'s #77 check cannot fail. Also covers
  AFK/edge cases, #77 double claims, and the economy comparison.
- `tools/playtime_streak_proof.py`: runs the real PlaytimeService and BattlePassService.ClaimDaily in
  lupa. It has 11 checks and 8 planted faults (`--plant`). Needs `lupa`.
- `tools/playtime_economy_compare.py`: the playtime awards and the streak table next to
  `tools/economy_model.py`'s coins an hour. It uses a model, not a measurement.
