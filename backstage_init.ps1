$root = "c:\temp\repos"
function _Main{
         
    $repo = _Get-Repos
}
function Main{

    $includedFile = '*.md', '*swagger*.yaml', '*swagger*.yml', '*swagger*.json'
    $exludedFile = 'CHANGELOG.md', 'level?.md', 'scorecard*', 'PULL_REQUEST_TEMPLATE.md'

    $curDir = $PWD
    cd $PSScriptRoot

    $repos = Get-Repos -businessCritical
    
    $results = ""
    
    foreach($repo in $repos){
        Add-RepoLocally -repo $repo

        cd $repo.Path

        $paths = Get-ChildItem -File -Recurse -Include $includedFile -Exclude  $exludedFile | Resolve-path -Relative |%{$_.Replace('.\','')}
        $fileSystem = ConvertFrom-FileHierarchy -paths $paths

        #Out-MkDocs -repo $repo -fileSystem $filesSystem 
        
        Out-Catalog -repo $repo -fileHierarchy $fileSystem

        #New-PullRequest $repo

        cd $curDir

    }

    $results

}

function Out-Catalog{
    param(
        $repo,
        $fileHierarchy
        )

    $swaggers = Find-SwaggerDocuments -directory $fileHierarchy


    $catalog = ConvertTo-CatalogFromTemplate `
        -repo $repo `
        -apiSpecPaths $swaggers

    $catalog | Out-File -Force -FilePath "catalog.yaml"
   
}

function ConvertTo-CatalogApiYaml{
    param(
        [Parameter(ValueFromPipeline)]
        $specs,
        [Parameter(Position=0)]
        $repo
        )
    
    if(!$specs){
        return ""
    }

    $margin = " " * 8
    $indent = " " * 4

    $dubIndent = $indent * 3

    $yaml = Get-ApiSpecTemplate | Format-Template $repo

    $yaml += foreach($spec in $specs){
        $version = Get-OpenApiVersion -specPath $spec
        $specContent = "$margin$indent - swagger:`r`n"

        if($version){
             $specContent += "$margin$($dubIndent)type:$($version.Type)`r`n"
        }
        
        $specContent += "$margin$($dubIndent)path:$spec`r`n"
        $specContent += "---`r`n"    
        $specContent    
    }

    return $yaml
    
}

function Get-OpenApiVersion {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]
        $specPath
    )

    # Read the OpenAPI/Swagger spec file
    $specContent = Get-Content -Path $specPath -Raw

    # Define the regex pattern to extract the type and version
    $regexPattern = "\s*[{`"]*(?<type>openapi|swagger)[`"\s]*:"

    # Use regex to match the type and version
    $match = $specContent | Select-String -Pattern $regexPattern -AllMatches

    if ($match.Matches.Success) {
        $type = $match.Matches.Groups | where{$_.name -eq 'type' }
        
        [PSCustomObject]@{
            Type = $type
        }
    }
    else {
        Write-Warning "Failed to extract type and version from the OpenAPI/Swagger spec."
        $null
    }
}

function Out-MkDocs{
    param(
    [Parameter(Position=0)]
    $repo,
    [Parameter(Position=1)]
    $fileSystem  
    )   
    $menu = ConvertTo-MkDocYamlMenu $filesSystem  
    $template = Get-MkDocsTemplate

    $content = $template.Replace('{repoName}', $repo.Name).Replace('{nav}', $menu)

    $savePath = Join-Path $repo.Path  "$($repo.Name)_mkdocs.yaml"

    $content | Out-File $savePath

}
function Get-MkDocsTemplate {
    
    return @'
    site_name: '{repoName}'

nav: 
{nav}

plugins:
  - techdocs-core
'@
    
}

function ConvertTo-MkDocYamlMenu {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [hashtable]
        $fileStructure,
        [int]
        $indentLevel = 0
    )

    $menu = ""
    $indent = " " * $indentLevel


    $readmeFile = $fileStructure['files']['README.md']

    if ($readmeFile) {
        $name = Get-FormattedName 'README.md'
        $menu += "${indent}- $name : $readmeFile`n"
    }

    foreach ($fileEntry in $fileStructure['files'].Keys) {
        if ($fileEntry -ne 'README.md') {
            $name = Get-FormattedName $fileEntry
            $value = $fileStructure['files'][$fileEntry]  
            $menu += "${indent}- $name : $value`n"
        }
    }

    foreach ($directoryEntry in $fileStructure['directories'].Keys) {
        $name = Get-FormattedName $directoryEntry
        $value = $fileStructure['directories'][$directoryEntry]
        $menu += "${indent}- $name`n"
        $menu += ConvertTo-MkDocYamlMenu -fileStructure $value -indentLevel ($indentLevel + 2) | ForEach-Object {
            "${indent}  $_"
        }
    }

    return $menu
}

