# Save and Compress Docker Image for Upload
# This reduces the image size by exporting, compressing, and optionally splitting

param(
    [string]$ImageName = "photosynth-full:gpu-optimized",
    [string]$OutputFile = "gpu-image.tar.gz",
    [int]$SplitSizeMB = 500,  # Split into 500MB chunks
    [switch]$Split
)

Write-Host "==> Docker Image Compression Script" -ForegroundColor Cyan
Write-Host "    Image: $ImageName" -ForegroundColor Gray
Write-Host "    Output: $OutputFile" -ForegroundColor Gray

# Step 1: Export image to tar
Write-Host "`n[1/3] Exporting Docker image..." -ForegroundColor Yellow
docker save $ImageName -o temp-image.tar
if ($LASTEXITCODE -ne 0) { throw "Export failed" }
$origSize = (Get-Item temp-image.tar).Length / 1GB
Write-Host "    Exported: $([math]::Round($origSize, 2)) GB" -ForegroundColor Gray

# Step 2: Compress with gzip
Write-Host "`n[2/3] Compressing with gzip..." -ForegroundColor Yellow
if (Get-Command pigz -ErrorAction SilentlyContinue) {
    # Use parallel gzip if available (faster)
    pigz -9 temp-image.tar -c > $OutputFile
} else {
    # Use 7-Zip if available (better compression)
    if (Get-Command 7z -ErrorAction SilentlyContinue) {
        7z a -tgzip -mx=9 $OutputFile temp-image.tar
    } else {
        # Fallback to PowerShell compression
        Compress-Archive -Path temp-image.tar -DestinationPath ($OutputFile -replace '\.gz$', '.zip') -CompressionLevel Optimal
        $OutputFile = $OutputFile -replace '\.tar\.gz$', '.zip'
        Write-Host "    Note: Using ZIP format (install 7-Zip for better compression)" -ForegroundColor Yellow
    }
}

Remove-Item temp-image.tar -Force
$compressedSize = (Get-Item $OutputFile).Length / 1GB
$ratio = [math]::Round((1 - $compressedSize / $origSize) * 100, 1)
Write-Host "    Compressed: $([math]::Round($compressedSize, 2)) GB ($ratio% reduction)" -ForegroundColor Green

# Step 3: Split if requested
if ($Split) {
    Write-Host "`n[3/3] Splitting into $SplitSizeMB MB chunks..." -ForegroundColor Yellow
    $chunkSize = $SplitSizeMB * 1MB
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
    
    $stream = [System.IO.File]::OpenRead($OutputFile)
    $buffer = New-Object byte[] $chunkSize
    $chunkIndex = 0
    
    while (($bytesRead = $stream.Read($buffer, 0, $chunkSize)) -gt 0) {
        $chunkFile = "${baseName}.part$chunkIndex"
        [System.IO.File]::WriteAllBytes($chunkFile, $buffer[0..($bytesRead-1)])
        Write-Host "    Created: $chunkFile ($([math]::Round($bytesRead/1MB, 1)) MB)" -ForegroundColor Gray
        $chunkIndex++
    }
    
    $stream.Close()
    Write-Host "    Split into $chunkIndex chunks" -ForegroundColor Green
    
    # Create reassembly script
    @"
# Reassemble and load Docker image
# Usage: .\load-image.ps1

Write-Host "Reassembling image chunks..." -ForegroundColor Yellow
Get-ChildItem ${baseName}.part* | Sort-Object Name | ForEach-Object {
    Get-Content `$_.FullName -Raw -Encoding Byte | Add-Content -Path "$OutputFile" -Encoding Byte
}

Write-Host "Loading into Docker..." -ForegroundColor Yellow
docker load -i $OutputFile

Write-Host "Cleaning up..." -ForegroundColor Yellow
Remove-Item ${baseName}.part* -Force
Remove-Item $OutputFile -Force

Write-Host "Done! Image loaded: $ImageName" -ForegroundColor Green
"@ | Out-File -FilePath "load-image.ps1" -Encoding UTF8
    
    Write-Host "    Created: load-image.ps1" -ForegroundColor Gray
}

Write-Host "`n==> Summary" -ForegroundColor Cyan
Write-Host "    Original: $([math]::Round($origSize, 2)) GB" -ForegroundColor Gray
Write-Host "    Compressed: $([math]::Round($compressedSize, 2)) GB" -ForegroundColor Gray
Write-Host "    Reduction: $ratio%" -ForegroundColor Green

if ($Split) {
    Write-Host "`n    Upload chunks to S3:" -ForegroundColor Cyan
    Write-Host "    aws s3 cp . s3://your-bucket/ --recursive --include '${baseName}.part*'" -ForegroundColor Gray
    Write-Host "`n    Download and load on EC2:" -ForegroundColor Cyan
    Write-Host "    aws s3 cp s3://your-bucket/ . --recursive --include '${baseName}.part*'" -ForegroundColor Gray
    Write-Host "    .\load-image.ps1" -ForegroundColor Gray
} else {
    Write-Host "`n    Upload to S3:" -ForegroundColor Cyan
    Write-Host "    aws s3 cp $OutputFile s3://your-bucket/" -ForegroundColor Gray
    Write-Host "`n    Load on EC2:" -ForegroundColor Cyan
    Write-Host "    docker load -i $OutputFile" -ForegroundColor Gray
}
