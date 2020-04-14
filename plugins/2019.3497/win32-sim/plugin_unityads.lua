-- UnityAds plugin

local Library = require "CoronaLibrary"

-- Create library
local lib = Library:new{ name="plugin.unityads", publisherId="com.coronalabs", version=1 }

-------------------------------------------------------------------------------
-- BEGIN
-------------------------------------------------------------------------------

-- This sample implements the following Lua:
-- 
--    local unityads = require "plugin.unityads"
--    unityads.init()
--    

local function showWarning(functionName)
    print( functionName .. " WARNING: The UnityAds plugin is only supported on Android & iOS devices. Please build for device")
end

function lib.init()
    showWarning("unityads.init()")
end

function lib.isLoaded()
    showWarning("unityads.isLoaded()")
end

function lib.show()
    showWarning("unityads.show()")
end

-------------------------------------------------------------------------------
-- END
-------------------------------------------------------------------------------

-- Return an instance
return lib
