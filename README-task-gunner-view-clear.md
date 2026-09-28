# task/gunner-view-clear

Cut from `origin/main` at d1e4f73. Task 16: the gunner's own gun no longer blocks the hip view (Jacob,
playtest 2026-09-25: "the gunners gun obscures your view when not in ads").

## What changed from d1e4f73

- `ReplicatedStorage/Shared/VehicleModels.lua`: the `GunnerEye` marker (where GunnerView's hip camera
  sits) moves up on four turrets. Rotster +1.2, TartarugaScout +1.2, CameloCarrier +1.0, SahurVan +0.4.
  Each keeps its old height as `SeatEye`, which `GunnerSeatFor` already prefers, so every gunner seat is
  exactly where it was. The CrocodiloRanger is unchanged. The ADS sight (`GunnerSight`) is unchanged. The
  header comment on the markers says what the eye's height is held to.
- `tools/gunner_hip_view_check.py` (new): builds every armed vehicle with the real VehicleModels under
  lupa, places the hip camera as GunnerView does, and sweeps the whole pitch arc. H1: the crosshair
  neighbourhood is clear of the turret's own parts. H2: the line to the aim point is clear. H3: the grips
  stay within the viewmodel arms' reach. It has three planted faults.
- `tools/gunner_fp_gallery.lua`: adds a `<Model>_fp_low` view (hip, barrel at its lowest pitch), where
  the old eye was worst.

## Cause

The hip eye sat 1.1–1.6 studs above the gun's trunnion and just behind the receiver, looking along the
barrel. It was almost the sight line. At level pitch the receiver, top cover and reflex sight covered
59–75 of the 77 crosshair rays. With the barrel down, the breech rose into the view and covered all 77,
and the line to the aim point itself ran through the receiver.
