param(
    [Parameter(Mandatory=$true)]
    [string]$ImageName,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "image.tar.gz",
    
    [Parameter(Mandatory=$false)]
    [switch]$Split,
    
    [Parameter(Mandatory=$false)]
    [int]$SplitSizeMB = 500
)

Write-Host "==> Docker Image Compression (Direct Stream)" -ForegroundColor Cyan
Write-Host "    Image: $ImageName" -ForegroundColor Gray
Write-Host "    Output: $OutputFile`n" -ForegroundColor Gray

# Validate image exists
$imageExists = docker images $ImageName --format "{{.Repository}}:{{.Tag}}" | Select-String -Pattern $ImageName
if (-not $imageExists) {
    Write-Host "ERROR: Image '$ImageName' not found!" -ForegroundColor Red
    exit 1
}

$imageSize = docker images $ImageName --format "{{.Size}}"
Write-Host "[1/3] Image size: $imageSize" -ForegroundColor Green

# Check for gzip (from Git for Windows)
$gzipPath = $null
$possiblePaths = @(
    "C:\Program Files\Git\usr\bin\gzip.exe",
    "C:\Program Files (x86)\Git\usr\bin\gzip.exe",
    "$env:ProgramFiles\Git\usr\bin\gzip.exe"
)

foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $gzipPath = $path
        break
    }
}

if ($gzipPath) {
    Write-Host "`n[2/3] Using Git gzip for compression..." -ForegroundColor Green
    Write-Host "    This will take 20-30 minutes. Please wait..." -ForegroundColor Yellow
    
    # Use direct piping: docker save | gzip > file
    # This is the most reliable method for large images
    try {
        $startTime = Get-Date
        & docker save $ImageName | & $gzipPath -c > $OutputFile
        $duration = (Get-Date) - $startTime
        
        if (Test-Path $OutputFile) {
            $compressedSize = (Get-Item $OutputFile).Length / 1GB
            Write-Host "`n    Success! Compressed to $([math]::Round($compressedSize, 2)) GB" -ForegroundColor Green
            Write-Host "    Duration: $([math]::Round($duration.TotalMinutes, 1)) minutes" -ForegroundColor Gray
        } else {
            Write-Host "`nERROR: Compression failed - output file not created" -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "`nERROR: Compression failed - $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "`n[2/3] Git gzip not found. Using alternative method..." -ForegroundColor Yellow
    Write-Host "    Exporting to tar first..." -ForegroundColor Cyan
    
    # Fallback: export to tar, then compress with .NET
    $tarFile = "temp-export.tar"
    
    try {
        Write-Host "    Running docker save (this may take 15-20 minutes)..." -ForegroundColor Yellow
        docker save $ImageName -o $tarFile
        
        if (-not (Test-Path $tarFile)) {
            Write-Host "ERROR: Docker save failed!" -ForegroundColor Red
            exit 1
        }
        
        $exportSize = (Get-Item $tarFile).Length / 1GB
        Write-Host "    Exported: $([math]::Round($exportSize, 2)) GB" -ForegroundColor Green
        
        Write-Host "`n    Compressing with .NET GZipStream..." -ForegroundColor Cyan
        
        $inputStream = [System.IO.File]::OpenRead($tarFile)
        $outputStream = [System.IO.File]::Create($OutputFile)
        $gzipStream = New-Object System.IO.Compression.GZipStream($outputStream, [System.IO.Compression.CompressionLevel]::Optimal)
        
        $buffer = New-Object byte[](4MB)
        $totalBytes = $inputStream.Length
        $processedBytes = 0
        $lastPercent = -1
        
        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $gzipStream.Write($buffer, 0, $bytesRead)
            $processedBytes += $bytesRead
            $percent = [math]::Floor(($processedBytes / $totalBytes) * 100)
            if ($percent -ne $lastPercent -and $percent % 10 -eq 0) {
                Write-Host "      Progress: $percent% ($([math]::Round($processedBytes/1GB, 2)) GB)" -ForegroundColor Cyan
                $lastPercent = $percent
            }
        }
        
        $gzipStream.Close()
        $outputStream.Close()
        $inputStream.Close()
        
        Remove-Item $tarFile -Force
        
        $compressedSize = (Get-Item $OutputFile).Length / 1GB
        $ratio = [math]::Round((1 - $compressedSize / $exportSize) * 100, 1)
        Write-Host "`n    Compressed: $([math]::Round($compressedSize, 2)) GB ($ratio% reduction)" -ForegroundColor Green
        
    } catch {
        Write-Host "`nERROR: $_" -ForegroundColor Red
        if (Test-Path $tarFile) { Remove-Item $tarFile -Force }
        exit 1
    }
}

