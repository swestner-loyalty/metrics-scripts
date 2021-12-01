$root = "c:\temp\repos"

function Main {
    $criticalRepos = Get-BusinessCriticalRepos
    $recentRepos = Get-RecentRepos
    
    New-Item -Type Directory -Force -Path $root

    Write-DepndencyReports -repos $criticalRepos 
    Write-DepndencyReports -repos $criticalRepos 
    
    Write-Loc -repos $recentRepos -reportPrefix "recent"
    Write-Loc -repos $criticalRepos -reportPrefix "critical"    
    
    Write-JenkinsFileReport -repos $criticalRepos -reportPrefix "critical"
    Write-JenkinsFileReport -repos $recentRepos -reportPrefix "recent"
    
    Write-CommitsPerWeek -repos $criticalRepos -reportPrefix "critical"       
    Write-CommitsPerWeek -repos $recentRepos -reportPrefix "recent"    
   
}


function Write-JenkinsFileReport {
    param (        
        $repos,
        $reportPrefix
    )
    

    $summaryReport = "$root\$($reportPrefix)_summary_jenkins.txt"        
    $detailedReport = "$root\$($reportPrefix)_detailed_jenkins.txt"
    
    $f = gci -Path $repos.Path -Filter "jenkinsfile*" -recurse 

    $detailed = ($f |%{ if(($_ | gc | select-string "jenkins-shared-lib-v2")){"$($_.FullName)`r`n"}})
        
    New-Item -ItemType File -Force -Path $detailedReport -Value "$detailed"

    $summary = ($f |%{ if(($_ | gc | select-string "jenkins-shared-lib-v2")){$($_.FullName.Replace("C:\temp\repos\", "").Split("\")[0] + "`r`n")}}) | Select -Unique

    $sum = $summary.Count

    New-Item -ItemType File -Force -Path $summaryReport -Value "SUM : $sum`r`n`r`n $summary"

}

function Write-CommitsPerWeek{
    param(
        $repos,
        $reportPrefix
    )

    
    $summaryReport = "$root\$($reportPrefix)_summary_commits.csv"
        
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

function Write-DepndencyReports{
    param (
        $repos,
        $reportPrefix
    )

    $detailedReport = "$root\$($reportPrefix)_detailed_dependencies.csv"
    $summaryReport = "$root\$($reportPrefix)_summary_dependencies.csv"
    
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
function Get-BusinessCriticalRepos {
    
    $criticalRepos = gh repo list loyaltyone --limit 2000 --topic "business-critical" `
    | ConvertFrom-Csv -Delimiter "`t" -header repo,desc,status,date `
    | ForEach-Object{ [PSCustomObject]@{
         Name = $_.repo.Split('/')[1]
         Url = "https://github.com/$($_.repo)"
         Path = "$root\$($_.repo.Split('/')[1])"
         Date = $_.Date
         Repo = $_.Repo
     }}

     return $criticalRepos
}

function Get-RecentRepos{
    $recentRepos = gh repo list loyaltyone --limit 2000 `
      | ConvertFrom-Csv -Delimiter "`t" -header repo,desc,status,date | Where-Object{$_.date -gt '2020-12-31'} `
      | ForEach-Object{ [PSCustomObject]@{
          Name = $_.repo.Split('/')[1]
          Url = "https://github.com/$($_.repo)"
          Path = "$root\$($_.repo.Split('/')[1])"
          Date = $_.Date
          Repo = $_.Repo
     }}

     return $recentRepos
}

function Write-Loc {
    param (
        $repos,
        $reportPrefix
    )
       
    $detailedReport = "$root\$($reportPrefix)_detailed_results.csv"
    $summaryReport = "$root\$($reportPrefix)_summary_results.csv"
    
    New-Item -ItemType File -Force -Path $detailedReport -Value "repo,modified,files,language,blank,comment,code`r`n"
    New-Item -ItemType File -Force -Path $summaryReport -Value "repo,modified,time,loc`r`n"
    
    foreach($repo in $repos){
        git clone $repo.Url --depth=1 $repo.Path
        
        cd $repo.Path

        $details = docker run --rm -v ${PWD}:/tmp aldanial/cloc --csv --quiet -- .
        
        cd $root

        $total = $details[-1].split(",")[-1]
            
        $records = $details | Select-Object -Skip 2 | ForEach-Object{"$($repo.Name),$($repo.Date),$_"}

        Add-Content -Path $detailedReport -Value $records
        
        Add-Content -Path $summaryReport -Value "$($repo.Name),$($repo.Date),$total"     
    }
}

Main