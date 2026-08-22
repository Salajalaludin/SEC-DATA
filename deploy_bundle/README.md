# shinyapps.io deployment bundle

This directory is a generated deployment bundle. The generated application
files are intentionally ignored so the repository keeps one canonical copy of
the source code and data.

From the repository root:

    Rscript scripts/build_shinyapps_bundle.R

The builder creates a self-contained bundle with:

- app.R
- shared R modules
- Shiny modules and www assets
- commodity workbooks
- the four runtime cache inputs used by the dashboard

The hosted bundle is cache-only: local ERA5 NetCDF files and the native
`terra`/GDAL updater dependency are intentionally excluded. ERA5 cache rebuilds
continue to run locally through `cilegon_komoditas_shiny/update_era5_daily.R`.

Upload requires credentials supplied through the environment. Never place
tokens, secrets, .Renviron, or .cdsapirc in this directory or in Git.

PowerShell placeholder:

    $env:SHINYAPPS_NAME = "<account>"
    $env:SHINYAPPS_TOKEN = "<token>"
    $env:SHINYAPPS_SECRET = "<secret>"
    $env:SHINYAPPS_APP_NAME = "sec-data-cilegon"
    Rscript scripts/deploy_shinyapps_placeholder.R

The upload script builds the bundle first and then calls
rsconnect::deployApp(). Cache refreshes and deployment are separate
operations; redeploy after a cache refresh if the hosted app should receive
the new static cache files.
