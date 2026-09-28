# Phone HUD audit and polish (2026-09-28)

Oliver: "the mobile hud needs a full polish, it's too cluttered and unusable on phone". This is the audit
of every HUD element and touch button a phone can show, state by state, then what changed.

## How it was measured

- **HUD panels**: `python tools/hud_layout_check.py . --dump`. It runs the real HudClient, BoonHud,
  VehicleClient, VehicleWeaponClient, ModeScoreHud and GunfireCueClient with the real PhoneLayout in its
  mocked client. The check now covers 667x375 and 932x430 as well as 844x390, and the lobby, spectating,
  passenger and bike states alongside battle royale, team match, driving and gunner.
- **Touch buttons, before**: the positions the scripts gave ContextActionService (CAS).
  `SetPosition(UDim2.new(1, -x, 1, -y))` on CAS's frame (bottom-right at the screen's bottom-right) lands
  at (W-x, H-y). Each button is 45 px (Roblox's ContextActionTouch: 45, or 35 when the screen is 320 tall
  or less). CAS draws **at most 7**, and only unbinding frees a slot.
- **Touch buttons, after**: `PhoneLayout.TouchButtons`, which is what `Settings` and the seats' scripts
  apply (checked by `tools/touch_seat_check.py`, S5).
- **Roblox's own controls** (PhoneLayout): the thumbstick's zone covers the left 40% below H/3, the jump
  button is 70 px at (W-95, H-90), and the top bar is 200x52. At 844x390 the crosshair sits at 409,182 (26 px).
- **Not in the mock**:
  - Parachuting / drop-in is the in-match HUD. You steer by looking, so it is the battle royale row.
  - The emplacement gunner's panel is MountedGunClient's; see "gunner" below.
  - The spectate plate and its NEXT / LEAVE buttons are CombatClient literals; the gallery and the check
    copy them.

Rects are `x,y wxh` in screen pixels. "-" means not drawn. Renders of every state (before and after,
matching names) are in the session scratchpad under `phonehud/before` and `phonehud/after`
(`tools/phone_hud_gallery.lua`).

### battle royale

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| crosshair | 409,182 26x26 | 320,174 26x26 | 409,182 26x26 | 320,174 26x26 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| stamina bar | 350,210 132x18 | 271,214 100x14 | 363,223 111x15 | 273,216 95x13 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | 359,254 208x131 | 270,246 192x124 |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| companion buffs panel | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 |
| button FIRE | 704,210 45x45 | 527,195 45x45 | 669,298 72x72 | 492,283 72x72 |
| button AIM | 594,210 45x45 | 417,195 45x45 | 681,242 48x48 | 504,227 48x48 |
| button RUN | 594,110 45x45 | 417,95 45x45 | 681,186 48x48 | 504,171 48x48 |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | 760,242 48x48 | 583,227 48x48 |
| button PET | 484,210 45x45 | 307,195 45x45 | 760,186 48x48 | 583,171 48x48 |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | 681,130 48x48 | 504,115 48x48 |
| button MOVE | 374,110 45x45 | 197,95 45x45 | 760,130 48x48 | 583,115 48x48 |

### team match

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| crosshair | 409,182 26x26 | 320,174 26x26 | 409,182 26x26 | 320,174 26x26 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| stamina bar | 350,210 132x18 | 271,214 100x14 | 363,223 111x15 | 273,216 95x13 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | 359,254 208x131 | 270,246 192x124 |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| mode scoreline | 257,4 330x35 | 208,4 291x30 | 257,4 330x35 | 208,4 291x30 |
| companion buffs panel | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 |
| button FIRE | 704,210 45x45 | 527,195 45x45 | 669,298 72x72 | 492,283 72x72 |
| button AIM | 594,210 45x45 | 417,195 45x45 | 681,242 48x48 | 504,227 48x48 |
| button RUN | 594,110 45x45 | 417,95 45x45 | 681,186 48x48 | 504,171 48x48 |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | 760,242 48x48 | 583,227 48x48 |
| button PET | 484,210 45x45 | 307,195 45x45 | 760,186 48x48 | 583,171 48x48 |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | 681,130 48x48 | 504,115 48x48 |
| button MOVE | 374,110 45x45 | 197,95 45x45 | 760,130 48x48 | 583,115 48x48 |

### lobby

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| stamina bar | 350,210 132x18 | 271,214 100x14 | 363,223 111x15 | 273,216 95x13 |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| READY pill | 667,86 172x45 | 315,86 172x45 | 667,66 172x45 | 490,66 171x44 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| companion buffs panel | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 |
| button FIRE | 704,210 45x45 | 527,195 45x45 | - | - |
| button AIM | 594,210 45x45 | 417,195 45x45 | - | - |
| button RUN | 594,110 45x45 | 417,95 45x45 | 681,186 48x48 | 504,171 48x48 |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | - | - |
| button PET | 484,210 45x45 | 307,195 45x45 | 760,186 48x48 | 583,171 48x48 |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |

