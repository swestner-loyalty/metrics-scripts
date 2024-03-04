param (
    [Parameter()]
    $repos
)

#the script will not create pull requests while in debug mode 
$DEBUG = $true
$root = "/temp/repos"
$Global:repos = $repos

function Main{
    $includedFile =  'swagger.yaml', '*.md', '*swagger*.yaml', '*swagger*.yml', '*swagger*.json'
    $exludedFile = 'CHANGELOG.md', 'level?.md', 'scorecard*', 'PULL_REQUEST_TEMPLATE.md'

    $curDir = $PWD
    cd $PSScriptRoot

    $repos = if($Global:repos){
        $Global:repos
    }else{
        Get-Repos -businessCritical
    }

    $results = ""
    
    foreach($repo in $repos){

        echo $repo
        Add-RepoLocally -repo $repo

        cd $repo.Path

        $catalogPaths = Get-ChildItem -File -Recurse -Include $includedFile -Exclude  $exludedFile | Resolve-path -Relative |%{$_.Replace('.\','')}
        $catalogFileSystem = ConvertFrom-FileHierarchy -paths $catalogPaths

        $mkdocsPaths = Get-ChildItem -File -Recurse -Include '*.md' -Exclude  $exludedFile | Resolve-path -Relative |%{$_.Replace('.\','')}
        $mkdocsFileSystem = ConvertFrom-FileHierarchy -paths $mkdocsPaths


        Out-MkDocs -repo $repo -fileSystem $mkdocsFileSystem 
        
        Out-Catalog -repo $repo -fileHierarchy $catalogFileSystem

        if(!$DEBUG){
            New-PullRequest $repo
        }
        echo " --- Completed --- "
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

    $catalog | Out-File -Force -FilePath "catalog-info.yaml"
   
}
function ConvertTo-CatalogApiYaml{
    param(
        [Parameter(ValueFromPipeline)]
        $specs,
        [Parameter(Position=0)]
        $repo
        )

    $indent = " " * 4

    $yaml = Get-ApiSpecTemplate | Format-Template $repo

    $apiSpecTemplate = Get-CatalogApiTemplate | Format-Template $repo

    if(!$specs){
        $yaml = $yaml -replace "{APISPEC}", ""
        $yaml = $yaml -replace "{DOCS}", ""
        return $yaml
    }
    
    $yaml = $yaml -replace "{APISPEC}", $apiSpecTemplate
    $swaggerPath = ""
    $docs += foreach($spec in $specs){
        $version = Get-OpenApiVersion -specPath $spec
        $swaggerPath = $spec
        $specContent = "  providesApis:`n$indent- {Name}`n"
        $specContent    
    }


    $yaml = $yaml -replace "{DOCS}", $docs


    $yaml += "`n  definition:`n    `$text: $swaggerPath"
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
    $regexPattern = "(?<type>openapi|swagger)[`"\s]*:"

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
    $menu = ConvertTo-MkDocYamlMenu $fileSystem  

    $template = Get-MkDocsTemplate

    $content = $template.Replace('{repoName}', $repo.Name).Replace('{nav}', $menu)

    $savePath = Join-Path $repo.Path "mkdocs.yml"

    $content | Out-File $savePath

}

function ConvertTo-MkDocYamlMenu {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [hashtable]
        $fileStructure,
        [int]
        $indentLevel = 2
    )

    $menu = ""
    $indent = " " * $indentLevel


    $readmeFile = $fileStructure['files']['README.md']
    

    if ($readmeFile) {
        $name = Get-FormattedName 'README.md'
        $menu += "${indent}- ${name}: $readmeFile`n"
    }

    foreach ($fileEntry in $fileStructure['files'].Keys) {
        if ($fileEntry -ne 'README.md') {
            $name = Get-FormattedName $fileEntry
            $value = $fileStructure['files'][$fileEntry]  
            $menu += "${indent}- ${name}: $value`n"
        }
    }

    foreach ($directoryEntry in $fileStructure['directories'].Keys) {
        $name = Get-FormattedName $directoryEntry
        $value = $fileStructure['directories'][$directoryEntry]
        $menu += "${indent}- ${name}:`n"
        $menu += ConvertTo-MkDocYamlMenu -fileStructure $value -indentLevel ($indentLevel + 2) 
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
    $exclusions = @("src", "main", "resources", , "appendix", ".git")
)

$root = @{
    files = @{}
    directories = @{}
}

foreach ($path in $paths) {
    $segments = $path.trim("./") -split "\\|\/"

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
        'team-atsops',
        'teamdynamite')
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
        
        $openingDelimiter = "`{",
        $closingDelimiter = "`}"
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
    [string] $organization = "AirMilesLoyaltyInc",
    [decimal]$recentRepoCutoffDateInYears = 0,
    [string]$topic = "business-critical",
    [switch]$mockData = $false
    )

    if($mockData){
        return Get-MockData
    }
    
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
            #Description = $repo.description ? $repo.description : "<PLEASE FILL THIS DESCRIPTION>"
            Url = $repo.url
            Path = "$root/$($repo.name)"
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
    $prTitle = 'Backstage mkdocs and catalog-info Autogeneration'
    $prMessage = @'
This PR adds the necessary files to integrate the repo with Backstage:
* Creates a catalog-info file
* Collects all mds in a repository and creates a menu system based on the directory structure to autogenerate mkdoc file

If a `mkdocs.yml` file is generated, then please also add the following stage to your `ci` build processes, so that the docs are built and pushed to S3:
```groovy
stage ('Build techdocs') {
  agent {
    docker {
      image '277983268692.dkr.ecr.us-east-1.amazonaws.com/ubuntu-22-slim'
    }
  }
  steps {
    script {
      backstage.generateTechDocs()
      backstage.publishTechDocs()
    }
  }
}
```

The informative comments can be removed from the final PR.

Once reviewed and merged in, the repo should show up on Backstage once the next scan runs, i.e. in 12 hours.
'@

    $originalPath = (gi .).FullName
    cd $repo.Path
    git config user.name "AMNext-Jenkins"
    git config user.email "teamdynamite@loyalty.com"
    
    $defaultBranch = Get-DefaultBranch
    git checkout -b $branch
    git add --all
    git commit -am "$prTitle"
    git push origin 'backstage-setup'

    gh pr create --base "$defaultBranch" --head "$branch" --title "$prTitle" --body "$prMessage"
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
    git config user.name "AMNext-Jenkins"
    git config user.email "teamdynamite@loyalty.com"

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
    
    $specMenu = $apiSpecPaths | ConvertTo-CatalogApiYaml $repo

    $template = $template -replace "{API}", $specMenu

    $tags = Get-TagsYaml (Get-Tags $repo)
    $template = $template -replace "{TAGS}", $tags

    $template = $template | Format-Template $repo 
    return $template

}
function Get-CatalogTemplate{
    $template = @'
---
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: {Name}
  description: {Description}
  annotations:
    github.com/project-slug: {Repo}
    # If the value of this is 'AirmilesLoyaltyInc/unknown', please make sure to replace with the correct team name (from Github: https://github.com/orgs/AirMilesLoyaltyInc/teams?query=). Same thing for `spec.owner` below.
    github.com/team-slug: AirmilesLoyaltyInc/{Team}
    sonarqube.org/project-key: {Name}
    backstage.io/techdocs-ref: dir:.
    jenkins.loyalty.com/job-full-name: job/{Name}
{TAGS}
  links:
    - url: https://amrp.atlassian.net/wiki/spaces/BKS/overview
      title: Confluence
      icon: LibraryBooks
{API}  
'@

return $template

}

function Get-Tags{
    param(
        $repo
    )

    $tags = @("business-critical")

    # Only pick the top 3
    if($repo.Languages -is [array]){
        $tags += $repo.Languages[0..2]
    }else {
        $tags += $repo.Languages
    }

    return $tags
}

function Get-TagsYaml{
    param(
        $tags
    )

    $indent = " " * 2
    $newline = "`n"

    $output = "${indent}tags:${newline}"
    $output += "${indent}${indent}# Add tags for further classification:${newline}"
    $output += "${indent}${indent}# examples: platform (AES, AWS, etc...), framework (Springboot, Express, etc...), languages etc...${newline}"

    foreach ($tag in $tags)
    {
        if ($tag) {
            # Valid tag regex for backstage catalog:
            # "a string that is sequences of [a-z0-9+#] separated by [-]"
            $tag = $tag.ToLower()
            $tag = $tag -replace " ","-"
            $output += "${indent}${indent}- ${tag}${newline}"
        }
    }

    return $output
}

function Get-ApiSpecTemplate{
return @'
# 
# ######################### PLEASE, CHECK THE PARAMETERS #######################################
# Please, during the PR, check what is the correct spec.type, spec.lifecycle, spec.owner to your project. 
#
#spec.type:
#   service - a backend service, typically exposing an API
#   website - a website
#   library - a software library, such as an npm module or a Java library
#
#
# spec.lifecycle
#   experimental - an experiment or early, non-production component, signaling that users may not prefer to consume it over other more established components, or that there are low or no reliability guarantees
#   production - an established, owned, maintained component
#   deprecated - a component that is at the end of its lifecycle, and may disappear at a later point in time
# For more info, please visit the page: https://backstage.io/docs/features/software-catalog/descriptor-format/
# ###############################################################################################
spec:
  type: service
  owner: {Team}
  lifecycle: production
{DOCS}
{APISPEC}
'@
}
function Get-CatalogApiTemplate {
return @'
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: {Name}
  description: {Description}
spec:
  type: openapi
  lifecycle: production
  owner: {Team}
'@

}
function Get-MkDocsTemplate {
    
    return @'
site_name: '{repoName}'

docs_dir: "."

nav: 
{nav}

plugins:
  - techdocs-core
  - same-dir
'@
    
}



function Get-MockData{
    [CmdletBinding()]
    param(
        [parameter(Position=0)]
        [ValidateRange(1,10)]
        [int]
        $numItems = 10
    )


    $json = @"
    [ 
        {
            "Name":  "airmiles-web-bff",
            "Url":  "https://github.com/AirMilesLoyaltyInc/airmiles-web-bff",
            "Path":  "$root/airmiles-web-bff",
            "Repo":  "AirMilesLoyaltyInc/airmiles-web-bff",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/falcon",
            "Path":  "$root/falcon",
            "Repo":  "AirMilesLoyaltyInc/falcon",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/aem-airmiles-web",
            "Path":  "$root/aem-airmiles-web",
            "Repo":  "AirMilesLoyaltyInc/aem-airmiles-web",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/profile-api",
            "Path":  "$root/profile-api",
            "Repo":  "AirMilesLoyaltyInc/profile-api",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/auth0-login",
            "Path":  "$root/auth0-login",
            "Repo":  "AirMilesLoyaltyInc/auth0-login",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/zoo",
            "Path":  "$root/zoo",
            "Repo":  "AirMilesLoyaltyInc/zoo",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/airmiles-aem",
            "Path":  "$root/airmiles-aem",
            "Repo":  "AirMilesLoyaltyInc/airmiles-aem",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/offer-management-api",
            "Path":  "$root/offer-management-api",
            "Repo":  "AirMilesLoyaltyInc/offer-management-api",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/collector-secure-signup-token-api",
            "Path":  "$root/collector-secure-signup-token-api",
            "Repo":  "AirMilesLoyaltyInc/collector-secure-signup-token-api",
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
            "Url":  "https://github.com/AirMilesLoyaltyInc/api-gateway-external-promotion-service-api",
            "Path":  "$root/api-gateway-external-promotion-service-api",
            "Repo":  "AirMilesLoyaltyInc/api-gateway-external-promotion-service-api",
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
    ]
"@
    $data = $json | ConvertFrom-Json
    return $data[0..($numItems - 1)]
}


`

Main
