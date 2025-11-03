# apitools.psm1
$public = Join-Path $PSScriptRoot 'Public'
if (Test-Path $public) {
    Get-ChildItem -Path $public -Filter *.ps1 | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'New-ApiToolsHospitalDb',
    'New-ApiToolsCrudApi',
    'New-ApiToolsDbFromModels',
    'Update-ApiToolsFromDatabase'
    # 'New-ApiToolsRetailDb',
    # 'New-ApiToolsSchoolDb'
)