### spectate

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| stamina bar | 350,210 132x18 | 271,214 100x14 | 363,223 111x15 | 273,216 95x13 |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| READY pill | 667,86 172x45 | 315,86 172x45 | 667,66 172x45 | 490,66 170x44 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| companion buffs panel | 78,196 152x72 | 78,196 152x72 | - | - |
| button FIRE | 704,210 45x45 | 527,195 45x45 | - | - |
| button AIM | 594,210 45x45 | 417,195 45x45 | - | - |
| button RUN | 594,110 45x45 | 417,95 45x45 | - | - |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | - | - |
| button PET | 484,210 45x45 | 307,195 45x45 | - | - |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |

### driving

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | - | - |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| vehicle-gun ammo panel | 246,211 98x51 | 196,207 69x36 | 254,212 102x53 | 198,207 70x36 |
| vehicle-gun reticle | 418,191 8x8 | 330,184 8x8 | 418,191 8x8 | 330,184 8x8 |
| driving speed panel | 78,211 163x51 | 78,207 114x36 | 78,212 171x53 | 78,207 116x36 |
| driving hint | 78,265 170x9 | 78,246 120x6 | - | - |
| button FIRE | 704,210 45x45 | 527,195 45x45 | - | - |
| button AIM | 594,210 45x45 | 417,195 45x45 | - | - |
| button RUN | 594,110 45x45 | 417,95 45x45 | - | - |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | - | - |
| button PET | 484,210 45x45 | 307,195 45x45 | - | - |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |
| button BRAKE (NOT DRAWN: over the cap) | 664,240 45x45 | 487,225 45x45 | - | - |
| button gun FIRE (NOT DRAWN: over the cap) | 704,210 45x45 | 527,195 45x45 | - | - |
| button FIRE (seat's) | - | - | 669,298 72x72 | 492,283 72x72 |
| button BRAKE | - | - | 681,242 48x48 | 504,227 48x48 |
| button LEAVE | - | - | 760,130 48x48 | 583,115 48x48 |

### gunner

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | - | - |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| vehicle-gun ammo panel | 246,211 98x51 | 196,207 69x36 | 254,212 102x53 | 198,207 70x36 |
| gunner sight | 412,185 20x20 | 324,178 20x20 | 412,185 20x20 | 324,178 20x20 |
| button FIRE | 704,210 45x45 | 527,195 45x45 | - | - |
| button AIM | 594,210 45x45 | 417,195 45x45 | - | - |
| button RUN | 594,110 45x45 | 417,95 45x45 | - | - |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | - | - |
| button PET | 484,210 45x45 | 307,195 45x45 | - | - |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |
| button FIRE (NOT DRAWN: over the cap) | 754,110 45x45 | 577,95 45x45 | - | - |
| button AIM (NOT DRAWN: over the cap) | 674,110 45x45 | 497,95 45x45 | - | - |
| button RELOAD (NOT DRAWN: over the cap) | 594,110 45x45 | 417,95 45x45 | - | - |
| button LEAVE (NOT DRAWN: over the cap) | 514,110 45x45 | 337,95 45x45 | - | - |
| button FIRE (seat's) | - | - | 669,298 72x72 | 492,283 72x72 |
| button AIM (seat's) | - | - | 681,242 48x48 | 504,227 48x48 |
| button RELOAD (seat's) | - | - | 760,242 48x48 | 583,227 48x48 |
| button LEAVE | - | - | 760,130 48x48 | 583,115 48x48 |

### passenger

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| crosshair | 409,182 26x26 | 320,174 26x26 | 409,182 26x26 | 320,174 26x26 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| stamina bar | 350,210 132x18 | 271,214 100x14 | 363,223 111x15 | 273,216 95x13 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | 359,254 208x131 | 270,246 192x124 |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| companion buffs panel | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 | 78,196 152x72 |
| button FIRE | 704,210 45x45 | 527,195 45x45 | 669,298 72x72 | 492,283 72x72 |
| button AIM | 594,210 45x45 | 417,195 45x45 | 681,242 48x48 | 504,227 48x48 |
| button RUN | 594,110 45x45 | 417,95 45x45 | - | - |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | 760,242 48x48 | 583,227 48x48 |
| button PET | 484,210 45x45 | 307,195 45x45 | - | - |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |
| button LEAVE | - | - | 760,130 48x48 | 583,115 48x48 |

### bike

| element | 844x390 before | 667x375 before | 844x390 after | 667x375 after |
|---|---|---|---|---|
| banner | 257,4 330x42 | 208,4 291x37 | 257,4 330x42 | 208,4 291x37 |
| crosshair | 409,182 26x26 | 320,174 26x26 | 409,182 26x26 | 320,174 26x26 |
| health row | 350,230 177x30 | 271,239 140x24 | 363,247 151x26 | 273,243 135x23 |
| companion strip | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 | 142,158 160x30 |
| effects pill | 493,204 84x16 | 377,208 84x16 | 480,217 84x16 | 374,210 84x16 |
| hotbar (8 cells + INV) | 346,243 236x143 | 267,244 197x127 | 359,254 208x131 | 270,246 192x124 |
| minimap | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 | 16,58 96x96 |
| bounty line | 461,152 200x19 | 310,152 174x17 | 461,132 200x19 | 310,132 174x17 |
| compass | 257,64 330x18 | 208,64 291x16 | - | - |
| kill feed | 484,86 200x35 | 132,86 200x35 | 461,66 200x35 | 284,66 200x35 |
| toast | 279,126 285x22 | 191,126 285x22 | 279,106 285x22 | 191,106 285x22 |
| pet tile (ability icon) | 16,233 56x56 | 16,218 56x56 | 16,233 56x56 | 16,218 56x56 |
| driving speed panel | 78,211 163x51 | 78,207 114x36 | 78,212 171x53 | 78,207 116x36 |
| driving hint | 78,265 170x9 | 78,246 120x6 | - | - |
| button FIRE | 704,210 45x45 | 527,195 45x45 | 669,298 72x72 | 492,283 72x72 |
| button AIM | 594,210 45x45 | 417,195 45x45 | 681,242 48x48 | 504,227 48x48 |
| button RUN | 594,110 45x45 | 417,95 45x45 | - | - |
| button RELOAD | 704,110 45x45 | 527,95 45x45 | 760,242 48x48 | 583,227 48x48 |
| button PET | 484,210 45x45 | 307,195 45x45 | - | - |
| button CROUCH | 484,110 45x45 | 307,95 45x45 | - | - |
| button MOVE | 374,110 45x45 | 197,95 45x45 | - | - |
| button BRAKE (NOT DRAWN: over the cap) | 664,240 45x45 | 487,225 45x45 | - | - |
| button BRAKE | - | - | 681,186 48x48 | 504,171 48x48 |
| button LEAVE | - | - | 760,130 48x48 | 583,115 48x48 |

**Upright (390x844)**: the buttons were at the landscape literals, so MOVE was at x=-80, off the screen.
CROUCH, PET, AIM and RUN were in the thumbstick's zone: the before renders count 4 in Roblox's zones.
After, the buttons sit in the portrait cluster, bottom right. The hotbar row's box had been 134 tall for
one row of cells, and now matches it.

**Emplacement gunner** (MountedGunClient, not in the mock): the 240x46 gauge panel sat top-middle at
y≈44, across the banner's lower edge and the storm line. It now goes in `Rects().gunnerPanel`, at the
foot of the bottom band. A gunner has no hotbar there. Upright, it goes under the crosshair, left of the
buttons.

## What was cluttered / unusable (before)

Unusable:
1. **A phone gunner could not fire.** The 7 on-foot CAS buttons (FIRE AIM RUN RELOAD PET CROUCH MOVE)
   stayed bound all session and filled the cap. The gunner's FIRE, AIM, RELOAD and LEAVE got no button,
   and neither did the driver's BRAKE and gun, the bike's BRAKE or COOK. The renders show them as red
   "NO ..." chips.
2. **The buttons were not where the layout thought.** PhoneLayout lays the HUD out around a right-thumb
   cluster, but CAS drew the buttons at older literals:
   - At 844x390: MOVE at 374,110, 30 px above the crosshair and across the toast; PET across the health
     row, the effects pill and the hotbar's top; RUN and CROUCH across the kill feed and the bounty line.
     The before render counts 10 overlapping pairs.
   - At 667x375: MOVE sat in the thumbstick's zone.
3. **Useless buttons.** A driver kept FIRE, AIM, RUN and the rest, and a spectator and the lobby kept all
   seven, none of which does anything there.

Cluttered:
4. **A third strip at the top**: the 330x18 compass under the banner and storm line. The minimap already
   shows the bearing.
5. **A fourth line of text** in the right column (the location line, under the bounty line). The town is
   announced mid-screen on entry.
6. **The bottom stack crowded the crosshair.** At 844x390 the stamina bar and effects pill started 4 px
   under the crosshair's box, because the hotbar cells grew to fill the band.
7. **Driver and gunner still had the full 2x4 hotbar**, the biggest thing on screen, and none of it
   usable from a seat.
8. **The driving hint** ("JUMP get out BRAKE handbrake") was scaled to 6-9 px text.
9. **The lobby's READY pill** overlapped the kill feed box by 17 px on all three landscape phones. The
   check had not had a lobby to find it.
10. **A spectator on a 667x375 phone** had the companion-buffs panel under the NEXT button.

## What changed (after)

- **PhoneLayout** (`StarterPlayerScripts/PhoneLayout.lua`), "THE TOUCH BUTTONS, BY WHAT THE PLAYER IS DOING":
  - `TouchSets` / `TouchContexts` / `TouchSet` decide which buttons each state has:
    - on foot, 7;
    - with a coconut, COOK replaces RELOAD;
    - driver: FIRE (the car's), BRAKE, LEAVE;
    - gunner: FIRE, AIM, RELOAD, LEAVE (the mount's);
    - passenger or pillion: FIRE, AIM, RELOAD, LEAVE;
    - bike rider: FIRE, AIM, RELOAD, BRAKE, LEAVE;
    - lobby: RUN, PET;
    - range: FIRE, AIM, RELOAD, RUN, PET;
    - spectator: none.
  - `PlaceTouchButton` puts each CAS button on its cluster square at the square's size (FIRE 72, the
    rest 48).
  - `SeatOf` names the seat.
  - `SeatHidesHotbar` covers driver and gunner.
  - A phone on its side drops the compass, the location line and the driving hint.
  - Hotbar cells stop at the finger minimum + 4.
  - The kill feed clears the READY pill.
  - `gunnerPanel` is new.
  - Upright tablets use Roblox's big jump button.
- **Settings** (`StarterPlayerScripts/Settings.lua`):
  - `BindFixed` is new (FIRE and AIM moved here from raw CAS).
  - `BindSeat` / `UnbindSeat` / `RefreshTouch` / `SetTouchFlag` take the on-foot buttons away before a
    seat's buttons are bound, and give them back only once the seat's are gone. They listen to the seat
    and the match remotes. If a seat's script never lets go, they wait at most 2 s.
  - LEAVE is a touch-only action for drivers, riders and passengers.
  - Laptops with touch keep the old behaviour.
- **Seat scripts**: VehicleClient (BRAKE), VehicleWeaponClient (FIRE / AIM), MountedGunClient
  (RELOAD / LEAVE, and the gauge panel's slot) and ProjectileClient (COOK) now bind through
  `Settings.BindSeat`.
- **HudClient**: the hotbar goes through `hudLayout.show` and steps out in driver and gunner seats on a
  touch screen. The phone hotbar row's box matches its rows.
- **BoonHud**: hides on a touch screen when there is no living body (spectating).
- **VehicleClient**: hides the hint when PhoneLayout has no room for it.

Desktop and console: `hud_layout_check --dump` shows the same rects at 1920x1080 and 1366x768 in every
scenario. The only difference is the spectate scene, which in the mock now has no body, as in the game.
No touch code runs without a touch screen or with a keyboard (Studio excepted).

## Checks

- `tools/touch_seat_check.py` is new. It covers:
  - S1 needed buttons per state;
  - S2 never more than 7, through a 51-step walk of every seat change in both signal orders;
  - S3 finger size;
  - S4 Roblox's zones, the crosshair, off-screen and pairs;
  - S5 each button on its square;
  - S6 no raw CAS binds of these actions;
  - S7 the gunner panel.
  All of it runs the real Settings and PhoneLayout. 12/12 plants are caught.
- `tools/hud_layout_check.py` now covers:
  - 667x375 and 932x430;
  - the lobby, spectate, passenger and bike states;
  - the touch buttons and the jump button as elements;
  - seat hotbar assertions;
  - the phone's dropped pieces;
  - `--gallery`.
  4 new plants.
- `tools/device_compat_check.py` understands `BindFixed` / `BindSeat`. `KNOWN_OVER_CAP` is now empty,
  and there is a new plant for BRAKE bound past the cap.
- `tools/mounted_guns_check.py` reads the `BindSeat` calls.

## Still open / only a device can say

- That CAS honours `SetPosition` and `GetButton().Size` on a real phone. The sizes are set once the
  CoreScript has made the button, retried for 2 s. Whether a rebind keeps the new size also needs a device.
- That the 8th-button bug never shows. The sim (`touch_seat_check`) peaks at 7 through every seat change,
  in both signal orders. Real replication timing needs a Play test on the emulator and on a phone.
- The spectate plate and its NEXT / LEAVE (CombatClient) sit in the thumbstick's zone and under where
  the jump button would be. This is fine only if Roblox hides both with no body, which is unverified.
- The companion strip, pet tile and buffs panel still share the left column. The owner asked for the
  strip to be kept. A tap-to-expand for buffs was not built.
