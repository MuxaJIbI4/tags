#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;

use Cwd;
use File::Path qw(make_path);
use File::Copy; # for move
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

### global vars
our ($config, $run, $current, $proc);

################################################################################
#########   Filesystem service subroutines
################################################################################

sub fs_decode {
    my $path = shift || croak;
    my $enc = $run->{encoding}->{fs} || $config->{encoding}->{fs};
    $run->{encoding}->{fs} ||= $enc;
    # TODO eval, valid encoding
    return defined $enc ? decode($enc, $path) : $path;
}

sub fs_encode {
    my $path = shift || croak;
    my $enc = $run->{encoding}->{fs} || $config->{encoding}->{fs};
    $run->{encoding}->{fs} ||= $enc;
    # TODO eval, valid encoding
    return defined $enc ? encode($enc, $path) : $path;
}

# Cwd

sub fs_getcwd {
    return fs_decode(getcwd());
}

sub fs_abs_path {
    use Cwd 'abs_path';
    my $file = shift || croak;
    my $fs_file = fs_encode($file);
    if (defined abs_path($fs_file)) {
        $fs_file = abs_path($fs_file);
    }
    else {
        # return undef for not existing paths and for errors
        _print_log('warning', 'fs', "Can't create absolute path for: $file");
    }
    $file = fs_decode($fs_file);
    return $file;
}

sub fs_create_path {
    local %_ = @_;
    croak "Path not defined" unless defined $_{path};
    my $path = $_{path};
    my $fs_path = fs_encode($path);
    delete $_{path};
    _print_log('debug', 'fs', "Creating path: $path");
    eval {
        make_path( $fs_path, { %_ } );
        unless (-e $fs_path) {
            _print_log('error', '_create_path', "Can't create path : $path");
            return 0;
        }
    };
    if($@) {
        _print_log('warning', $@);
        croak;
    }
    return 1;
}

sub fs_move {
    my ($source, $dest) = @_;
    move(fs_encode($source), fs_encode($dest) );
}

sub fs_rename {
    my ($source, $dest) = @_;
    return rename(fs_encode($source), fs_encode($dest) );
}

sub fs_symlink {
    my ($source, $dest) = @_;
    return symlink(fs_encode($source), fs_encode($dest) );
}

# TODO check if .info is file ?
sub fs_folder_listing {
    my $dir = shift;
    my $files = {};

    my $ok = opendir(my $dh, fs_encode($dir));
    unless ($ok) {
        _print_log('warning', "Can't open $dir");
        croak "can't opendir $dir: $!"
    }
    _print_log('debug',"getting listing of $dir");
    while (my $file = readdir $dh) {
        $file = fs_decode($file);
        next if $file =~ /^\.\.?$/i;
#        $files->{content} = 1 if $file eq '.content';
#        $files->{info} = 1 if $file eq '.info' && fs_file("$dir/$file");
        $files->{$file} = 1;
    }
    closedir $dh;
    return $files;
}

sub fs_chdir {
    my $dir = shift || croak;
    my $ok = chdir(fs_encode($dir));
    unless ($ok) {
        _print_log('warning', 'fs', "Cannot chdir to $dir: $!\n");
    }
    return $ok;
}

sub fs_exists {
    return -e fs_encode($_[0]);
}

sub fs_writable {
    return -w fs_encode($_[0]);
}

sub fs_directory {
    return -d fs_encode($_[0]);
}

sub fs_file {
    return -f fs_encode($_[0]);
}

sub fs_modified {
    return -M fs_encode($_[0]);
}

