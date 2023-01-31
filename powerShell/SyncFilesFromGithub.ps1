$ADO_metaData_url = $env:ADO_METADATA_URL
$GitHubPat = $env:GITHUB_TOKEN

$devOpsUrlMatchRegExp1 = "https://dev.azure.com/([^\\]*)/([^\\]*)/_git/([^\\]*)"
$devOpsUrlMatchRegExp2 = "https://([^.]*).visualstudio.com/([^\\]*)/_git/([^\\]*)"

$GithubConfig = @{
    owner = "Azure"
    repo  = "azure-rest-api-specs"
    path  = "/specification/common-types"
}

function Get-GitHubApiHeaders ($token) {
    $headers = @{ Authorization = "bearer $token" }
    return $headers
}

function Get-GitHubMetaData {
    param (
        [Parameter(Mandatory = $true)]
        $uri,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )

    try {
        return Invoke-WebRequest `
            -Method GET `
            -Headers (Get-GitHubApiHeaders -token $AuthToken) `
            -Uri $uri `
        | ConvertFrom-Json
    }
    catch {
        write-error "Get-GitHubMetaData failed with exception:`n$_"
        exit 1
    }
}

function Clone-GitHubRepo($owner, $repo, $local_dir) {
    git clone --single-branch "https://${owner}:$($GitHubPat)@github.com/$owner/$repo.git" $local_dir
}

function Checkout-Branch($branch, $from) {
    $b = $(git branch --list $branch)
    if ($b) {
        git checkout $branch | Out-Null
    }
    else {
        git checkout -b $branch $from | Out-Null
    }
}

function Get-ADOHeaders ($token) {
    $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
    $headers = @{ Authorization = "Basic $token" }
    return $headers
}

function Get-ADOMetaData {
    param (
        [Parameter(Mandatory = $true)]
        $url
    )

    if ($url.IndexOf('?') -ge 0) {
        # get the part of the url after the question mark to get the query string
        $query = ($url -split '\?')[1]    
        # or use: $query = $url.Substring($url.IndexOf('?') + 1)
    
        # remove possible fragment part of the query string
        $query = $query.Split('#')[0]
    
        # detect variable names and their values in the query string
        foreach ($q in ($query -split '&')) {
            $kv = $($q + '=') -split '='
            $varName  = [uri]::UnescapeDataString($kv[0]).Trim()
            $varValue = [uri]::UnescapeDataString($kv[1])
            New-Variable -Name $varname -Value $varValue -Force
        }

        $url_prefix = ($url -split '\?')[0]  
        if ($url_prefix -match $devOpsUrlMatchRegExp1) {
            $org, $project, $repo = $Matches[1], $Matches[2], $Matches[3]
        }
        elseif ($url_prefix -match $devOpsUrlMatchRegExp2) {
            $org, $project, $repo = $Matches[1], $Matches[2], $Matches[3]
        }
        else {
            echo "$($url) input format error"
            exit 1
        }

        $branch = $version.Substring(2, $version.length - 2)
        
        $token = [System.Environment]::GetEnvironmentVariable("token_$org")

        $ADO_METADATA_URL = "https://dev.azure.com/$(${org})/$(${project})/_apis/sourceProviders/TfsGit/filecontents?repository=$(${repo})&commitOrBranch=$($branch)&path=$(${path})&api-version=6.0"
    }
    else {
        Write-Warning "No query string found as part of the given URL"
    }

    try {
        return Invoke-WebRequest `
            -Method GET `
            -Headers (Get-ADOHeaders -token $token) `
            -Uri $ADO_METADATA_URL `
        | ConvertFrom-Json
    }
    catch {
        write-error "Get-ADOMetaData failed with exception:`n$_"
        exit 1
    }
}

function Push-Changes {
    param (
        [Parameter(Mandatory = $true)]
        $prBranch,
        [Parameter(Mandatory = $true)]
        $commitMsg,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )
    $B64Pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("`:$AuthToken"))
    git add -A
    git -c user.name="Azure Rest API Specs Review" -c user.email="swagger@microsoft.com" commit -am $commitMsg
    git remote -vv
    git -c http.extraHeader="Authorization: Basic $B64Pat" push origin $prBranch
}

function Clone-ADORepo {
    param (
        [Parameter(Mandatory = $true)]
        $org,
        [Parameter(Mandatory = $true)]
        $project,
        [Parameter(Mandatory = $true)]
        $repo,
        [Parameter(Mandatory = $true)]
        $dir,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )

    $B64Pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("`:$AuthToken"))
    git -c http.extraHeader="Authorization: Basic $B64Pat" clone "https://dev.azure.com/${org}/${project}/_git/${repo}" $dir
}

function Sync-ADORepo {
    param (
        [Parameter(Mandatory = $true)]
        $defaultBranch,
        [Parameter(Mandatory = $true)]
        $branch,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )
    
    $B64Pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("`:$AuthToken"))
    git -c http.extraHeader="Authorization: Basic $B64Pat" reset --hard $($defaultBranch)
    git -c http.extraHeader="Authorization: Basic $B64Pat" push origin $($branch) -f
}

function Get-ADOPullRequests {
    param (
        [Parameter(Mandatory = $true)]
        $org,
        [Parameter(Mandatory = $true)]
        $project,
        [Parameter(Mandatory = $true)]
        $repo,
        [Parameter(Mandatory = $true)]
        $sourceRefName,
        [Parameter(Mandatory = $true)]
        $targetRefName,
        [ValidateSet("abandoned", "active", "all", "completed", "notSet")]
        $prStatus,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )

    $url = "https://dev.azure.com/${org}/${project}/_apis/git/repositories/${repo}/pullrequests?searchCriteria.sourceRefName=${sourceRefName}&searchCriteria.targetRefName=${targetRefName}&searchCriteria.status=${prStatus}&api-version=6.0"
    $resp = Invoke-RestMethod -Uri $url -Method Get -ContentType "application/json" -Headers (Get-ADOHeaders -token $AuthToken)
    return $resp
}

