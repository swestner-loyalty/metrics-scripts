$root = "c:\temp\repos"

function _Main{
    #$d = Get-DetailedRepos

    $data = Get-DataFromGraphQL -recentRepoCutoffDateInYears 1

}

function Main {    
    while(1){
                    
        $data = Get-DataFromMainPrompt

        if($LASTEXITCODE -eq -1){
            EXIT 0
            break;
        }

        Invoke-ReportForPrompt -data $data

        if($LASTEXITCODE -eq -1){
            EXIT 0
            break;
        }
    }  
}

function Get-DataFromMainPrompt{
    
    Write-Host "Would you like to use : "
    Write-Host "1) Business critical repos"
    Write-Host "2) Most recent repos"
    Write-Host "3) All repos"
    Write-Host "4) Use mock data"
    Write-Host "5) No data needed"
    Write-Host "6) Exit"
    
    $decision = Read-Host

    $data = switch($decision){
        1 { Get-DataFromGraphQL -topic 'business-critical' ; break}        
        2 { 
            Write-Host "How many years back should we go"
            $years = Read-Host 

            Get-DataFromGraphQL -recentRepoCutoffDateInYears $years
           }
        3 { Get-DataFromGraphQL break}
        4 { Get-MockDataJson break}
        5 { }
        6 { EXIT = -1 }#no op on exit
    }

    return $data    
}

function Invoke-ReportForPrompt{
    param(
        $data
    )
    

    while(1){
        Write-Host "What would you like to run today?"

        Write-Host "1) Scorecard summary report" 
        Write-Host "2) Scorecard detailed report"       
        Write-Host "3) Ownership report"  
        Write-Host "4) Dependency report" 

        Write-Host "5) Jenkinsfile report"
        Write-Host "6) Commits per week report"
        Write-Host "7) Lines of Code report" 
        Write-Host "8) Exit"
        Write-Host "9) Help"

        $action = Read-Host

        switch($action){
            1 {Write-RepoScorecardReport -repos $data -reportName "($prefix)summary_scorecard_report.csv"; break}
            2 {Write-RepoScorecardReportDetailed -repos $data -reportName "($prefix)detailed_scorecard_report.csv";break}
            3 {Write-OwnershipReport -repos $data -reportName "($prefix)ownership_report.csv"; break}
            4 {Write-DependencyReports -repos $data -reportName "($prefix)dependency_report.csv" ; break}
            5 {Write-JenkinsCsvReport -repos $data -reportName "jenkinsfile_report.txt"; break}
            6 {Write-CommitsPerWeek -repos $data -reportName "commits_per_week_report.csv"; break}
            7 {Write-Loc -repos $data -reportName "loc_report.csv"; break}
            8 {EXIT -1; break}
            9 {Write-Host "coming soon"}
        }
    }
}

function Write-OwnershipReport{
    param($reportName)

    
    $report = "$root\$($reportName)"        
    $header = "Name,Team,Url,Last Push,Last Update,Archived,Disabled,Contributors,Languages`r`n"

    New-Item -ItemType File -Force -Path $report -Value $header

    $content = $repos | %{
        $topics = $_.Topics -join ";"
        "{0},{1},{2},{3},{4},{5},{6},{7},{8}" -f $_.Name, $topics, $_.Url,$_.Pushed, $_.Updated, $_.Archived, $_.Disabled, $_.Contributors, $_.Languages
    }    

    Add-Content -Path $report -Value $content
   
    Write-Host (gc $report)
}

function Write-RepoScorecardReport{
    param (        
        $repos,
        $reportName
    )

    $summaryReport = "$root\$($reportName)"        
    $summaryHeader = "repo,score,topics,notes`r`n"

    New-Item -ItemType File -Force -Path $summaryReport -Value $summaryHeader

    $repos |%{
        Add-RepoLocally -Repo $_
        $summary = Get-RepoHealthScoreSummary -repo $_
        Add-Content -Path $summaryReport -Value $summary
    }

    Write-Host (gc $summaryReport)
     
}