function Find-SwaggerDocuments {
    param(
        $directory
    )
    $swaggerDocuments = @()

    # Iterate through the files in the current directory
    foreach ($fileEntry in $directory['files'].Keys) {
        $file = $directory['files'][$fileEntry]
        $extension = [System.IO.Path]::GetExtension($file)

        # Check if the file has a Swagger document extension (e.g., .json or .yaml)
        if ($extension -in ".json", ".yaml", "yml") {
            $swaggerDocuments += $file
        }
    }

    # Recursively traverse the subdirectories
    foreach ($subdirectoryEntry in $directory['directories'].Keys) {
        $subdirectory = $directory['directories'][$subdirectoryEntry]
        $swaggerDocuments += Find-SwaggerDocuments $subdirectory
    }

    return $swaggerDocuments
}
function ConvertFrom-FileHierarchy {
param (
    [Parameter(Position = 0, Mandatory = $true)]
    [string[]]
    $paths,

    [Parameter(Position = 1)]
    [string[]]
    $exclusions = @("src", "main", "resources", "docs", "appendix", "external", "internal", ".git")
)

$root = @{
    files = @{}
    directories = @{}
}

foreach ($path in $paths) {
    $segments = $path -split '\\'

    $currentFiles = $root['files']
    $currentDirectories = $root['directories']

    for ($i = 0; $i -lt $segments.Length - 1; $i++) {
        $segment = $segments[$i]
        if ($exclusions.Contains($segment)) {
            continue
        }

        if (-not $currentDirectories.ContainsKey($segment)) {
            $currentDirectories[$segment] = @{
                files = @{}
                directories = @{}
            }
        }

        $currentFiles = $currentDirectories[$segment]['files']
        $currentDirectories = $currentDirectories[$segment]['directories']
    }

    $lastSegment = $segments[-1]
    if (-not $currentFiles.ContainsKey($lastSegment) -and -not $exclusions.Contains($lastSegment)) {
        $currentFiles[$lastSegment] = $path
    }
}

return $root

}

