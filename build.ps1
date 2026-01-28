$ErrorActionPreference = "Stop"

# Always operate relative to this script's directory (NOT the caller's cwd)
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

Push-Location $root
try {
  # ----------------------------------------------------------------------
  # Force TLS 1.2 for Invoke-WebRequest (Windows PowerShell / older .NET defaults)
  # ----------------------------------------------------------------------
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    # fallback constant for TLS 1.2 on older frameworks
    [Net.ServicePointManager]::SecurityProtocol = 3072
  }

  function Write-Utf8NoBom {
    param(
      [Parameter(Mandatory=$true)][string]$Path,
      [Parameter(Mandatory=$true)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
  }

  function Read-TextFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)  # auto-detects encoding and strips UTF-8 BOM if present
  }

  function Remove-Utf8BomInFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      [System.IO.File]::WriteAllBytes($Path, $bytes[3..($bytes.Length-1)])
    }
  }

  # ----------------------------------------------------------------------
  # Paths (absolute, based on script dir)
  # ----------------------------------------------------------------------
  $clientDir      = Join-Path $root "client"
  $swaggerPath    = Join-Path $root "virus-api-swagger.json"
  $openapiJar     = Join-Path $root "openapi-generator-cli-7.12.0.jar"
  $packageConfig  = Join-Path $root "packageconfig.json"

  $patchRoot          = Join-Path $root "patches"
  $patchChunkedMethod = Join-Path $patchRoot "ApiClient.enableChunkedTransfer.snippet.java"

  foreach ($p in @($openapiJar, $packageConfig, $patchChunkedMethod)) {
    if (!(Test-Path $p)) { throw "Missing required file: $p" }
  }

  # ----------------------------------------------------------------------
  # Clean
  # ----------------------------------------------------------------------
  if (Test-Path $clientDir) {
    Remove-Item -Path $clientDir -Recurse -Force
  }

  # ----------------------------------------------------------------------
  # Download swagger (TLS 1.2)
  # ----------------------------------------------------------------------
  Write-Host "Downloading swagger -> $swaggerPath"

  $iwrParams = @{
    Uri         = 'https://api.cloudmersive.com/virus/docs/v1/swagger'
    OutFile     = $swaggerPath
    ErrorAction = 'Stop'
  }

  # Optional compatibility switches (only if supported)
  $iwrCmd = Get-Command Invoke-WebRequest
  if ($iwrCmd.Parameters.ContainsKey('UseBasicParsing')) { $iwrParams['UseBasicParsing'] = $true }
  if ($iwrCmd.Parameters.ContainsKey('SslProtocol'))     { $iwrParams['SslProtocol'] = 'Tls12' }

  Invoke-WebRequest @iwrParams

  if (!(Test-Path $swaggerPath)) {
    throw "Swagger download did not create expected file: $swaggerPath (PWD: $(Get-Location))"
  }

  # ----------------------------------------------------------------------
  # Patch swagger host + scheme (write no BOM)
  # ----------------------------------------------------------------------
  $swaggerJson = Read-TextFile $swaggerPath
  $swaggerJson = $swaggerJson.Replace('localhost', 'api.cloudmersive.com').Replace('"http"', '"https"')
  Write-Utf8NoBom -Path $swaggerPath -Content $swaggerJson

  # ----------------------------------------------------------------------
  # Generate Java client (native library = java.net.http.HttpClient)
  # ----------------------------------------------------------------------
  Write-Host "Generating client -> $clientDir"
  & java -jar $openapiJar generate `
    -i $swaggerPath `
    -g java `
    --library native `
    -o $clientDir `
    -c $packageConfig

  # ----------------------------------------------------------------------
  # Patch ApiClient.java: add enableChunkedTransfer() helper method
  # ----------------------------------------------------------------------
  $apiClientPath = Join-Path $clientDir "src\main\java\org\openapitools\client\ApiClient.java"
  $apiClientContent = Read-TextFile $apiClientPath

  if ($apiClientContent -notmatch '\benableChunkedTransfer\s*\(') {
    $chunkedSnippet = Read-TextFile $patchChunkedMethod

    $lastBrace = $apiClientContent.LastIndexOf("}")
    if ($lastBrace -lt 0) { throw "Could not find class closing brace in ApiClient.java" }

    $apiClientContent = $apiClientContent.Insert($lastBrace, "`r`n" + $chunkedSnippet + "`r`n")
  }

  Write-Utf8NoBom -Path $apiClientPath -Content $apiClientContent

  # ----------------------------------------------------------------------
  # Patch API classes: make the Pipe-based (chunked) multipart body
  # publisher conditional on ApiClient.isChunkedTransferEnabled().
  #
  # Generated code has:
  #   if (hasFiles) {           // Pipe -> always chunked (unknown length)
  #   } else {                  // ByteArrayOutputStream -> buffered
  #   }
  #
  # We change it to:
  #   if (ApiClient.isChunkedTransferEnabled()) {  // Pipe -> chunked
  #   } else {                                     // buffer everything -> known Content-Length
  #   }
  #
  # The else branch already buffers via ByteArrayOutputStream + entity.writeTo(),
  # which works for both file and non-file multipart bodies (the entity is built
  # by MultipartEntityBuilder before the if/else).  We also swap
  # ofInputStream(() -> new ByteArrayInputStream(...)) to ofByteArray(...) so that
  # java.net.http sends a proper Content-Length header.
  # ----------------------------------------------------------------------
  $apiDir = Join-Path $clientDir "src\main\java\org\openapitools\client\api"
  $apiFiles = Get-ChildItem -Path $apiDir -Filter '*.java' -Recurse

  foreach ($file in $apiFiles) {
    $content = Read-TextFile $file.FullName
    $changed = $false

    # (1) Replace "if (hasFiles)" with "if (ApiClient.isChunkedTransferEnabled())"
    if ($content -match '\bif\s*\(\s*hasFiles\s*\)') {
      $content = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        '\bif\s*\(\s*hasFiles\s*\)',
        'if (ApiClient.isChunkedTransferEnabled())'
      )
      $changed = $true
    }

    # (2) Replace ofInputStream(() -> new ByteArrayInputStream(...)) with ofByteArray(...)
    #     in the else (buffered) branch so a known Content-Length is sent.
    $ofInputStreamPattern = 'HttpRequest\.BodyPublishers\s*\n?\s*\.ofInputStream\(\(\)\s*->\s*new\s+ByteArrayInputStream\((\w+)\.toByteArray\(\)\)\)'
    if ($content -match $ofInputStreamPattern) {
      $content = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        $ofInputStreamPattern,
        'HttpRequest.BodyPublishers.ofByteArray($1.toByteArray())'
      )
      $changed = $true
    }

    if ($changed) {
      Write-Host "Patched multipart body publisher in $($file.Name)"
      Write-Utf8NoBom -Path $file.FullName -Content $content
    }
  }

  # Safety net: strip UTF-8 BOM from ALL generated Java files
  Get-ChildItem -Path (Join-Path $clientDir "src\main\java") -Recurse -Filter '*.java' |
    ForEach-Object { Remove-Utf8BomInFile -Path $_.FullName }

  # Copy README
  Copy-Item -Path (Join-Path $clientDir "README.md") -Destination (Join-Path $root "README.md") -Force

  # Build
  & mvn -f (Join-Path $clientDir "pom.xml") clean package -DskipTests

} finally {
  Pop-Location
}