function Get-RepoHealthScoreSummary{
    param(        
       $repo
   )
   
   $format = "{0},{1},{2},{3}"
   
   $scorecard = ((gci -Path $repo.Path) | where {$_.Name -match '(scorecard|level\d)\.md'}).FullName
   $topics = $repo.Topics -join ';'
   
   if(!$scorecard){
       return $format -f $repo.Name, 0, $topics, 'no scorecard'
   }
   
   $content = gc $scorecard

   $total =  ($content -match '-\s*\[').Count
   $completed = ($content -match '-\s*\[\s*[xX]\s*\]').Count
   
   $score = ($completed / $total) * 100

   return $format -f $repo.Name, $score, $topics, ''
}
function Write-RepoScorecardReportDetailed{
    param(
        $repos,
        $reportName
    )

    
    $details = $repos |%{
        Add-RepoLocally -Repo $_ | Out-Null
        Get-RepoHealthScoreDetailed -repo $_
        
    }
    
    $headers = @()

    $report = ""

    #write the headers
    foreach($detail in $details){
        foreach($key in $detail.Keys){
            if(!$headers.Contains($key)){
                $headers += ($key)
                $report += "$($key.subString(0, [System.Math]::Min(100, $key.Length))),"
            }           
        }
    }
    
    $report = $report.TrimEnd(',')
    $report += "`r`n"
        
    #write the details
    foreach($detail in $details){
        foreach($column in $headers){            
            if($detail.Contains($column)){
                $report += "$($detail[$column].ToLower())"
            }          
            $report += ","
        }

        $report = $report.TrimEnd(',')
        $report += "`r`n"       
    }

    $detailedReport = "$root\$($reportName)"        
    New-Item -ItemType File -Force -Path $detailedReport -Value $report

    Write-Host (gc $detailedReport)
    
}
function Get-RepoHealthScoreDetailed{
    param(        
       $repo
   )
   
   $scorecard = ((gci -Path $repo.Path) | where {$_.Name -match '(scorecard|level\d)\.md'}).FullName
   $topics = $repo.Topics -join ';'
   
   if(!$scorecard){
       return @{Repo = $repo.Name; Topics=$topics; Notes="No scorecard"}
   }
   
   $content = gc $scorecard

   $deets = Get-RepoScoreDetails -content $content

   $deets.Add("Repo", $repo.Name)
   $deets.Add("Topics", $repo.Topics)
   $deets.Add("Notes", "")

   return $deets
}

function Get-RepoScoreDetails{
    param(
        $content
    )

    [regex]$expression = "\[(?<score>.*)\]\s*(?<desc>.*)"

    $scores = @{}

    foreach ($line in $content){        
        $match = $expression.match($line)

        if($match.Success){
            $scores.Add($match.Groups['desc'].Value.Trim(), $match.Groups['score'].Value.Trim())
        }
    }
    return $scores

}


