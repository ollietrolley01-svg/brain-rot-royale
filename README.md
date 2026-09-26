# Proof for vehicle-aim

Proof-only branch for the PR from task/vehicle-aim. **Never merge it**: the repo commits no images.

- `third_person_board.gif`: Boarded from third-person combat, mouse on the blue target. BEFORE (main d1e4f73): MouseBehavior stays LockCenter in the car and the red beam from the bonnet gun goes to the yellow screen-middle dot, not the target. AFTER (this branch): Default in the car, and the beam lands on the target under the white mouse ring.
- `first_person_board.gif`: The same, boarded from first-person combat. On main Roblox's camera module restores the LockCenter it saved, so the gun still aims through the middle; on the branch the beam lands on the target.
