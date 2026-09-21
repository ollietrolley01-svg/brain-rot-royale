-- Curated Creator Store candidates for the established meme characters in BrainrotData.
--
-- REVIEW DATA ONLY.  Production does not require this module and it never calls LoadAsset.
-- These were searched in Roblox's live Creator Store index and visually checked from Roblox's
-- own 420px model thumbnails on 2026-09-19.  Import into a separate review folder first.  For
-- entries marked containsScripts, delete every LuaSourceContainer while the returned asset is
-- still unparented; never run free-model code.
--
-- The rest of BrainrotData is original to Brain Rot Royale, so an existing model cannot be an
-- authoritative match for those names.  They need original art rather than unrelated free models.

return {
	["Tung Tung Tung Sahur"] = {
		assetId = 138151705692565,
		creator = "ATMnou",
		containsScripts = false,
		quality = "high-detail single-mesh original look: wood humanoid, human feet, bat",
	},
	["Golden Sahur"] = {
		-- Use the Tung mesh above with a gold material/texture variant; there is no separate canonical
		-- Golden Sahur design worth importing.
		assetId = 138151705692565,
		creator = "ATMnou",
		containsScripts = false,
		variant = "gold",
		quality = "recolour of the high-detail Tung mesh",
	},
	["Bombardiro Crocodilo"] = {
		assetId = 91327024837680,
		creator = "F0g_02",
		containsScripts = true,
		quality = "high-detail crocodile head integrated into a bomber aircraft",
	},
	["Tralalero Tralala"] = {
		assetId = 129482668414941,
		creator = "F0g_02",
		containsScripts = true,
		quality = "realistic shark body with blue sneakers; strongest detailed Store option",
	},
	["Chimpanzini Bananini"] = {
		assetId = 83732984780551,
		creator = "xXH3nry_AltXx",
		containsScripts = false,
		quality = "high-detail green chimp emerging from a peeled banana",
	},
	["Boneca Ambalabu"] = {
		assetId = 125906339004688,
		creator = "Haxcyc_LDC",
		containsScripts = false,
		quality = "high-detail frog head, tire torso, frog/human legs",
	},
	["Lirili Larila"] = {
		assetId = 77231614368559,
		creator = "giacomorixYT",
		containsScripts = false,
		quality = "high-detail cactus elephant with oversized sandals",
	},
	["Ballerina Cappuccina"] = {
		assetId = 75983792852042,
		creator = "hexsunez251",
		containsScripts = true,
		quality = "recognizable cup-headed ballerina, but blockier than the other selected assets",
		caveat = "candidate only; should be replaced if a higher-detail licensed model is found",
	},
	["Brr Brr Patapim"] = {
		assetId = 100538198930997,
		creator = "Haxcyc_LDC",
		containsScripts = false,
		quality = "high-detail forest creature with bark, foliage and oversized human feet",
	},
	["Frigo Camelo"] = {
		assetId = 136392638607318,
		creator = "Thaiskiy",
		containsScripts = false,
		quality = "high-detail camel head and legs fused with a refrigerator body",
	},
	["Bombombini Gusini"] = {
		assetId = 76661728011648,
		creator = "Luciano_Lol97",
		containsScripts = false,
		quality = "detailed white goose aircraft with multiple jet engines",
	},
	["La Vacca Saturno Saturnita"] = {
		assetId = 79911767286448,
		creator = "hexsunez251",
		containsScripts = true,
		quality = "cow head, Saturn body/rings and human feet with a blue cosmic aura",
		caveat = "recognizable but stylized/blocky; candidate only",
	},
}