function Write-JenkinsCSVReport {
    param (        
        $repos,
        $reportName
    )
    
    $summaryReport = "$root\summary_$($reportName)"        
    $detailedReport = "$root\detailed_$($reportName)"

    $summary = "Repo, Topics`r`n"
    $detailed = "Repo,Path,Version,Topics`r`n"

    foreach($repo in $repos){
        $repo | Add-RepoLocally
        $files = Get-ChildItem -Path $repo.Path -Filter "jenkinsfile*" -recurse
        $sum = 0 

        foreach($file in $files){
            $version = $file | Get-Content | Select-String "jenkins-shared-lib-v*"

            if(!$version){
                $version = 'No SDK'
            }else{
                $sum += 1
            }

            $detailed += "$($repo.Name), $($file.FullName), `"$version`", $($repo.Topics) `r`n"     
        }

        $summary = "$($repo.Name),$sum/$($files.Count) `r`n"
    }
    New-Item -ItemType File -Force -Path $detailedReport -Value "$detailed"
    New-Item -ItemType File -Force -Path $summaryReport -Value $summary

}

function Write-JenkinsFileReport {
    param (        
        $repos,
        $reportName
    )
    
    $repos |% { $_ | Add-RepoLocally}

    $summaryReport = "$root\summary_$($reportName)"        
    $detailedReport = "$root\detailed_$($reportName)"
    
    $f = gci -Path $repos.Path -Filter "jenkinsfile*" -recurse 

    
    $detailed = ($f |%{ if(($_ | gc | select-string "jenkins-shared-lib-v2")){"$($_.FullName), `"$($_.Topics)`"`r`n"}})
        
    New-Item -ItemType File -Force -Path $detailedReport -Value "$detailed"

    $summary = ($f |%{ if(($_ | gc | select-string "jenkins-shared-lib-v2")){$($_.FullName.Replace("C:\temp\repos\", "").Split("\")[0] + ", `"$($_.Topics)`"`r`n")}}) | Select -Unique

    $sum = $summary.Count
    $total = $repos.Count

    New-Item -ItemType File -Force -Path $summaryReport -Value "SUM : $sum/$total`r`n`r`n $summary"

}

function Write-CommitsPerWeek{
    param(
        $repos,
        $reportName
    )

    
    $summaryReport = "$root\$($reportName)"
        
    New-Item -ItemType File -Force -Path $summaryReport -Value "repo,average`r`n"

    $summary = $repos |%{
        Get-CommitsPerWeekForRepo -repo $_
    }

    Add-Content -Path $summaryReport -Value $summary

}
function Get-CommitsPerWeekForRepo{
     param(        
        $repo
    )

    cd $repo.Path

    git fetch --unshallow
    $commits = git --no-pager log --pretty=format:"%h`t%cn`t%cd" --date=iso-strict | convertfrom-csv -Delimiter "`t" -header hash,committer,date,week
    $commits |%{$_.week = $(Get-Culture).Calendar.GetWeekOfYear(([DateTime]$_.Date),[System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)}
    $commitsThisYear = $commits |?{([DateTime]$_.Date) -gt (Get-Date '2020-12-31')}

    $currentWeek = $(Get-Culture).Calendar.GetWeekOfYear((Get-Date),[System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)

    $buckets = @{}

    1..$currentWeek |%{       
        $week = $_
        $count = @($commitsThisYear |?{ $_.Week -eq $week }).Count
        $buckets.Add($week, $count)
    }

    $average = ($buckets.Values | Measure-Object -Average).Average

    cd $root

    return "$repo.Name,$average`r`n" 
}

function Write-DependencyReports{
    param (
        $repos,
        $reportName
    )

    $detailedReport = "$root\$($reportName)_detailed.csv"
    $summaryReport = "$root\$($reportName)_summary.csv"
    
    New-Item -ItemType File -Force -Path $detailedReport -Value "repo,ref`r`n"
    New-Item -ItemType File -Force -Path $summaryReport -Value "repo,count`r`n"
    
    $prsAll = foreach($repo in $repos){
        $prs = gh pr list --repo $($repo.Repo) `
           | ConvertFrom-Csv -Delimiter "`t" -Header Num,Desc,Ref `
           |?{ $_.Ref -Match "dependabot.*" }

        $prs |%{
            Add-Content -Path $detailedReport -Value "$($repo.Name),$($_.Ref)"
        }
        
        Add-Content -Path $summaryReport -Value "$($repo.Name),$($prs.Count)"  
        
        $prs
       }

    Add-Content -Path $summaryReport -Value "total,$($prsAll.Count)"
       
}


function Add-RepoLocally{
    param(
        [Parameter(position=0, ValueFromPipeline)]
        $repo
    )

    $originalPath = (gi .).FullName

    if(!(Test-Path $repo.Path)){
        git clone $repo.Url --depth=1 $repo.Path                
    }

    cd $repo.Path
    git config --global --add safe.directory $repo.Path 
    $currentBranch = git branch --show-current
    $defaultBranch = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
    
    if($currentBranch -ne $defaultBranch){
        git stash       
    }

    #git reset --hard origin/$defaultBranch
    #git pull $defaultBranch

    git fetch origin $defaultBranch
    git merge -s recursive -X theirs origin/$defaultBranch


    cd $originalPath
}



function Get-DataFromGraphQL{
    param(
    [string] $organization = "AirMilesLoyaltyInc",
    [decimal]$recentRepoCutoffDateInYears = 0,
    [string]$topic = ""
    )

    $filter = @("org:$organization")

    if($recentRepoCutoffDateInYears){
        $cutoff = (get-date).AddYears($recentRepoCutoffDateInYears *-1).ToString('yyyy-MM-ddTHH:mm:ss')
        $filter +=  "pushed:>$cutoff"
    }

    if($topic){
        $filter += "topic:$topic"
    }

    $graph =  Join-Path -Path $PSScriptRoot -ChildPath "metrics.graphql"

    $results = gh api graphql --paginate -F query="@$graph" -F filter=$($filter -Join " ") `
    | gh merge-json `
    | ConvertFrom-Json 

    $nodes = $results.data.search.nodes

    $repos = $nodes | ForEach-Object{      
        [PSCustomObject]@{
            Name = $_.name
            Url = $_.url
            Path = "$root\$($_.name)"
            Date = $_.pushedAt
            Pushed = $_.pushedAt
            Updated = $_.updatedAt
            Repo = $_.nameWithOwner
            Topics = $_.repositoryTopics.edges.node.topic.name
            Archived = $_.isArchived
            Disabled = $_.isDisabled
            #Contributors = $_.contributors
            Languages = $_.languages.nodes.names
        }    
    }
    return $repos
}


function Get-DetailedRepos{
    param(
        $orgName = "LoyaltyOne"
    )

    $i = 1
    $repos = gh api "orgs/$orgName/repos?page=$i&per_page=100" | ConvertFrom-Json
    $buffer = $repos
    while($buffer){
        $i = $i + 1
        $buffer = gh api "orgs/$orgName/repos?page=$i&per_page=100" | ConvertFrom-Json       
        $repos += $buffer
    } 

   $formatted =  $repos | ForEach-Object{   
        [PSCustomObject]@{
            Name = $_.name
            Url = $_.url
            Path = "$root\$($_.name)"
            Date = $_.pushed_at
            Pushed = $_.pushed_at
            Updated = $_.updated_at
            Repo = $_.full_name
            Topics = $_.topics
            Archived = $_.archived
            Disabled = $_.disabled
            Contributors = $((Get-Contributors -repoName $_.name) -Join ";")
            Languages = $(Get-Languages -repoName $_.name )
        }

    }

    $formatted

} 


function Write-Loc {
    param (
        $repos,
        $reportName
    )
       
    $detailedReport = "$root\detailed_$($reportName)"
    $summaryReport = "$root\summary_$($reportName)"
    
    New-Item -ItemType File -Force -Path $detailedReport -Value "repo,modified,files,language,blank,comment,code`r`n"
    New-Item -ItemType File -Force -Path $summaryReport -Value "repo,modified,time,loc`r`n"
    
    foreach($repo in $repos){
        
        $repo | Add-RepoLocally
        
        cd $repo.Path

        $details = docker run --rm -v ${PWD}:/tmp aldanial/cloc --csv --quiet -- .
        
        cd $root

        $total = $details[-1].split(",")[-1]
            
        $records = $details | Select-Object -Skip 2 | ForEach-Object{"$($repo.Name),$($repo.Date),$_"}

        Add-Content -Path $detailedReport -Value $records
        
        Add-Content -Path $summaryReport -Value "$($repo.Name),$($repo.Date),$total"     
    }
}


function Get-MockDataJson{
    [CmdletBinding()]
    param(
        [parameter(Position=0)]
        [ValidateRange(1,10)]
        [int]
        $numItems = 10
    )
    


       $data = ConvertFrom-Json '[{
            "Name":  "transaction-summary-consumer",
            "Url":  "https://github.com/LoyaltyOne/transaction-summary-consumer",
            "Path":  "c:\\temp\\repos\\transaction-summary-consumer",
            "Date":  "2022-11-22T18:05:28Z",
            "Repo":  "LoyaltyOne/transaction-summary-consumer",
            "Topics":  "teamfusion"
        },
        {
            "Name":  "promotion-service",
            "Url":  "https://github.com/LoyaltyOne/promotion-service",
            "Path":  "c:\\temp\\repos\\promotion-service",
            "Date":  "2022-11-22T16:32:19Z",
            "Repo":  "LoyaltyOne/promotion-service",
            "Topics":  "team-things"
        },
        {
            "Name":  "aem-airmiles-web",
            "Url":  "https://github.com/LoyaltyOne/aem-airmiles-web",
            "Path":  "c:\\temp\\repos\\aem-airmiles-web",
            "Date":  "2022-11-22T14:19:09Z",
            "Repo":  "LoyaltyOne/aem-airmiles-web",
            "Topics":  [
                           "team-goat",
                           "team-atsops"
                       ]
        },
        {
            "Name":  "airmiles-aem",
            "Url":  "https://github.com/LoyaltyOne/airmiles-aem",
            "Path":  "c:\\temp\\repos\\airmiles-aem",
            "Date":  "2022-11-22T18:44:44Z",
            "Repo":  "LoyaltyOne/airmiles-aem",
            "Topics":  "team-goat"
        },
        {
            "Name":  "airmiles-web-bff",
            "Url":  "https://github.com/LoyaltyOne/airmiles-web-bff",
            "Path":  "c:\\temp\\repos\\airmiles-web-bff",
            "Date":  "2022-11-21T18:05:47Z",
            "Repo":  "LoyaltyOne/airmiles-web-bff",
            "Topics":  "team-goat"
        },
        {
            "Name":  "auth0-pages",
            "Url":  "https://github.com/LoyaltyOne/auth0-pages",
            "Path":  "c:\\temp\\repos\\auth0-pages",
            "Date":  "2022-11-21T16:31:22Z",
            "Repo":  "LoyaltyOne/auth0-pages",
            "Topics":  "team-goat"
        },
        {
            "Name":  "rtc-amcash-infra",
            "Url":  "https://github.com/LoyaltyOne/rtc-amcash-infra",
            "Path":  "c:\\temp\\repos\\rtc-amcash-infra",
            "Date":  "2022-11-21T15:47:43Z",
            "Repo":  "LoyaltyOne/rtc-amcash-infra",
            "Topics":  "mobsrus"
        },
        {
            "Name":  "zoo",
            "Url":  "https://github.com/LoyaltyOne/zoo",
            "Path":  "c:\\temp\\repos\\zoo",
            "Date":  "2022-11-22T16:20:15Z",
            "Repo":  "LoyaltyOne/zoo",
            "Topics":  "team-goat"
        },
        {
            "Name":  "api-gateway-external-offer-state-api",
            "Url":  "https://github.com/LoyaltyOne/api-gateway-external-offer-state-api",
            "Path":  "c:\\temp\\repos\\api-gateway-external-offer-state-api",
            "Date":  "2022-11-18T18:36:13Z",
            "Repo":  "LoyaltyOne/api-gateway-external-offer-state-api",
            "Topics":  "team-things"
        },
        {
            "Name":  "notification-service-producer",
            "Url":  "https://github.com/LoyaltyOne/notification-service-producer",
            "Path":  "c:\\temp\\repos\\notification-service-producer",
            "Date":  "2022-11-18T18:08:43Z",
            "Repo":  "LoyaltyOne/notification-service-producer",
            "Topics":  [
                           "avengers",
                           "notification-service"
                       ]
        }
    ]'

    return $data[0..($numItems - 1)]
}

Main