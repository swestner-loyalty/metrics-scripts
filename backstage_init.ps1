
$debug = $true

function Main{

    $includedFile = '*.md', 'swagger.yaml', 'swagger.json'
    $exludedFile = 'CHANGELOG.md','level?.md', 'scorecard*', 'PULL_REQUEST_TEMPLATE.md'

    $repos = Get-Repos -businessCritical -mockData:$debug
    $curDir = $PWD

    
    foreach($repo in $repos){
        Add-RepoLocally -repo $repo
        cd $repo.Path

        $paths = Get-ChildItem -File -Recurse -Include $includedFile -Exclude  $exludedFile | Resolve-path -Relative |%{$_.TrimStart('.\')}

        $filesSystem = Get-FileHierarchy -paths $paths
        $menu = Convert-ToMkdocsYaml -fileHierarchy $filesSystem    
        Out-MkDocs -repo $repo -nav $menu  -dryRun:$debug

        New-PullRequest $repo -dryRun:$debug

        cd $curDir

    }
}

function Out-MkDocs{
    param(
    [Parameter(ValueFromPipeline)]
    $nav,
    [Parameter(Position=0)]
    $repo,
    [Parameter(Position=1)]
    [switch]$dryRun   
    )
    
    $template = Get-YamlTemplate
    
    $content = $template.Replace('{repoName}', $repo.Name).Replace('{nav}', $nav)

    if($dryRun){
        return $content
    }
    
    $savePath = Join-Path $repo.Path "mkdocs.yaml"

    $content | Out-File $savePath

}

function Get-FileHierarchy {
    param (
        [Parameter(Position = 0)]
        [string[]]
        $paths
    )

    $meaninglessFolderNames = "src","main","resources","docs","appendix", "external", "internal", ".git"
    
    $root = @{}

    foreach ($path in $paths) {
        $segments = $path -split '\\'

        $current = $root
        foreach ($segment in $segments) {
            if ($meaninglessFolderNames.Contains($segment)) {
                continue
            }

            if (-not $current.ContainsKey($segment)) {
                $current[$segment] = @{}
            }

            $current = $current[$segment]
        }

        $current['__path'] = $path
    }

    return $root
}

function Convert-ToMkdocsYaml {
    param (
        [Parameter(Position = 0)]
        [hashtable]
        $fileHierarchy
    )

    $yamlBuilder = [System.Text.StringBuilder]::new()

    # Helper function to add YAML key-value pair
    function Add-YamlKeyValuePair {
        param (
            [Parameter(Position = 0)]
            [string]
            $key,

            [Parameter(Position = 1)]
            [string]
            $value,

            [Parameter(Position = 2)]
            [int]
            $indentLevel
        )

        Add-Indent -indentLevel $indentLevel

        $formattedKey =  $key | Get-FormattedName
        $formattedValue = if($value){ "`'$value`'"}else{ ""}

        $yamlBuilder.Append("$formattedKey`: $formattedValue")
        $yamlBuilder.AppendLine()
    }

    # Helper function to indent the YAML content
    function Add-Indent {
        param (
            [Parameter(Position = 0)]
            [int]
            $indentLevel
        )

        $indent = '  ' * $indentLevel
        $yamlBuilder.Append($indent)
    }

    # Recursive function to build the YAML string
    function Invoke-BuildYaml {
        param (
            [Parameter(Position = 0)]
            [hashtable]
            $hierarchy,

            [Parameter(Position = 1)]
            [string]
            $parentKey = '',

            [Parameter(Position = 2)]
            [string]
            $basePath = '',

            [Parameter(Position = 3)]
            [int]
            $indentLevel = 0
        )

        $keys = $hierarchy.Keys | Sort-Object

        # Sort keys with README.md to the top
        $sortedKeys = @(
            $keys | Where-Object { $_ -eq 'README.md' }
            $keys | Where-Object { $_ -ne 'README.md' }
        )

        foreach ($key in $sortedKeys) {
            if ($key -eq '__path') {
                continue
            }

            $currentKey = $key
            $currentPath = $hierarchy[$key]['__path']
            $relativePath = if ($basePath) { Join-Path -Path $basePath -ChildPath $currentPath } else { $currentPath }

            Add-YamlKeyValuePair -key $currentKey -value $relativePath -indentLevel $indentLevel

            $subHierarchy = $hierarchy[$key] | Where-Object { $_ -is [hashtable] }
            if ($subHierarchy) {
                Invoke-BuildYaml -hierarchy $subHierarchy -parentKey $currentKey -basePath $relativePath -indentLevel ($indentLevel + 1)
            }
        }
    }

    Invoke-BuildYaml -hierarchy $fileHierarchy

    return $yamlBuilder.ToString()
}

function Get-FormattedName{
    param(
        [Parameter(position=0, ValueFromPipeline)]
        $name
        )

        $name = switch -Regex ($name){
                     '(?i)^(README|_index)\.md$'{ "Home";break }
                     '(?i)^(?<name>.+)README\.md' {$matches["name"];break}
                     '(?i)^README(?<name>.+)\.md'  {$matches["name"];break}
                     '(?i)(?<name>.*)' {$matches["name"];break}
                 }

        return $name | ConvertTo-TitleCase | ConvertTo-ReadableFormat
}

function ConvertTo-ReadableFormat{
    param(
        [Parameter(position=0, ValueFromPipeline)]
        $toConvert
        )

    $toReplace = "(-|_)"
    $toRemove = "(?i)(\.md|\.)"

    return $toConvert -replace $toReplace, " " -replace $toRemove, ""
}
    
function ConvertTo-TitleCase{
    param(
        [Parameter(position=0, ValueFromPipeline)]
        $toConvert
        )
        
    return (Get-Culture).TextInfo.ToTitleCase($toConvert.ToLower())
}

function New-PullRequest{
    param(
        $repo,
        [switch]$dryRun
    )

    if($dryRun){
        return 
    }

    $branch = 'backstage-setup'
    $prTitle = 'Backstage mkdocs Autogeneration'
    $prMessage = 'Collects all mds in a repository and creates a menu system based on the directory structure to autogenerated mkdoc file'

    $originalPath = (gi .).FullName
    cd $repo.Path
    
    $defaultBranch = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name

    git checkout -b $branch
    git add --all
    git commit -am $prMessage
    git push origin 'backstage-setup'

    gh pr create --base $defaultBranch --head $branch --title $prMessage --body $prMessage 
}


function Add-RepoLocally{
    param(
        $repo
    )

    $originalPath = (gi .).FullName

    if(!(Test-Path $repo.Path)){
        git clone $repo.Url --depth=1 $repo.Path                
    }

    cd $repo.Path

    $currentBranch = git branch --show-current
    $defaultBranch = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name

    #if we want to rip out gh, we could probably use something like the below line to get the default branch since we are cloning all the repos we are opertaing on (vs authoring them)
    #git symbolic-ref --short refs/remotes/origin/HEAD

    if($currentBranch -ne $defaultBranch){
        git stash       
    }

    git fetch origin $defaultBranch
    git merge -s recursive -X theirs origin/$defaultBranch

    cd $originalPath
}

function Get-Repos{
    param(
        $yearsOld = 0,
        [switch] $businessCritical,
        [switch] $mockData,
        $org = "loyaltyone"
    )

    if($mockData){
        return Get-MockDataJson
    }

    $cmd = "gh repo list $org --limit 2000"

    if($businessCritical){
        $cmd += " --topic 'business-critical'"
    }

    $repos = Invoke-Command $cmd  | ConvertFrom-Csv -Delimiter "`t" -header repo,desc,status,date

    if($yearsOld -gt 0){
        $repos = $repos | Where-Object{$_.date -gt $cutoff}
    }

    $mapped = $repos | ForEach-Object{ [PSCustomObject]@{
        Name = $_.repo.Split('/')[1]
        Url = "https://github.com/$($_.repo)"
        Path = "$root\$($_.repo.Split('/')[1])"
        Date = $_.Date
        Repo = $_.Repo
        }
    }
    return $mapped
}

function Get-YamlTemplate {
    
    return @'
site_name: '{repoName}'

nav: 
  {nav}

plugins:
  - techdocs-core
'@
    
}
function Get-MockDataJson{
    [CmdletBinding()]
    param(
        [parameter(Position=0)]
        [ValidateRange(1,10)]
        [int]
        $numItems = 10
    )

       $data = ConvertFrom-Json '[ {
        "Name":  "API-Guidelines",
        "Url":  "https://github.com/LoyaltyOne/API-Guidelines",
        "Path":  "c:\\temp\\repos\\API-Guidelines",
        "Date":  "2022-11-22T18:44:44Z",
        "Repo":  "LoyaltyOne/API-Guidelines",
        "Topics":  ""
       }]'



    #    "Name":  "airmiles-aem",
    #    "Url":  "https://github.com/LoyaltyOne/airmiles-aem",
    #    "Path":  "c:\\temp\\repos\\airmiles-aem",
    #    "Date":  "2022-11-22T18:44:44Z",
    #    "Repo":  "LoyaltyOne/airmiles-aem",
    #    "Topics":  "team-goat"
    #    }
    #},
      #  
      #  ,
      #  {
      #      "Name":  "transaction-summary-consumer",
      #      "Url":  "https://github.com/LoyaltyOne/transaction-summary-consumer",
      #      "Path":  "c:\\temp\\repos\\transaction-summary-consumer",
      #      "Date":  "2022-11-22T18:05:28Z",
      #      "Repo":  "LoyaltyOne/transaction-summary-consumer",
      #      "Topics":  "teamfusion"
      #  },
      #  {
      #      "Name":  "promotion-service",
      #      "Url":  "https://github.com/LoyaltyOne/promotion-service",
      #      "Path":  "c:\\temp\\repos\\promotion-service",
      #      "Date":  "2022-11-22T16:32:19Z",
      #      "Repo":  "LoyaltyOne/promotion-service",
      #      "Topics":  "team-things"
      #  },
      #  {
      #      "Name":  "aem-airmiles-web",
      #      "Url":  "https://github.com/LoyaltyOne/aem-airmiles-web",
      #      "Path":  "c:\\temp\\repos\\aem-airmiles-web",
      #      "Date":  "2022-11-22T14:19:09Z",
      #      "Repo":  "LoyaltyOne/aem-airmiles-web",
      #      "Topics":  [
      #                     "team-goat",
      #                     "team-atsops"
      #                 ]
      #  },
      # 
      #  {
      #      "Name":  "airmiles-web-bff",
      #      "Url":  "https://github.com/LoyaltyOne/airmiles-web-bff",
      #      "Path":  "c:\\temp\\repos\\airmiles-web-bff",
      #      "Date":  "2022-11-21T18:05:47Z",
      #      "Repo":  "LoyaltyOne/airmiles-web-bff",
      #      "Topics":  "team-goat"
      #  },
      #  {
      #      "Name":  "auth0-pages",
      #      "Url":  "https://github.com/LoyaltyOne/auth0-pages",
      #      "Path":  "c:\\temp\\repos\\auth0-pages",
      #      "Date":  "2022-11-21T16:31:22Z",
      #      "Repo":  "LoyaltyOne/auth0-pages",
      #      "Topics":  "team-goat"
      #  },
      #  {
      #      "Name":  "rtc-amcash-infra",
      #      "Url":  "https://github.com/LoyaltyOne/rtc-amcash-infra",
      #      "Path":  "c:\\temp\\repos\\rtc-amcash-infra",
      #      "Date":  "2022-11-21T15:47:43Z",
      #      "Repo":  "LoyaltyOne/rtc-amcash-infra",
      #      "Topics":  "mobsrus"
      #  },
      #  {
      #      "Name":  "zoo",
      #      "Url":  "https://github.com/LoyaltyOne/zoo",
      #      "Path":  "c:\\temp\\repos\\zoo",
      #      "Date":  "2022-11-22T16:20:15Z",
      #      "Repo":  "LoyaltyOne/zoo",
      #      "Topics":  "team-goat"
      #  },
      #  {
      #      "Name":  "api-gateway-external-offer-state-api",
      #      "Url":  "https://github.com/LoyaltyOne/api-gateway-external-offer-state-api",
      #      "Path":  "c:\\temp\\repos\\api-gateway-external-offer-state-api",
      #      "Date":  "2022-11-18T18:36:13Z",
      #      "Repo":  "LoyaltyOne/api-gateway-external-offer-state-api",
      #      "Topics":  "team-things"
      #  },
      #  {
      #      "Name":  "notification-service-producer",
      #      "Url":  "https://github.com/LoyaltyOne/notification-service-producer",
      #      "Path":  "c:\\temp\\repos\\notification-service-producer",
      #      "Date":  "2022-11-18T18:08:43Z",
      #      "Repo":  "LoyaltyOne/notification-service-producer",
      #      "Topics":  [
      #                     "avengers",
      #                     "notification-service"
      #                 ]
      #  }
    #]
#
    return $data[0..($numItems - 1)]
}

Main