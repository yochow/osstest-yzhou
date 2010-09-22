#$c{Domain}= 'uk.xensource.com';
$c{Domain}= 'cam.xci-test.com';
$c{TestHostDomain}= 'cam.xci-test.com';

$c{NetNameservers}= '10.80.248.2 10.80.16.28 10.80.16.67';
$c{NetNetmask}= '255.255.254.0';
$c{NetGateway}= '10.80.249.254';

$c{GenEtherPrefix}= '5a:36:0e';

$c{WebspaceFile}= '/export/home/osstest/public_html/';
$c{WebspaceUrl}= "http://woking.$c{Domain}/~osstest/";
$c{WebspaceCommon}= 'osstest/';
$c{WebspaceLog}= '/var/log/apache2/access.log';

$c{GitCache}='teravault-1.cam.xci-test.com:/export/home/xc_osstest/git-cache/';
$c{GitCacheLocal}= '/home/xc_osstest/git-cache/';

$c{PubBaseUrl}= 'http://www.chiark.greenend.org.uk/~xensrcts';
$c{ReportHtmlPubBaseUrl}= "$c{PubBaseUrl}/logs";
$c{ResultsHtmlPubBaseUrl}= "$c{PubBaseUrl}/results";
    
$c{ReportTrailer}= <<END;
Logs, config files, etc. are available at
    $c{ReportHtmlPubBaseUrl}

Test harness code can be found at
    http://xenbits.xensource.com/gitweb?p=osstest.git;a=summary
END

$c{SerialLogPattern}= '/root/sympathy/%host%.log*';

$c{OverlayLocal}= '/export/home/osstest/overlay-local';

$c{Publish}= 'xensrcts@login.chiark.greenend.org.uk:/home/ian/work/xc_osstest';

$c{Stash}= '/home/xc_osstest/logs';
$c{Images}= '/home/xc_osstest/images';
$c{Logs}= '/home/xc_osstest/logs';
$c{Results}= '/home/xc_osstest/results';
$c{LogsMinSpaceMby}= 10*1e3;
$c{LogsMinExpireAge}= 86400*28;

$c{LogsPublish}= "$c{Publish}/logs";
$c{ResultsPublish}= "$c{Publish}/results";

$c{HarnessPublishGitUserHost}= 'xen@xenbits.xensource.com';
$c{HarnessPublishGitRepoDir}= 'git/osstest.git';

$c{Tftp}= '/tftpboot/pxe';

#$c{Baud}= 38400;
$c{Baud}= 115200;
$c{PxeDiBase}= 'debian-installer';

$c{Suite}= 'lenny';
$c{GuestSuite}= 'lenny';
$c{HostDiskBoot}=   '300'; #Mby
$c{HostDiskRoot}= '30000'; #Mby
$c{HostDiskSwap}=  '2000'; #Mby

$c{BisectionRevisonGraphSize}= '600x300';

# We use the IP address because Citrix can't manage reliable nameservice
#$c{DebianMirrorHost}= 'debian.uk.xensource.com';
$c{DebianMirrorHost}= '10.80.16.17';
$c{DebianMirrorSubpath}= 'debian';

$c{TestingLib}= '.';

$c{Preseed}= <<END;
d-i clock-setup/ntp-server string ntp.uk.xensource.com
END

$c{TestHostKeypairPath}= '/export/home/osstest/.ssh/id_rsa_osstest';
$c{AuthorizedKeysFiles}= '';
$c{AuthorizedKeysAppend}= <<'END';
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA2m8+FRm8zaCy4+L2ZLsINt3OiRzDu82JE67b4Xyt3O0+IEyflPgw5zgGH69ypOn2GqYTaiBoiYNoAn9bpUksMk71q+co4gsZJ17Acm0256A3NP46ByT6z6/AKTl58vwwNKSCEAzNru53sXTYw2TcCZUN8A4vXY76OeJNJmCmgBDHCNod9fW6+EOn8ZSU1YjFUBV2UmS2ekKmsGNP5ecLAF1bZ8I13KpKUIDIY+UiG0UMwTWDfQY59SNsz6bCxv9NsxSXL29RS2XHFeIQis7t6hJuyZTT4b9YzjEAxvk8kdGzzK6314kwILibm1O1Y8LLyrYsWK1AvnJQFIhcYXF0EQ== iwj@mariner
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEApAkFv1FwknjOoataWvq5SRN/eUHjfQ5gfWnGJpIa4qnT+zAqYuC10BAHu3pHPV6NiedMxud0KcYlu/giQBMVMnYBdb7gWKdK4AQTgxHgvMMWHufa8oTLONLRsvyp1wQADJBzjQSjmo6HHF9faUckZHfJTfRxqLuR/3ENIyl+CRV9G6KfN9fbABejBxdfsbuTHc5ew2JsYxhDJsDFHgMjtrUoHI/d6eBTQDx8GRj8uUor8W+riFpW3whTH9dqloOyrqIke2qGVQlMNmzx5Z04vB1+n95nu9c5SGOZTUT4BQ5FybEANWQsNfJ7b3aMcYgVCVkKuRHSbW8Q4Pyn1Nh31w== ian@liberator
END

1;