function Create-ADOPullRequest {
    param (
        [Parameter(Mandatory = $true)]
        $org,
        [Parameter(Mandatory = $true)]
        $project,
        [Parameter(Mandatory = $true)]
        $repo,
        [Parameter(Mandatory = $true)]
        $prBody,
        [Parameter(Mandatory = $true)]
        $AuthToken
    )

    $url = "https://dev.azure.com/${org}/${project}/_apis/git/repositories/${repo}/pullrequests?api-version=6.0"
    Invoke-RestMethod -Uri $url -Method POST -ContentType "application/json" -Headers (Get-ADOHeaders -token $AuthToken) -Body $prBody
}

function LogError {
    Write-Host "##vso[task.LogIssue type=error;]$args"
}

function main() {
    Write-Host "Meta Url is $($env:ADO_METADATA_URL)"

    $home_dir = $pwd
    $github_dir = "$($GithubConfig.owner)-$($GithubConfig.repo)"
    $github_file_path = Join-Path $home_dir $github_dir $GithubConfig.path

    try {
        Clone-GitHubRepo $GithubConfig.owner $GithubConfig.repo $github_dir
        # $GitHubMetaData = Get-GitHubMetaData -uri $github_metaData_url -AuthToken $github_token
        $ADOMetaData = Get-ADOMetaData -url $ADO_metaData_url

        foreach ($r in $ADOMetaData.onboarded_services) {
            $ADO_url = $r.ADO_url
            $ADO_swagger_dir = $r.swagger_dir
            $ADO_token_flag = $r.ado_org

            if ($ADO_url -match $devOpsUrlMatchRegExp1) {
                $ADO_org, $ADO_project, $ADO_repo = $Matches[1], $Matches[2], $Matches[3]
            }
            elseif ($ADO_url -match $devOpsUrlMatchRegExp2) {
                $ADO_org, $ADO_project, $ADO_repo = $Matches[1], $Matches[2], $Matches[3]
            }
            else {
                echo "$($ADO_url) input format error"
                exit 1
            }

            $ADO_Token = [System.Environment]::GetEnvironmentVariable("token_$ADO_token_flag")
            # $ADO_Token = (Get-Variable -Name "token_$ADO_org").value

            if ([string]::IsNullOrEmpty($ADO_Token)) {
                write-error "Get Token for $($ADO_token_flag) failed with exception:`n$_"
                exit 1
            }

            $ADO_dir = "$($ADO_org)-$($ADO_project)-$($ADO_repo)"
            $ADO_branch = "auto-sync-from-$($ADO_repo)"

            Clone-ADORepo -org $ADO_org -project $ADO_project -repo $ADO_repo -dir $ADO_dir -AuthToken $ADO_Token
        
            Set-Location $ADO_dir
    
            # get default branch
            $ADO_default_branch = git symbolic-ref --short HEAD

            # checkout branch
            $b = $(git branch --list --remotes "origin/$ADO_branch")
            if ($b) {
                $checkoutFrom = "origin/$ADO_branch"
            }
            else {
                $checkoutFrom = "origin/$($ADO_default_branch)"
            }
            echo "checking $ADO_branch from $checkoutFrom"
            Checkout-Branch $ADO_branch $checkoutFrom

            # sync force from default branch
            Sync-ADORepo -defaultBranch $ADO_default_branch -branch $ADO_branch -AuthToken $ADO_Token
        
            $ADO_file_path = Join-Path $home_dir $ADO_dir $ADO_swagger_dir
        
            # delete path files
            try {
                Remove-Item "$($ADO_file_path)/common-types" -Force -Recurse
            }
            catch {
                echo "$($ADO_file_path) is not existing"
                exit 1
            }

            # copy path files from github
            Copy-Item $github_file_path "$($ADO_file_path)/common-types" -Recurse -Force

            #git add 
            Push-Changes -prBranch $ADO_branch  -commitMsg 'Sync common-types folder files' -AuthToken $ADO_Token

            # create pull request
            $pr_body = 
            @"
{
  "sourceRefName": "refs/heads/${ADO_branch}",
  "targetRefName": "refs/heads/${ADO_default_branch}",
  "title": "[AutoSync] sync comment-types folder from ADO repo",
  "description": "Sync comment-types folder from ADO repo",
}
"@

            $resp = Get-ADOPullRequests -org $ADO_org -project $ADO_project -repo $ADO_repo -sourceRefName "refs/heads/${ADO_branch}" -targetRefName "refs/heads/${ADO_default_branch}" -prStatus "active" -AuthToken $ADO_Token
            if ($resp.Count -ne 0) {
                echo "PR already exists $($resp.value[0].url)"
            }
            else {
                $pr = Create-ADOPullRequest -org $ADO_org -project $ADO_project -repo $ADO_repo -prBody $pr_body -AuthToken $ADO_Token
                echo "PR has been created $($pr.url)"
            }
    
            Set-Location $home_dir
            Remove-Item -Recurse -Force -Path $ADO_dir

        }

        Remove-Item -Recurse -Force -Path $github_dir 
    }
    catch {
        write-error "script run failed with exception:`n$_"
        if (Test-Path $github_dir) {
            Remove-Item -Recurse -Force -Path $github_dir 
        }
    }
    finally {
        Set-Location $home_dir
    }
}
main
