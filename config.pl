#$c{Domain}= 'uk.xensource.com';
$c{Domain}= 'cam.xci-test.com';
$c{TestHostDomain}= 'cam.xci-test.com';

$c{NetNameservers}= '10.80.248.2 10.80.16.28 10.80.16.67';
$c{NetNetmask}= '255.255.254.0';
$c{NetGateway}= '10.80.249.254';

$c{WebspaceFile}= '/export/home/osstest/public_html/';
$c{WebspaceUrl}= "http://woking.$c{Domain}/~osstest/";
$c{WebspaceCommon}= 'osstest/';
$c{WebspaceLog}= '/var/log/apache2/access.log';

$c{Stash}= '/home/xc_osstest/stash';
$c{Images}= '/home/xc_osstest/images';

$c{Tftp}= '/tftpboot/pxe';

#$c{Baud}= 38400;
$c{Baud}= 115200;
$c{PxeDiBase}= 'debian-installer';

$c{Suite}= 'lenny';
$c{GuestSuite}= 'lenny';
$c{HostDiskBoot}=   '300'; #Mby
$c{HostDiskRoot}= '30000'; #Mby
$c{HostDiskSwap}=  '2000'; #Mby

$c{DebianMirrorHost}= 'debian.uk.xensource.com';
$c{DebianMirrorSubpath}= 'debian';

$c{TestingLib}= '.';

$c{Preseed}= <<END;
d-i clock-setup/ntp-server string ntp.uk.xensource.com
END

$c{AuthorizedKeysFiles}= '';
$c{AuthorizedKeysAppend}= <<'END';
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA2m8+FRm8zaCy4+L2ZLsINt3OiRzDu82JE67b4Xyt3O0+IEyflPgw5zgGH69ypOn2GqYTaiBoiYNoAn9bpUksMk71q+co4gsZJ17Acm0256A3NP46ByT6z6/AKTl58vwwNKSCEAzNru53sXTYw2TcCZUN8A4vXY76OeJNJmCmgBDHCNod9fW6+EOn8ZSU1YjFUBV2UmS2ekKmsGNP5ecLAF1bZ8I13KpKUIDIY+UiG0UMwTWDfQY59SNsz6bCxv9NsxSXL29RS2XHFeIQis7t6hJuyZTT4b9YzjEAxvk8kdGzzK6314kwILibm1O1Y8LLyrYsWK1AvnJQFIhcYXF0EQ== iwj@mariner
END

1;
