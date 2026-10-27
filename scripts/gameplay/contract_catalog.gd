class_name ContractCatalog
extends RefCounted
## Client templates the ContractManager draws contracts from. Ranges are
## [min, max]; fees are dollars, storage_fee is per pallet per contract day.

const TEMPLATES: Array[Dictionary] = [
	{"company": "Nordic Build", "prefix": "NB", "cargo": "Construction materials", "pack": "Pallets (Euro)", "tons_per_pallet": 1.7, "pallets": [6, 10], "days": [2, 3], "handling_per_pallet": 95, "storage_fee": 22, "tag": "Standard", "logo": "res://ui/icons/logo_layers.svg", "color": Color(0.85, 0.42, 0.18), "desc": "Delivery of building materials for a local construction project. Customer requires indoor storage and easy truck access."},
	{"company": "GreenFields", "prefix": "GF", "cargo": "Agricultural goods", "pack": "Pallets (Mixed)", "tons_per_pallet": 1.4, "pallets": [6, 10], "days": [2, 3], "handling_per_pallet": 85, "storage_fee": 18, "tag": "Standard", "logo": "res://ui/icons/logo_leaf.svg", "color": Color(0.36, 0.72, 0.30), "desc": "Seasonal produce and seed stock. Keep dry, standard rotation."},
	{"company": "ElectroLogix", "prefix": "EL", "cargo": "Electronics", "pack": "Pallets (Fragile)", "tons_per_pallet": 0.75, "pallets": [4, 8], "days": [1, 2], "handling_per_pallet": 160, "storage_fee": 35, "tag": "Priority", "logo": "res://ui/icons/logo_e.svg", "color": Color(0.30, 0.55, 0.95), "desc": "High value consumer electronics. Handle with care, no stacking."},
	{"company": "HomeStyle", "prefix": "HS", "cargo": "Furniture", "pack": "Pallets (Mixed)", "tons_per_pallet": 1.4, "pallets": [8, 10], "days": [3, 4], "handling_per_pallet": 90, "storage_fee": 20, "tag": "Standard", "logo": "res://ui/icons/logo_house.svg", "color": Color(0.62, 0.42, 0.85), "desc": "Flat-packed furniture for regional retail stores."},
	{"company": "AutoParts Co.", "prefix": "AP", "cargo": "Auto parts", "pack": "Pallets (Mixed)", "tons_per_pallet": 1.5, "pallets": [6, 10], "days": [2, 3], "handling_per_pallet": 100, "storage_fee": 24, "tag": "Standard", "logo": "res://ui/icons/logo_gear.svg", "color": Color(0.55, 0.58, 0.62), "desc": "Spare parts for workshops. Mixed pallet sizes."},
	{"company": "FreshFoods", "prefix": "FF", "cargo": "Food (Non-perishable)", "pack": "Pallets (Euro)", "tons_per_pallet": 1.4, "pallets": [6, 10], "days": [2, 4], "handling_per_pallet": 80, "storage_fee": 19, "tag": "Standard", "logo": "res://ui/icons/logo_leaf.svg", "color": Color(0.95, 0.78, 0.25), "desc": "Canned and dry goods for grocery distribution."},
	{"company": "Global Trade", "prefix": "GT", "cargo": "General cargo", "pack": "Pallets (Mixed)", "tons_per_pallet": 1.4, "pallets": [6, 10], "days": [2, 3], "handling_per_pallet": 85, "storage_fee": 20, "tag": "Standard", "logo": "res://ui/icons/logo_globe.svg", "color": Color(0.25, 0.75, 0.75), "desc": "Mixed import cargo awaiting onward transport."},
	{"company": "QuickShip", "prefix": "QS", "cargo": "Express goods", "pack": "Pallets (Mixed)", "tons_per_pallet": 1.3, "pallets": [3, 6], "days": [1, 1], "handling_per_pallet": 150, "storage_fee": 30, "tag": "Urgent", "logo": "res://ui/icons/logo_swirl.svg", "color": Color(0.92, 0.30, 0.35), "desc": "Time-critical parcels. Cross-dock within the day."},
	{"company": "LogiTrans", "prefix": "LT", "cargo": "General cargo", "pack": "Pallets (Euro)", "tons_per_pallet": 1.4, "pallets": [6, 10], "days": [2, 3], "handling_per_pallet": 85, "storage_fee": 20, "tag": "Standard", "logo": "res://ui/icons/logo_globe.svg", "color": Color(0.95, 0.55, 0.20), "desc": "Regular line-haul customer. Standard handling and storage."},
]


static func find(company: String) -> Dictionary:
	for t: Dictionary in TEMPLATES:
		if t.company == company:
			return t
	return {}