# Split if requested
if ($Split) {
    Write-Host "`n[3/3] Splitting into $SplitSizeMB MB chunks..." -ForegroundColor Yellow
    
    try {
        $chunkSize = $SplitSizeMB * 1MB
        $inputStream = [System.IO.File]::OpenRead($OutputFile)
        $totalSize = $inputStream.Length
        $buffer = New-Object byte[]($chunkSize)
        $chunkIndex = 0
        
        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunkName = "$OutputFile.part{0:D3}" -f $chunkIndex
            [System.IO.File]::WriteAllBytes($chunkName, $buffer[0..($bytesRead-1)])
            
            $sizeMB = [math]::Round($bytesRead / 1MB, 2)
            $progressPct = [math]::Round(($inputStream.Position / $totalSize) * 100, 1)
            Write-Host "    Created: $chunkName ($sizeMB MB) - $progressPct% complete" -ForegroundColor Green
            $chunkIndex++
        }
        
        $inputStream.Close()
        
        Write-Host "`n    Split complete: $chunkIndex chunks created" -ForegroundColor Green
        Write-Host "    Keeping original: $OutputFile" -ForegroundColor Gray
        
        # Create load script for EC2
        $loadScript = @"
#!/bin/bash
# Reassemble and load Docker image on EC2

echo 'Reassembling $OutputFile from chunks...'
cat ${OutputFile}.part* > $OutputFile

echo 'Loading Docker image...'
docker load -i $OutputFile

echo 'Cleaning up...'
rm ${OutputFile}.part* $OutputFile

echo 'Done!'
"@
        Set-Content -Path "load-image.sh" -Value $loadScript
        
        $loadScriptPS = @"
# Reassemble and load Docker image (PowerShell version)
Write-Host 'Reassembling chunks...'
`$parts = Get-ChildItem '$OutputFile.part*' | Sort-Object Name
`$output = [System.IO.File]::Create('$OutputFile')
foreach (`$part in `$parts) {
    Write-Host "  `$(`$part.Name)"
    `$bytes = [System.IO.File]::ReadAllBytes(`$part.FullName)
    `$output.Write(`$bytes, 0, `$bytes.Length)
}
`$output.Close()
Write-Host 'Loading Docker image...'
docker load -i '$OutputFile'
"@
        Set-Content -Path "load-image.ps1" -Value $loadScriptPS
        
        Write-Host "    Created: load-image.sh (for Linux/EC2)" -ForegroundColor Green
        Write-Host "    Created: load-image.ps1 (for Windows)" -ForegroundColor Green
        
    } catch {
        Write-Host "`nERROR: Splitting failed - $_" -ForegroundColor Red
        exit 1
    }
}

# Summary
Write-Host "`n==> Complete!" -ForegroundColor Green
Write-Host "    Output: $OutputFile ($([math]::Round((Get-Item $OutputFile).Length / 1GB, 2)) GB)" -ForegroundColor Cyan

if ($Split) {
    $chunkCount = (Get-ChildItem "$OutputFile.part*").Count
    Write-Host "    Chunks: $chunkCount files" -ForegroundColor Cyan
    
    Write-Host "`n==> Next Steps:" -ForegroundColor Yellow
    Write-Host "    1. Upload to S3:" -ForegroundColor White
    Write-Host "       aws s3 cp . s3://your-bucket/gpu-image/ --recursive --exclude '*' --include '$OutputFile.part*'" -ForegroundColor Gray
    
    Write-Host "`n    2. On EC2 (us-east-1):" -ForegroundColor White
    Write-Host "       aws s3 cp s3://your-bucket/gpu-image/ . --recursive --include '$OutputFile.part*'" -ForegroundColor Gray
    Write-Host "       bash load-image.sh" -ForegroundColor Gray
    Write-Host "       docker tag $ImageName 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized" -ForegroundColor Gray
    Write-Host "       aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 401753844565.dkr.ecr.us-east-1.amazonaws.com" -ForegroundColor Gray
    Write-Host "       docker push 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized" -ForegroundColor Gray
}
