
package OsstestDebian;

use strict;
use warnings;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      %preseed_cmds
                      preseed_create
                      preseed_hook_command preseed_hook_installscript
                      di_installcmdline_core
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}


#---------- installation of Debian via debian-installer ----------

our %preseed_cmds;
# $preseed_cmds{$di_key}[]= $cmd

sub di_installcmdline_core ($$;@) {
    my ($tho, $ps_url, %xopts) = @_;

    my @cl= qw(
               auto=true preseed
               hw-detect/load_firmware=false
               DEBCONF_DEBUG=5
               DEBIAN_FRONTEND=text
               );
    push @cl, (
               "hostname=$tho->{Name}",
               "url=$ps_url",
               "netcfg/dhcp_timeout=150",
               "netcfg/choose_interface=auto"
               );

    my $debconf_priority= $xopts{DebconfPriority};
    push @cl, "debconf/priority=$debconf_priority"
        if defined $debconf_priority;

    return @cl;
}             

sub preseed_create ($$;@) {
    my ($ho, $sfx, %xopts) = @_;

    my $authkeys_url= create_webfile($ho, "authkeys$sfx", authorized_keys());

    my $hostkeyfile= "$c{OverlayLocal}/etc/ssh/ssh_host_rsa_key.pub";
    my $hostkey= get_filecontents($hostkeyfile);
    chomp($hostkey); $hostkey.="\n";
    my $knownhosts= '';

    my $hostsq= $dbh_tests->prepare(<<END);
        SELECT val FROM runvars
         WHERE flight=? AND name LIKE '%host'
         GROUP BY val
END
    $hostsq->execute($flight);
    while (my ($node) = $hostsq->fetchrow_array()) {
        my $longname= "$node.$c{TestHostDomain}";
        my (@hostent)= gethostbyname($longname);
        if (!@hostent) {
            logm("skipping host key for nonexistent host $longname");
            next;
        }
        my $specs= join ',', $longname, $node, map {
            join '.', unpack 'W4', $_;
        } @hostent[4..$#hostent];
        logm("adding host key for $specs");
        $knownhosts.= "$specs ".$hostkey;
    }
    $hostsq->finish();

    $knownhosts.= "localhost,127.0.0.1 ".$hostkey;
    my $knownhosts_url= create_webfile($ho, "known_hosts$sfx", $knownhosts);

    my $overlays= '';
    my $create_overlay= sub {
        my ($srcdir, $tfilename) = @_;
        my $url= create_webfile($ho, "$tfilename$sfx", sub {
            my ($fh) = @_;
            my $child= fork;  defined $child or die $!;
            if (!$child) {
                postfork();
                chdir($srcdir) or die $!;
                open STDIN, 'find ! -name "*~" ! -name "#*" -type f -print0 |'
                    or die $!;
                open STDOUT, '>&', $fh or die $!;
                system 'cpio -Hustar -o --quiet -0 -R 1000:1000';
                $? and die $?;
                $!=0; close STDIN; die "$! $?" if $! or $?;
                exit 0;
            }
            waitpid($child, 0) == $child or die $!;
            $? and die $?;
        });
        $overlays .= <<END;
wget -O overlay.tar '$url'
cd /target
tar xf \$r/overlay.tar
cd \$r
rm overlay.tar

END
    };

    $create_overlay->('overlay',        'overlay.tar');
    $create_overlay->($c{OverlayLocal}, 'overlay-local.tar');

    preseed_hook_installscript($ho, $sfx,
          '/lib/partman/init.d', '000override-parted-devices', <<END);
#!/bin/sh
set -ex
cd /bin
if test -f parted_devices.real; then exit 0; fi
mv parted_devices parted_devices.real
cat <<END2 >parted_devices
#!/bin/sh
/bin/parted_devices.real | grep -v '	0	'
END2
chmod +x parted_devices
END

    preseed_hook_installscript($ho, $sfx,
          '/lib/partman/init.d', '25erase-other-disks', <<'END');
#!/bin/sh
set -ex
stamp=/var/erase-other-disks.stamp
if test -f $stamp; then exit 0; fi
>$stamp
zero () {
    if test -b $dev; then
        dd if=/dev/zero of=$dev count=64 ||:
    fi
}
for sd in sd hd; do
    for b in a b c d e f; do
        dev=/dev/${sd}${b}
        zero
    done
    for dev in /dev/${sd}a[0-9]; do
        zero
    done
done
echo ===
set +e
ls -l /dev/sd*
true
END

    preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target/root
cd \$r

umask 022
mkdir .ssh
wget -O .ssh/authorized_keys '$authkeys_url'
wget -O .ssh/known_hosts     '$knownhosts_url'

u=osstest
h=/home/\$u
mkdir /target\$h/.ssh
cp .ssh/authorized_keys /target\$h/.ssh
chroot /target chown -R \$u.\$u \$h/.ssh

$overlays

echo latecmd done.
END

    my $preseed_file= (<<END);
d-i mirror/suite string $c{Suite}

d-i debian-installer/locale string en_GB
d-i console-keymaps-at/keymap select gb

#d-i debconf/frontend string readline

d-i mirror/country string manual
d-i mirror/http/proxy string

d-i clock-setup/utc boolean true
d-i time/zone string Europe/London
d-i clock-setup/ntp boolean true

d-i partman-auto/method string lvm
#d-i partman-auto/method string regular

d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman-lvm/confirm boolean true

d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_nameservers string $c{NetNameservers}
d-i netcfg/get_netmask string $c{NetNetmask}
d-i netcfg/get_gateway string $c{NetGateway}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_domain string $c{TestHostDomain}
d-i netcfg/wireless_wep string

#d-i partman-auto/init_automatically_partition select regular
d-i partman-auto/disk string /dev/sda

d-i partman-ext3/no_mount_point boolean false
d-i partman-basicmethods/method_only boolean false

d-i partman-auto/expert_recipe string					\\
	boot-root ::							\\
		$c{HostDiskBoot} 50 $c{HostDiskBoot} ext3		\\
			\$primary{ } \$bootable{ }			\\
			method{ format } format{ }			\\
			use_filesystem{ } filesystem{ ext3 }		\\
			mountpoint{ /boot }				\\
		.							\\
		$c{HostDiskRoot} 50 $c{HostDiskRoot} ext3		\\
			method{ format } format{ } \$lvmok{ }		\\
			use_filesystem{ } filesystem{ ext3 }		\\
			mountpoint{ / }					\\
		.							\\
		$c{HostDiskSwap} 40 100% linux-swap			\\
			method{ swap } format{ } \$lvmok{ }		\\
		.							\\
		1 30 1000000000 ext3					\\
			method{ keep } \$lvmok{ }			\\
			lv_name{ dummy }				\\
		.

d-i passwd/root-password password xenroot
d-i passwd/root-password-again password xenroot
d-i passwd/user-fullname string FLOSS Xen Test
d-i passwd/username string osstest
d-i passwd/user-password password osstest
d-i passwd/user-password-again password osstest

console-common  console-data/keymap/policy      select  Don't touch keymap
console-data    console-data/keymap/policy      select  Don't touch keymap
console-data    console-data/keymap/family      select  qwerty
console-data console-data/keymap/template/layout select British

popularity-contest popularity-contest/participate boolean false
tasksel tasksel/first multiselect standard, web-server

d-i pkgsel/include string openssh-server

d-i grub-installer/only_debian boolean true

d-i finish-install/keep-consoles boolean true
d-i finish-install/reboot_in_progress note
d-i cdrom-detect/eject boolean false

d-i mirror/http/hostname string $c{DebianMirrorHost}
d-i mirror/http/directory string /$c{DebianMirrorSubpath}

$xopts{ExtraPreseed}
END

    foreach my $di_key (keys %preseed_cmds) {
        $preseed_file .= "d-i preseed/$di_key string ".
            (join ' && ', @{ $preseed_cmds{$di_key} }). "\n";
    }

    $preseed_file .= "$c{Preseed}\n";

    foreach my $prop (values %{ $xopts{Properties} }) {
        next unless $prop->{name} =~ m/^preseed $c{Suite} /;
        $preseed_file .= "$' $prop->{val}\n";
    }

    return create_webfile($ho, "preseed$sfx", $preseed_file);
}

sub preseed_hook_command ($$$$) {
    my ($ho, $di_key, $sfx, $text) = @_;
    my $ix= $#{ $preseed_cmds{$di_key} } + 1;
    my $url= create_webfile($ho, "$di_key-$ix$sfx", $text);
    my $file= "/tmp/$di_key-$ix";
    my $cmd_cmd= "wget -O $file '$url' && chmod +x $file && $file";
    push @{ $preseed_cmds{$di_key} }, $cmd_cmd;
}

sub preseed_hook_installscript ($$$$$) {
    my ($ho, $sfx, $installer_dir, $installer_leaf, $data) = @_;
    my $installer_pathname= "$installer_dir/$installer_leaf";
    my $urlfile= $installer_pathname;
    $urlfile =~ s/[^-_0-9a-z]/ sprintf "X%02x", ord($&) /ge;
    my $url= create_webfile($ho, $urlfile, $data);
    preseed_hook_command($ho, 'early_command', $sfx, <<END);
#!/bin/sh
set -ex
mkdir -p '$installer_dir'
wget -O '$installer_pathname' '$url'
chmod +x '$installer_pathname'
END
}

1;
