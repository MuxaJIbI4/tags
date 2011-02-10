#!/usr/bin/perl -w
use strict;
use warnings;
use feature ":5.10";
#use encoding 'utf8';
use Encode;
use HTML::Entities;
use Data::Dumper;
use Carp;
use Text::Unidecode;
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);
use File::Path qw(make_path);
use File::Find::Rule;
use utf8;   # source in utf-8

#use encoding 'cp1251';
#use open IN  => ":encoding(cp1251)";
#use open OUT => ':utf8';
#use open IO  => ":encoding(cp1251)";
#binmode STDOUT, ":encoding(cp1251)";

#binmode STDOUT, ":encoding(UTF-8)";






sub _create_path {
    local %_ = @_;
    croak "Path not defined" unless defined $_{path};
    my $path = $_{path};
    delete $_{path};
    _print_log('debug', '_create_path', "Creating path >> $path");
    make_path( $path, { %_ } );
    unless (-e $path) {
        _print_log('error', '_create_path', "Can't create path : $path");
        return 0;
    }
}

sub _print_log {
    my (@str) = @_;
    my %log = (
        error   => 0,
        warning => 1,
        qa      => 2,
        info    => 3,
        debug   => 4,
    );
    if ($str[0] !~ /^(error|warning|qa|info|debug)$/i) {
        printf( "%-7s: %-s: %s\n", 'error', (caller(1))[3], "wrong print_log() parameter: $str[0]. Exiting..." );
        croak;
    }
    my $run;
    $run->{options}->{verbose} = 2;
    return if $log{ $str[0] } > $run->{options}->{verbose};

    print color 'bold red'      if $str[0] eq 'error';
    print color 'bold yellow'   if $str[0] eq 'warning';
    print color 'bold blue'     if $str[0] eq 'qa';
    print color 'green'         if $str[0] eq 'info';
    my $level = shift @str;
    printf "%s: ", $level;
    print color 'reset' if $level eq 'info';
    my $caller = '';
    $caller = (caller(1))[3].':' if ($level =~ /error|warning/i ) && (caller(1))[3];
    printf "%s: ",$caller if $caller ne  '';
    printf "%s\n", join(": ",@str);
    print color 'reset';
    #print($log_handle,$str."\n");
}