function Get-TeamName{
    param(        
        $candidates,
        $knownTeams = @(
        'avengers',
        'fungible',
        'mobsrus',
        'teamfusion',
        'team-fusion',
        'team-goat',
        'team-things',
        'team-atsops')
        )
        
    $possibleName = $knownTeams | Where-Object { $candidates -contains $_ }

    $name = if($possibleName){
        $possibleName -replace "-",""
    }else{
        "unknown"
    }

    return $name
}
function Get-FormattedName{
    param(
        [Parameter(position=0, ValueFromPipeline)]
        $name,
        [Parameter(position=1)]
        $filter = '(README|_index)'
        )

        $name = switch -Regex ($name) {
            "(?i)^$filter\.md$" { "Home"; break }
            "(?i)^(?<name>.+)$filter\.md" { $matches["name"]; break }
            "(?i)^$filter(?<name>.+)\.md" { $matches["name"]; break }
            "(?i)(?<name>.*)" { $matches["name"]; break }
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

function Format-Template{
    param(
        [Parameter(ValueFromPipeline)]
        $template,
        [Parameter(Position=0)]
        $obj,
        
        $openingDelimeter = "`{",
        $closingDelimeter = "`{"
    )

    $obj | Get-Member -MemberType NoteProperty | ForEach-Object {
        $key = $_.Name
        $value = $obj.$key
        
        $template = $template -replace "$openingDelimiter$key$closingDelimiter", $value
    }

    return $template
}
function Get-Repos{
    param(
    [string] $organization = "loyaltyone",
    [decimal]$recentRepoCutoffDateInYears = 0,
    [string]$topic = "business-critical"
    )

    $filter = @("org:$organization")

    if($recentRepoCutoffDateInYears){
        $cutoff = (get-date).AddYears($recentRepoCutoffDateInYears *-1).ToString('yyyy-MM-ddTHH:mm:ss')
        $filter +=  "pushed:>$cutoff"
    }

    if($topic){
        $filter += "topic:$topic"
    }
               
    $graph = Join-Path -Path $PSScriptRoot -ChildPath "backstage_init.graphql"
    $results = gh api graphql --paginate -F query="@$graph" -F filter=$($filter -Join " ") `
    | gh merge-json `
    | ConvertFrom-Json 

    $nodes = $results.data.search.nodes

    $repos = ForEach($repo in $nodes)
    {   
        [PSCustomObject]@{
            Name = $repo.name
            Description = $repo.description
            Url = $repo.url
            Path = "$root\$($repo.name)"
            Repo = $repo.nameWithOwner
            Topics = $repo.repositoryTopics.edges.node.topic.name
            Team = $(Get-TeamName -candidates $repo.repositoryTopics.edges.node.topic.name)
            Languages = $repo.languages.nodes.name
        }    
    }

    return $repos
}
function New-PullRequest{
    param(
        $repo
    )


    $branch = 'backstage-setup'
    $prTitle = 'Backstage mkdocs and catalog yaml Autogeneration'
    $prMessage = 'Collects all mds in a repository and creates a menu system based on the directory structure to autogenerate mkdoc file'

    $originalPath = (gi .).FullName
    cd $repo.Path
    
    $defaultBranch = Get-DefaultBranch

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
    $defaultBranch = Get-DefaultBranch $repo

    if($currentBranch -ne $defaultBranch){
        git stash       
    }

    git fetch origin $defaultBranch
    git merge -s recursive -X theirs origin/$defaultBranch

    cd $originalPath
}
function Get-DefaultBranch{
    param(
        $repo
    )

    $originalPath = (gi .).FullName
    
    if($repo){
        cd $repo.Path
    }

     #if we want to rip out gh, we could probably use something like the below line to get the default branch since we are cloning all the repos we are opertaing on (vs authoring them)
    #git symbolic-ref --short refs/remotes/origin/HEAD
    $default = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name

    cd $originalPath

    return $default
}
function ConvertTo-CatalogFromTemplate{
    param(
        $repo,
        $apiSpecPaths
    )
    
    $template = Get-CatalogTemplate
    $template = $template | Format-Template $repo 
    
    $specMenu = $apiSpecPaths | ConvertTo-CatalogApiYaml $repo

    $template = $template -replace "{API}", $specMenu

    return $template

}
function Get-CatalogTemplate{
    $template = @'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
    name: "{Name}"
    description: {Description}
    namespace: 
    annotations:
    github.com/project-slug: {Repo}
    github.com/team-slug: {Team}
    sonarqube.org/project-key: ""
    backstage.io/techdocs-ref: dir:.
    tags:
        - business-critical
    links:
{API}    
'@

return $template

}

function Get-ApiSpecTemplate{
return @'
spec:
    type: service
    owner: {Team}
    lifecycle: experimental
    providesApis:

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

       $data = ConvertFrom-Json '[ [
        {
            "Name":  "airmiles-web-bff",
            "Url":  "https://github.com/LoyaltyOne/airmiles-web-bff",
            "Path":  "\\airmiles-web-bff",
            "Repo":  "LoyaltyOne/airmiles-web-bff",
            "Topics":  [
                           "business-critical",
                           "team-goat"
                       ],
            "Team":  "teamgoat",
            "Languages":  [
                              "Java",
                              "Shell",
                              "TypeScript",
                              "Dockerfile",
                              "Python",
                              "JavaScript",
                              "HTML",
                              "Groovy"
                          ]
        },
        {
            "Name":  "falcon",
            "Url":  "https://github.com/LoyaltyOne/falcon",
            "Path":  "\\falcon",
            "Repo":  "LoyaltyOne/falcon",
            "Topics":  [
                           "fungible",
                           "business-critical"
                       ],
            "Team":  "fungible",
            "Languages":  [
                              "JavaScript",
                              "Dockerfile",
                              "Shell",
                              "HTML",
                              "TypeScript",
                              "SCSS",
                              "EJS",
                              "CSS"
                          ]
        },
        {
            "Name":  "aem-airmiles-web",
            "Url":  "https://github.com/LoyaltyOne/aem-airmiles-web",
            "Path":  "\\aem-airmiles-web",
            "Repo":  "LoyaltyOne/aem-airmiles-web",
            "Topics":  [
                           "business-critical",
                           "team-goat"
                       ],
            "Team":  "teamgoat",
            "Languages":  [
                              "Java",
                              "Groovy",
                              "HTML",
                              "JavaScript",
                              "Handlebars",
                              "SCSS",
                              "TypeScript",
                              "Dockerfile",
                              "Shell",
                              "Less",
                              "CSS"
                          ]
        },
        {
            "Name":  "profile-api",
            "Url":  "https://github.com/LoyaltyOne/profile-api",
            "Path":  "\\profile-api",
            "Repo":  "LoyaltyOne/profile-api",
            "Topics":  [
                           "avengers",
                           "business-critical",
                           "profile-api",
                           "csor"
                       ],
            "Team":  "avengers",
            "Languages":  [
                              "Kotlin",
                              "Shell",
                              "Java",
                              "Scala",
                              "Groovy",
                              "Dockerfile"
                          ]
        },
        {
            "Name":  "auth0-login",
            "Url":  "https://github.com/LoyaltyOne/auth0-login",
            "Path":  "\\auth0-login",
            "Repo":  "LoyaltyOne/auth0-login",
            "Topics":  [
                           "react",
                           "jsx",
                           "avengers",
                           "business-critical",
                           "iam",
                           "auth0"
                       ],
            "Team":  "avengers",
            "Languages":  [
                              "HTML",
                              "Shell",
                              "JavaScript",
                              "SCSS"
                          ]
        },
        {
            "Name":  "zoo",
            "Url":  "https://github.com/LoyaltyOne/zoo",
            "Path":  "\\zoo",
            "Repo":  "LoyaltyOne/zoo",
            "Topics":  [
                           "business-critical",
                           "team-goat"
                       ],
            "Team":  "teamgoat",
            "Languages":  [
                              "JavaScript",
                              "CSS",
                              "TypeScript",
                              "Shell",
                              "Groovy",
                              "HTML",
                              "Dockerfile",
                              "SCSS",
                              "EJS"
                          ]
        },
        {
            "Name":  "airmiles-aem",
            "Url":  "https://github.com/LoyaltyOne/airmiles-aem",
            "Path":  "\\airmiles-aem",
            "Repo":  "LoyaltyOne/airmiles-aem",
            "Topics":  [
                           "business-critical",
                           "team-goat"
                       ],
            "Team":  "teamgoat",
            "Languages":  [
                              "Shell",
                              "JavaScript",
                              "Groovy",
                              "Dockerfile",
                              "Java",
                              "Python",
                              "EJS",
                              "Gherkin",
                              "HTML",
                              "SCSS",
                              "CSS",
                              "Less"
                          ]
        },
        {
            "Name":  "offer-management-api",
            "Url":  "https://github.com/LoyaltyOne/offer-management-api",
            "Path":  "\\offer-management-api",
            "Repo":  "LoyaltyOne/offer-management-api",
            "Topics":  [
                           "team-things",
                           "business-critical"
                       ],
            "Team":  "teamthings",
            "Languages":  [
                              "Groovy",
                              "Shell",
                              "Dockerfile",
                              "Kotlin",
                              "Gherkin",
                              "PLpgSQL",
                              "Python"
                          ]
        },
        {
            "Name":  "collector-secure-signup-token-api",
            "Url":  "https://github.com/LoyaltyOne/collector-secure-signup-token-api",
            "Path":  "\\collector-secure-signup-token-api",
            "Repo":  "LoyaltyOne/collector-secure-signup-token-api",
            "Topics":  [
                           "iam",
                           "avengers",
                           "business-critical",
                           "signup-token-api"
                       ],
            "Team":  "avengers",
            "Languages":  [
                              "Shell",
                              "Dockerfile",
                              "JavaScript",
                              "TypeScript"
                          ]
        },
        {
            "Name":  "api-gateway-external-promotion-service-api",
            "Url":  "https://github.com/LoyaltyOne/api-gateway-external-promotion-service-api",
            "Path":  "\\api-gateway-external-promotion-service-api",
            "Repo":  "LoyaltyOne/api-gateway-external-promotion-service-api",
            "Topics":  [
                           "team-things",
                           "business-critical"
                       ],
            "Team":  "teamthings",
            "Languages":  [
                              "Groovy",
                              "Shell",
                              "Python"
                          ]
        }
    ]'

    return $data[0..($numItems - 1)]
}


`

Main