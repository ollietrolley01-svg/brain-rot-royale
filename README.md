# Proof for task/gunner-view-clear (PR "Task 16"). Never merge this branch.

Each image puts origin/main d1e4f73 (left) beside task/gunner-view-clear (right). All of them are from
`tools/gunner_fp_gallery.lua`, rendered in Studio edit mode by the Linux harness
(`tools/linux/studio.py gallery`, `-PlaceFile` set to each tree's own build). GunnerView is stepped by
hand with noInput, not driven from a Play client. The magenta ball is where GunnerView says the shot lands.

| File | What to look for |
|---|---|
| Rotster_fp_rest.png | Hip view at rest. Left: the receiver, sight and arms fill the middle. Right: the wall is clear, the gun sits low. |
| Rotster_fp_low.png | Hip view, barrel at its lowest (-12). Left: the breech covers the crosshair. Right: the crosshair and ball are clear. |
| Rotster_fp_ads.png | Aiming down the sight: the same on both sides (the sight marker didn't move). |
| TartarugaScout_fp_rest.png | Hip view at rest. Right: over the shield, gun at the bottom. |
| TartarugaScout_fp_low.png | Hip view at -8. Left: gun over the crosshair. Right: clear. |
| TartarugaScout_fp_ads.png | ADS unchanged. |
| CameloCarrier_fp_rest.png | Hip view at rest. Right: clear, gun at the bottom. |
| CameloCarrier_fp_low.png | Hip view at -8. Right: clear. |
| CameloCarrier_fp_ads.png | ADS unchanged. |
| CrocodiloRanger_fp_rest.png | The Ranger's eye didn't move: both sides the same. |
| SahurVan_fp_rest.png / SahurVan_fp_low.png | The mortar's eye rose 0.4: a slightly higher view over the same sight. |
