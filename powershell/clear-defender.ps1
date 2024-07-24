# Get Windows Defender preferences
$x = Get-MpPreference

if ($x.ExclusionPath -ne $NULL) {
    Write-Host("================================================")
    Write-Host("Removing the following ExclusionPath entries:")
    foreach ($i in $x.ExclusionPath) {
        Remove-MpPreference -ExclusionPath $i
        Write-Host($i)
    }
    Write-Host("================================================")
    Write-Host("Total ExclusionPath entries deleted:", $x.ExclusionPath.Count)
} else {
    Write-Host("No ExclusionPath entries present. Skipping...")
}


```
\\wsl$\Ubuntu-22
\\wsl.localhost\Ubuntu-22\home\cd\git\github\dovholuknf\edgex
\\wsl.localhost\Ubuntu-22\home\cd\git\github\dovholuknf\go-deptree
\\wsl.localhost\Ubuntu-22\home\cd\git\github\dovholuknf\openziti-scripts
\\wsl.localhost\Ubuntu-22\home\cd\git\github\external\micahparks\keyfunc
\\wsl.localhost\Ubuntu-22\home\cd\git\github\openziti\desktop-edge-win
\\wsl.localhost\Ubuntu-22\home\cd\git\github\openziti\nf\ziti
\\wsl.localhost\Ubuntu-22\home\cd\git\github\openziti\ziti-console
\\wsl.localhost\Ubuntu\mnt\wsl\dev\git\github\dovholuknf\edgex-new
\\wsl.localhost\Ubuntu\mnt\wsl\dev\git\github\dovholuknf\openziti-scripts
\\wsl.localhost\Ubuntu\mnt\wsl\dev\git\github\openziti\nf
C:\Program Files\JetBrains\Rider\r2r
C:\temp\zititv\jan26-enrollment\go
C:\Users\clint\.ziti
C:\Users\clint\AppData\Local\JetBrains\CLion2023.2
C:\Users\clint\AppData\Local\JetBrains\CLion2023.3
C:\Users\clint\AppData\Local\JetBrains\DataGrip2023.3
C:\Users\clint\AppData\Local\JetBrains\GoLand2023.3
C:\Users\clint\AppData\Local\JetBrains\GoLand2024.1
C:\Users\clint\AppData\Local\JetBrains\IntelliJIdea2023.3
C:\Users\clint\AppData\Local\JetBrains\PyCharm2023.3
C:\Users\clint\DataGripProjects\datawarehouse
C:\work
V:\work
```