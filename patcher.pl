#!/usr/bin/perl
# Flipside Mac fix: patch engine.
#   patcher.pl patch   <game folder>   apply the fix (originals backed up to <game folder>/_mac-fix-backup)
#   patcher.pl restore <game folder>   put the original files back
#   patcher.pl check   <game folder>   show what would be changed
#
# Two binary patches on the game's own 32-bit Windows files:
#  1. SSE4.2 off in the Microsoft C runtime: the runtime stores the CPU feature level in __isa_available
#     (0 = none, 1 = SSE2, 2 = SSE4.2, 3 = AVX, 5 = AVX2, 6 = AVX-512). With level >= 2, string functions
#     such as wcsstr use the PCMPISTRI instruction, which Rosetta 2 runs extremely slowly. The stores of
#     levels 2..6 are changed to 1, so the runtime uses its plain SSE2 code paths.
#  2. NX_COMPAT flag on DLLs/extensions that lack it: one such DLL makes Wine mark all process memory as
#     executable, and under Rosetta writes to that memory are slow.
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Path qw(make_path);

my ($cmd, $dir) = @ARGV;
die "usage: $0 patch|restore|check <game folder>\n" unless $cmd && $dir && $cmd =~ /^(patch|restore|check)$/;
die "not a folder: $dir\n" unless -d $dir;
my $backup = "$dir/_mac-fix-backup";

sub pe_files {
    my @f;
    opendir(my $d, $dir) or die "$dir: $!\n";
    push @f, map { "$dir/$_" } grep { /\.(exe|dll)$/i && -f "$dir/$_" } readdir $d;
    closedir $d;
    if (opendir(my $m, "$dir/Modules")) {
        push @f, map { "$dir/Modules/$_" } grep { /\.(dll|mfx|mvx|sft|ift|flt)$/i && -f "$dir/Modules/$_" } readdir $m;
        closedir $m;
    }
    return sort @f;
}

sub rel { my $p = shift; $p =~ s/^\Q$dir\E\/?//; return $p }

# Returns (new content, list of change descriptions) without touching the file.
sub plan {
    my $data = shift;
    my @changes;
    return ($data, ()) unless substr($data, 0, 2) eq 'MZ' && length($data) > 0x200;
    my $pe = unpack('V', substr($data, 0x3c, 4));
    return ($data, ()) unless $pe + 0x60 < length($data) && substr($data, $pe, 4) eq "PE\0\0";
    return ($data, ()) unless unpack('v', substr($data, $pe + 4, 2)) == 0x14c;   # 32-bit x86 only

    # 1. __isa_available stores: C7 05 <addr32> <level32>. The variable is the address that gets both
    #    level 2 and level 3 stored into it (that is the CRT's __isa_available_init).
    my %lvl;
    while ($data =~ /\xC7\x05(.{4})([\x02-\x06])\x00\x00\x00/sg) { $lvl{$1}{ord $2} = 1 }
    for my $addr (keys %lvl) {
        next unless $lvl{$addr}{2} && $lvl{$addr}{3};
        my $re = qr/\xC7\x05\Q$addr\E[\x02-\x06]\x00\x00\x00/s;
        my @pos;
        while ($data =~ /$re/g) { push @pos, $-[0] }
        for my $p (@pos) {
            my $old = ord substr($data, $p + 6, 1);
            substr($data, $p + 6, 1) = "\x01";
            push @changes, sprintf("CPU level %d -> 1 (SSE2) at file offset 0x%x", $old, $p);
        }
    }

    # 2. NX_COMPAT (DllCharacteristics bit 0x100, optional header + 70)
    my $dcoff = $pe + 24 + 70;
    my $dc = unpack('v', substr($data, $dcoff, 2));
    unless ($dc & 0x100) {
        substr($data, $dcoff, 2) = pack('v', $dc | 0x100);
        push @changes, "NX_COMPAT flag set";
    }
    return ($data, @changes);
}

if ($cmd eq 'restore') {
    die "No backup found in $backup - nothing to restore.\n" unless -d $backup;
    my $n = 0;
    for my $b (`find "$backup" -type f`) {
        chomp $b;
        (my $r = $b) =~ s/^\Q$backup\E\///;
        copy($b, "$dir/$r") or die "restore $r: $!\n";
        print "restored $r\n"; $n++;
    }
    system('rm', '-rf', $backup);
    print "Restored $n original file(s).\n";
    exit 0;
}

my $total = 0;
for my $f (pe_files()) {
    open(my $in, '<:raw', $f) or die "$f: $!\n";
    local $/; my $data = <$in>; close $in;
    my ($new, @changes) = plan($data);
    next unless @changes;
    $total++;
    print rel($f), ":\n", map { "    $_\n" } @changes;
    next if $cmd eq 'check';
    my $bk = "$backup/" . rel($f);
    unless (-e $bk) {   # keep the very first original, even if patch runs twice
        make_path(dirname($bk));
        copy($f, $bk) or die "backup $f: $!\n";
    }
    open(my $out, '>:raw', "$f.tmp") or die "$f.tmp: $!\n";
    print $out $new; close $out or die "$f.tmp: $!\n";
    rename("$f.tmp", $f) or die "$f: $!\n";
}
if ($cmd eq 'check') { print $total ? "$total file(s) would be patched.\n" : "Nothing to patch (already fixed?).\n" }
else { print $total ? "Patched $total file(s). Originals saved in _mac-fix-backup.\n" : "Nothing to patch (already fixed).\n" }
