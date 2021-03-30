print("Executing KissMP modScript...")
loadJsonMaterialsFile("art/shapes/kissmp_playermodels/main.materials.json")

load("kissplayers")
registerCoreModule("kissplayers")

load("vehiclemanager")
registerCoreModule("vehiclemanager")

load("kisstransform")
registerCoreModule("kisstransform")

load("kissui")
registerCoreModule("kissui")

load("kissmods")
registerCoreModule("kissmods")

load("kissrichpresence")
registerCoreModule("kissrichpresence")

load("network")
registerCoreModule("network")

load("kissconfig")
registerCoreModule("kissconfig")

--load("kissutils")
--registerCoreModule("kissutils")
