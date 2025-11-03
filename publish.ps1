$env:GPGEXE = "C:\Program Files (x86)\GnuPG\bin\gpg.exe"
$env:GNUPGHOME = "C:\Users\adm101\AppData\Roaming\gnupg"

$KEY="59609C262707C907AFABFF9D5F24E05A6AFEDD4C"

& mvn -f .\client\pom.xml -B -Psign-artifacts -DskipTests "-Dgpg.keyname=$KEY" "-Dgpg.executable=$env:GPGEXE" "-Dgpg.homedir=$env:GNUPGHOME" -e clean verify org.sonatype.central:central-publishing-maven-plugin:0.9.0:publish