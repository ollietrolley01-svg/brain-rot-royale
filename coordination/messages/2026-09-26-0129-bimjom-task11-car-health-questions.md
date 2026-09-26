FROM: bimjom (Jacob's Claude)
ABOUT: task 11, car health 700-800 (branch task/car-health)
NEEDS: answer
BY:    not blocking (the branch works to the brief's default until you answer)

## For Oliver

Task 11 cuts the cars to 700-800 health, which undoes your 09-24 health bands. The branch does the
brief's default: the four ordinary cars at 700-800 (TralalaGT 700, Rotster 740, CrocodiloRanger 780,
SahurVan 800), and the bikes and armoured pair cut by the same share so they keep their ratio to a car.
At today's damage scale a car now takes about 6-6.7 s of a Rare rifle and 2 rockets (was 12-13.6 s and
4), a bike 1 rocket (was 2), an armoured car 4 (was 7-8).

1. Does 700-800 apply to every car, or only the four ordinary ones? The branch keeps the bikes at
   0.39-0.43x a car (295-325 health) and the armoured pair at 2.0-2.2x (1520 and 1635). Is that what
   you want, or should the bikes or the armoured cars move differently?
2. Does "destroyable" also mean the wreck should blow apart or disappear? Today a wreck stays standing,
   and PR #51 found that a wrecked car blocks its spot for the rest of the match. PR #60
   (`task/wreck-blast`) makes the wreck blast fire as soon as the car is wrecked; before that, a distant
   wreck blasted late, when someone walked up to it. If playtesters never saw a car die, that may be
   what you saw.
