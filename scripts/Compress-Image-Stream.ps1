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

Write-Host "==> Docker Image Compression Script (Streaming)" -ForegroundColor Cyan
Write-Host "    Image: $ImageName" -ForegroundColor Gray
Write-Host "    Output: $OutputFile`n" -ForegroundColor Gray

# Validate image exists
$imageExists = docker images $ImageName --format "{{.Repository}}:{{.Tag}}" | Select-String -Pattern $ImageName
if (-not $imageExists) {
    Write-Host "ERROR: Image '$ImageName' not found!" -ForegroundColor Red
    exit 1
}

# Get image size
$imageSize = docker images $ImageName --format "{{.Size}}"
Write-Host "[1/2] Image size: $imageSize" -ForegroundColor Green

# Step 1: Export and compress using .NET streams (no file size limits)
Write-Host "`n[2/2] Exporting and compressing (streaming, may take 20-30 min)..." -ForegroundColor Yellow

try {
    # Start docker save process
    $dockerProcess = Start-Process -FilePath "docker" -ArgumentList "save",$ImageName -NoNewWindow -PassThru -RedirectStandardOutput "temp-stream.tar"
    
    Write-Host "    Waiting for docker export..." -ForegroundColor Cyan
    $dockerProcess.WaitForExit()
    
    if ($dockerProcess.ExitCode -ne 0) {
        Write-Host "ERROR: Docker save failed!" -ForegroundColor Red
        exit 1
    }
    
    $exportSize = (Get-Item "temp-stream.tar").Length / 1GB
    Write-Host "    Exported: $([math]::Round($exportSize, 2)) GB" -ForegroundColor Green
    
    Write-Host "    Compressing with gzip..." -ForegroundColor Cyan
    
    # Use .NET GZipStream for compression (handles large files)
    $inputStream = [System.IO.File]::OpenRead("temp-stream.tar")
    $outputStream = [System.IO.File]::Create($OutputFile)
    $gzipStream = New-Object System.IO.Compression.GZipStream($outputStream, [System.IO.Compression.CompressionLevel]::Optimal)
    
    $buffer = New-Object byte[](1MB)
    $totalBytes = $inputStream.Length
    $processedBytes = 0
    $lastPercent = -1
    
    while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $gzipStream.Write($buffer, 0, $bytesRead)
        $processedBytes += $bytesRead
        $percent = [math]::Floor(($processedBytes / $totalBytes) * 100)
        if ($percent -ne $lastPercent -and $percent % 5 -eq 0) {
            Write-Host "      Progress: $percent% ($([math]::Round($processedBytes/1GB, 2)) GB)" -ForegroundColor Cyan
            $lastPercent = $percent
        }
    }
    
    $gzipStream.Close()
    $outputStream.Close()
    $inputStream.Close()
    
    # Clean up temp file
    Remove-Item "temp-stream.tar" -Force
    
    $compressedSize = (Get-Item $OutputFile).Length / 1GB
    $ratio = [math]::Round((1 - $compressedSize / $exportSize) * 100, 1)
    Write-Host "`n    Compressed: $([math]::Round($compressedSize, 2)) GB ($ratio% reduction)" -ForegroundColor Green
    
} catch {
    Write-Host "ERROR: Compression failed - $_" -ForegroundColor Red
    if (Test-Path "temp-stream.tar") { Remove-Item "temp-stream.tar" -Force }
    exit 1
}

# Step 2: Split if requested
if ($Split) {
    Write-Host "`n[3/3] Splitting into $SplitSizeMB MB chunks..." -ForegroundColor Yellow
    
    try {
        $chunkSize = $SplitSizeMB * 1MB
        $inputStream = [System.IO.File]::OpenRead($OutputFile)
        $buffer = New-Object byte[]($chunkSize)
        $chunkIndex = 0
        
        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunkName = "$OutputFile.part{0:D3}" -f $chunkIndex
            [System.IO.File]::WriteAllBytes($chunkName, $buffer[0..($bytesRead-1)])
            Write-Host "    Created: $chunkName ($([math]::Round($bytesRead/1MB, 2)) MB)" -ForegroundColor Green
            $chunkIndex++
        }
        
        $inputStream.Close()
        
        Write-Host "`n    Split into $chunkIndex chunks" -ForegroundColor Green
        Write-Host "    Original compressed file kept: $OutputFile" -ForegroundColor Gray
        
        # Create reassembly script
        $loadScript = @"
# Reassemble and load Docker image
Write-Host 'Reassembling chunks...'
`$parts = Get-ChildItem '$OutputFile.part*' | Sort-Object Name
`$output = [System.IO.File]::Create('$OutputFile')
foreach (`$part in `$parts) {
    Write-Host "  Adding `$(`$part.Name)..."
    `$bytes = [System.IO.File]::ReadAllBytes(`$part.FullName)
    `$output.Write(`$bytes, 0, `$bytes.Length)
}
`$output.Close()
Write-Host 'Loading Docker image...'
docker load -i '$OutputFile'
"@
        Set-Content -Path "load-image.ps1" -Value $loadScript
        Write-Host "    Created: load-image.ps1" -ForegroundColor Green
        
    } catch {
        Write-Host "ERROR: Splitting failed - $_" -ForegroundColor Red
        exit 1
    }
}

# Summary
Write-Host "`n==> Complete!" -ForegroundColor Green
Write-Host "    Compressed file: $OutputFile" -ForegroundColor Cyan

if ($Split) {
    Write-Host "`n    Upload chunks to S3:" -ForegroundColor Yellow
    Write-Host "    aws s3 cp . s3://your-bucket/path/ --recursive --include '$OutputFile.part*'" -ForegroundColor Gray
    Write-Host "`n    Download and load on EC2:" -ForegroundColor Yellow
    Write-Host "    aws s3 cp s3://your-bucket/path/ . --recursive --include '$OutputFile.part*'" -ForegroundColor Gray
    Write-Host "    powershell -File load-image.ps1" -ForegroundColor Gray
}
