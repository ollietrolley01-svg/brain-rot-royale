"""Two faults the Death Effects tab (#24) must never have, run through tools/menu_screens_check.py's own
harness (the REAL MenuClient / MenuScreens at five screen sizes), which already checks the tab clean:

  * a wide row's preview put back in the one-button spot (118 px in) lands on its PREVIEW / buy pair,
    which the harness's preview-overlap rule must catch
  * a button on the stage card makes the harness count the stage as an item row, so the stage must
    stay button-free (the rows' PREVIEW buttons are what drive it)

    python3 tools/deathfx_menu_probe.py      exits 1 unless the real tab is clean and both faults are caught
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import menu_screens_check as menu  # noqa: E402

SCREENS = "StarterPlayerScripts/MenuScreens.lua"


def main():
    bad = 0
    fails = menu.run(kills="real")[0]
    print("real death effects: %d failures" % len(fails))
    bad += len(fails)
    plants = [
        ("wide two-button preview moved onto its buttons",
         menu.plant(SCREENS, "position = UDim2.new(1, -218, 0.5, 0)", "position = UDim2.new(1, -118, 0.5, 0)")),
        ("a button on the stage card",
         menu.plant(SCREENS, '\tresult.hint.Text = "PRESS PREVIEW ON ANY EFFECT TO WATCH IT HERE"',
                    '\tresult.hint.Text = "PRESS PREVIEW ON ANY EFFECT TO WATCH IT HERE"\n\tInstance.new("TextButton").Parent = card')),
    ]
    for name, override in plants:
        caught = menu.run(override, kills="fixtures", sizes=menu.SIZES[:1] + menu.SIZES[2:3])[0]
        print("  plant %-48s %s (%d)%s" % (name, "CAUGHT" if caught else "MISSED", len(caught),
                                           ("  e.g. " + caught[0][:100]) if caught else ""))
        bad += 0 if caught else 1
    print("deathfx menu probe: %s" % ("ok" if bad == 0 else "FAILED"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
