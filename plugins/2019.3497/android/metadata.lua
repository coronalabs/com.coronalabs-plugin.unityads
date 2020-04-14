local metadata =
{
    plugin =
    {
        format = 'jar',
        manifest = 
        {
            permissions = {},
            usesPermissions =
            {
            },
            usesFeatures = 
            {
            },
            applicationChildElements =
            {
            }
        }
    },
    coronaManifest = {
        dependencies = {
            ["shared.android.support.v7.appcompat"] = "com.coronalabs"
        }
    }
}

return metadata
