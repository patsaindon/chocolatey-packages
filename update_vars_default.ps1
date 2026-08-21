# AU Packages Template: https://github.com/majkinetor/au-packages-template
# Copy this file to update_vars.ps1 and set the variables there. Do not include it in the repository.
#
# This is for a LOCAL, interactive run of update_all.ps1/test_all.ps1 by a
# developer only. CI (.github/workflows/update-internal-packages.yml) never
# reads update_vars.ps1 — it gets the staging feed URL/API key directly from
# GitHub Secrets. See internal/README.md.

$Env:mail_user        = ''
$Env:mail_pass        = ''
$Env:mail_server      = 'smtp.gmail.com'
$Env:mail_port        = '587'
$Env:mail_enablessl   = 'true'

$Env:api_key          = ''          #Chocolatey api key
$Env:gist_id          = ''          #Specify your gist id or leave empty for anonymous gist
$Env:gist_id_test     = ''          #Specify your gist id for test runs or leave empty for anonymous gist
$Env:github_user_repo = ''          #{github_user}/{repo}
$Env:github_api_key   = ''          #Github personal access token
$Env:au_Push          = 'false'     #Push to chocolatey
