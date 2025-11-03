Remove-Item –path ./client –recurse

Invoke-WebRequest -Uri 'https://api.cloudmersive.com/virus/docs/v1/swagger' -OutFile '.\virus-api-swagger.json'
(Get-Content .\virus-api-swagger.json).replace('localhost', "api.cloudmersive.com") | Set-Content .\virus-api-swagger.json
(Get-Content .\virus-api-swagger.json).replace('"http"', '"https"') | Set-Content .\virus-api-swagger.json




java -jar ./openapi-generator-cli-7.12.0.jar generate -i .\virus-api-swagger.json -g java -o client -c packageconfig.json

Copy-Item ./client/README.md ./README.md

& mvn -f .\client\pom.xml clean package -DskipTests