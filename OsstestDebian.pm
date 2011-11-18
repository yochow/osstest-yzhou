
package OsstestDebian;

use strict;
use warnings;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(debian_boot_setup
                      %preseed_cmds
                      preseed_create
                      preseed_hook_command preseed_hook_installscript
                      di_installcmdline_core
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

#---------- manipulation of Debian bootloader setup ----------

sub debian_boot_setup ($$$;$) {
    # $xenhopt==undef => is actually a guest, do not set up a hypervisor
    my ($ho, $xenhopt, $distpath, $hooks) = @_;

    target_kernkind_check($ho);
    target_kernkind_console_inittab($ho,$ho,"/");

    my $kopt;
    my $console= target_var($ho,'console');
    if (defined $console && length $console) {
        $kopt= "console=$console";
    } else {
        $kopt= "xencons=ttyS console=ttyS0,$c{Baud}n8";
    }

    my $targkopt= target_var($ho,'linux_boot_append');
    if (defined $targkopt) {
        $kopt .= ' '.$targkopt;
    }

    foreach my $hook ($hooks ? @$hooks : ()) {
        my $bo_hook= $hook->{EditBootOptions};
        $bo_hook->($ho, \$xenhopt, \$kopt) if $bo_hook;
    }

    my $bootloader;
    if ($ho->{Suite} =~ m/lenny/) {
        $bootloader= setupboot_grub1($ho, $xenhopt, $kopt);
    } else {
        $bootloader= setupboot_grub2($ho, $xenhopt, $kopt);
    }

    target_cmd_root($ho, "update-grub");

    my $kern= $bootloader->{GetBootKern}();
    logm("dom0 kernel is $kern");

    system "tar zvtf $distpath->{kern} boot/$kern";
    $? and die "$distpath->{kern} boot/$kern $?";

    my $kernver= $kern;
    $kernver =~ s,^/?(?:boot/)?(?:vmlinu[xz]-)?,, or die "$kernver ?";
    my $kernpath= $kern;
    $kernpath =~ s,^(?:boot/)?,/boot/,;

    target_cmd_root($ho,
                    "update-initramfs -k $kernver -c ||".
                    " update-initramfs -k $kernver -u",
                    200);

    $bootloader->{PreFinalUpdate}();

    target_cmd_root($ho, "update-grub");

    store_runvar(target_var_prefix($ho).'xen_kernel_path',$kernpath);
    store_runvar(target_var_prefix($ho).'xen_kernel_ver',$kernver);
}

sub bl_getmenu_open ($$$) {
    my ($ho, $rmenu, $lmenu) = @_;
    target_getfile($ho, 60, $rmenu, $lmenu);
    my $f= new IO::File $lmenu, 'r' or die "$lmenu $?";
    return $f;
}

sub setupboot_grub1 ($$$) {
    my ($ho,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    my $rmenu= "/boot/grub/menu.lst";
    my $lmenu= "$stash/$ho->{Name}--menu.lst.out";

    target_editfile_root($ho, $rmenu, sub {
        while (<::EI>) {
            if (m/^## ## Start Default/ ..
                m/^## ## End Default/) {
                s/^# xenhopt=.*/# xenhopt= $xenhopt/ if defined $xenhopt;
                s/^# xenkopt=.*/# xenkopt= $xenkopt/;
            }
            print ::EO or die $!;
        }
    });

    $bl->{GetBootKern}= sub {
        my $f= bl_getmenu_open($ho, $rmenu, $lmenu);

        my $def;
        while (<$f>) {
            last if m/^\s*title\b/;
            next unless m/^\s*default\b/;
            die "$_ ?" unless m/^\s*default\s+(\d+)\s*$/;
            $def= $1;
            last;
        }
        my $ix= -1;
        die unless defined $def;
        logm("boot check: grub default is option $def");

        my $kern;
        while (<$f>) {
            s/^\s*//; s/\s+$//;
            if (m/^title\b/) {
                $ix++;
                if ($ix==$def) {
                    logm("boot check: title $'");
                }
                next;
            }
            next unless $ix==$def;
            if (m/^kernel\b/) {
                die "$_ ?" unless
  m,^kernel\s+/(?:boot/)?((?:xen|vmlinuz)\-[-+.0-9a-z]+\.gz)(?:\s.*)?$,;
		my $actualkernel= $1;
                logm("boot check: actual kernel: $actualkernel");
		if (defined $xenhopt) {
		    die unless $actualkernel =~ m/^xen/;
		} else {
		    die unless $actualkernel =~ m/^vmlinu/;
		    $kern= $1;
		}
            }
            if (m/^module\b/ && defined $xenhopt) {
                die "$_ ?" unless m,^module\s+/((?:boot/)?\S+)(?:\s.*)?$,;
                $kern= $1;
                logm("boot check: kernel: $kern");
                last;
            }
        }
        die "$def $ix" unless defined $kern;
        return $kern;
    };


    $bl->{PreFinalUpdate}= sub { };

    return $bl;
}

sub setupboot_grub2 ($$$) {
    my ($ho,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    my $rmenu= '/boot/grub/grub.cfg';
    my $kernkey= (defined $xenhopt ? 'KernDom0' : 'KernOnly');
 
    my $parsemenu= sub {
        my $f= bl_getmenu_open($ho, $rmenu, "$stash/$ho->{Name}--grub.cfg.1");
    
        my $count= 0;
        my $entry;
        while (<$f>) {
            next if m/^\s*\#/ || !m/\S/;
            if (m/^\s*\}\s*$/) {
                die unless $entry;
                my (@missing) =
                    grep { !defined $entry->{$_} } 
		        (defined $xenhopt
			 ? qw(Title Hv KernDom0)
			 : qw(Title Hv KernOnly));
                last if !@missing;
                logm("(skipping entry at $entry->{StartLine}; no @missing)");
                $entry= undef;
                next;
            }
            if (m/^function.*\{/) {
                $entry= { StartLine => $. };
            }
            if (m/^menuentry\s+[\'\"](.*)[\'\"].*\{\s*$/) {
                die $entry->{StartLine} if $entry;
                $entry= { Title => $1, StartLine => $., Number => $count };
                $count++;
            }
            if (m/^\s*multiboot\s*\/(xen\-[0-9][-+.0-9a-z]*\S+)/) {
                die unless $entry;
                $entry->{Hv}= $1;
            }
            if (m/^\s*multiboot\s*\/(vmlinu[xz]-\S+)/) {
                die unless $entry;
                $entry->{KernOnly}= $1;
            }
            if (m/^\s*module\s*\/(vmlinu[xz]-\S+)/) {
                die unless $entry;
                $entry->{KernDom0}= $1;
            }
            if (m/^\s*module\s*\/(initrd\S+)/) {
                $entry->{Initrd}= $1;
            }
        }
        die 'grub 2 bootloader entry not found' unless $entry;

        die unless $entry->{Title};

        logm("boot check: grub2, found $entry->{Title}");

	die unless $entry->{$kernkey};
	if (defined $xenhopt) {
	    die unless $entry->{Hv};
	}

        return $entry;
    };

    $bl->{GetBootKern}= sub { return $parsemenu->()->{$kernkey}; };

    $bl->{PreFinalUpdate}= sub {
        my $entry= $parsemenu->();
        
        target_editfile_root($ho, '/etc/default/grub', sub {
            my %k;
            while (<::EI>) {
                if (m/^\s*([A-Z_]+)\s*\=\s*(.*?)\s*$/) {
                    my ($k,$v) = ($1,$2);
                    $v =~ s/^\s*([\'\"])(.*)\1\s*$/$2/;
                    $k{$k}= $v;
                }
                next if m/^GRUB_CMDLINE_(?:XEN|LINUX).*\=|^GRUB_DEFAULT.*\=/;
                print ::EO;
            }
            print ::EO <<END or die $!;

GRUB_DEFAULT=$entry->{Number}
END

            print ::EO <<END or die $! if defined $xenhopt;
GRUB_CMDLINE_XEN="$xenhopt"

END
            foreach my $k (qw(GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT)) {
                my $v= $k{$k};
                $v =~ s/\bquiet\b//;
                $v =~ s/\b(?:console|xencons)=[0-9A-Za-z,]+//;
                $v .= " $xenkopt" if $k eq 'GRUB_CMDLINE_LINUX';
                print ::EO "$k=\"$v\"\n" or die $!;
            }
        });
    };

    return $bl;
}

#---------- installation of Debian via debian-installer ----------

our %preseed_cmds;
# $preseed_cmds{$di_key}[]= $cmd

sub di_installcmdline_core ($$;@) {
    my ($tho, $ps_url, %xopts) = @_;

    $ps_url =~ s,^http://,,;

    my $netcfg_interface= get_host_property($tho,'interface force','auto');

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
               "netcfg/choose_interface=$netcfg_interface"
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

    my $disk= $xopts{DiskDevice} || '/dev/sda';
    my $suite= $xopts{Suite} || $c{Suite};

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
            contents_make_cpio($fh, 'ustar', $srcdir);
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
          '/lib/partman/init.d', '25erase-other-disks', <<END);
#!/bin/sh
set -ex
stamp=/var/erase-other-disks.stamp
if test -f \$stamp; then exit 0; fi
>\$stamp
zero () {
    if test -b \$dev; then
        dd if=/dev/zero of=\$dev count=64 ||:
    fi
}
for sd in sd hd; do
    for b in a b c d e f; do
        dev=/dev/\${sd}\${b}
        zero
    done
    for dev in /dev/\${sd}a[0-9]; do
        zero
    done
done
for dev in ${disk}*; do
    zero
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
d-i mirror/suite string $suite

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

d-i partman/confirm_nooverwrite true
d-i partman-lvm/confirm_nooverwrite true
d-i partman-md/confirm_nooverwrite true
d-i partman-crypto/confirm_nooverwrite true

#d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_nameservers string $c{NetNameservers}
#d-i netcfg/get_netmask string \$c{NetNetmask}
#d-i netcfg/get_gateway string \$c{NetGateway}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_domain string $c{TestHostDomain}
d-i netcfg/wireless_wep string

#d-i partman-auto/init_automatically_partition select regular
d-i partman-auto/disk string $disk

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
        next unless $prop->{name} =~ m/^preseed $suite /;
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
