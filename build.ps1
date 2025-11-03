Remove-Item –path ./client –recurse

Invoke-WebRequest -Uri 'https://api.cloudmersive.com/barcode/docs/v1/swagger' -OutFile '.\barcode-api-swagger.json'
(Get-Content .\barcode-api-swagger.json).replace('localhost', "api.cloudmersive.com") | Set-Content .\barcode-api-swagger.json
(Get-Content .\barcode-api-swagger.json -Raw) -replace '"http"','"https"' | Set-Content .\barcode-api-swagger.json -Encoding UTF8


java -jar ./openapi-generator-cli-7.12.0.jar generate -i .\barcode-api-swagger.json -g java -o client -c packageconfig.json

Copy-Item ./client/README.md ./README.md

& mvn -f .\client\pom.xml clean package -DskipTests