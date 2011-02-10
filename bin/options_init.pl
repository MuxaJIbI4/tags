#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;
use Getopt::Long;
use Pod::Usage;
use Text::Unidecode;
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

### global vars
our ($config, $run, $current, $proc);

################################################################################
#########   Init options part
################################################################################

my %options = ();

sub init_options {

    load_options();

    # options that must be defined before others
    init_options_default('verbose');
    init_options_default('config');
    croak "Config not loaded" unless defined $config;
    init_options_default('cache');
    init_options_default('preset');

    foreach my $option (keys %options) {
        init_options_default($option);
    }

    # default process type
    $run->{options}->{process} ||= 'dir';
}

sub load_options {
    # command line options

    Getopt::Long::Configure('bundling');
    my $ok = GetOptions(
            'help|h|?'          => \$options{'help'},
            'man'               => \$options{'man'},
            'verbose|v=s'       => \$options{'verbose'},
            'config=s'          => \$options{'config'},
            'preset|p=s'        => \$options{'preset'},
            'content|c=s'       => \$options{'content'},
            'public=s'          => \$options{'public'},
            'infosave'          => \$options{'infosave'},
            'infoskip|i=i'      => \$options{'infoskip'},
            'infocheck'         => \$options{'infocheck'},
            'symlink|s'         => \$options{'symlink'},
            'move|m'            => \$options{'move'},
            'test'              => \$options{'test'},
            'ext|e'             => \$options{'ext'},
            'dupes|d'           => \$options{'dupes'},

            'db=s'              => \$options{'db'},
            'dbname=s'          => \$options{'dbname'},

            'infoupdate'        => \$options{'infoupdate'},
            'cache=s'           => \$options{'cache'},      # define cache folder
            'title|t=s'           => \$options{'title'},      # define process of content by title

            #deleted
            #'rename|r'          => \$options{'rename'},
    );

    # help
    pod2usage()                 unless $ok;
    pod2usage(1)                if $options{'help'};
    pod2usage(-verbose => 2)    if $options{'man'};
}

$proc->{option}->{init}->{config} ||= sub {
    my $filename = $options{config} || $run->{paths}->{script_home}.'/config.yml';
    if ( fs_exists($filename) ) {
        $config = YAML::XS::LoadFile($filename);
    }
    else {
        _print_log('error', 'config', "Configuration file doesn't exist");
        croak;
    }
    # TODO config validate
    _print_log('qa', 'config', "Loaded config file: [$filename]");

    # TODO init_logger - get filehandle
    if (defined $config->{encoding}->{out}) {
        $run->{encoding}->{out} ||= $config->{encoding}->{out};
        # TODO check for known encoding
        binmode STDOUT, ":encoding($run->{encoding}->{out})";
    }

    $run->{paths}->{config} = $filename;
    foreach (keys %{$run->{paths}}) {
        $run->{paths}->{$_} = fs_decode($run->{paths}->{$_});

    }
};

# init cache root
$proc->{option}->{init}->{cache} ||= sub {
    my $path;
    if (defined $options{cache}) {
         $path = decode('utf8',$options{cache}); # TODO decode from encoding: STDIN
    }
    $path ||= $config->{paths}->{cache};
    unless (defined $path) {
        _print_log('error', 'cache', "Can't determine cache path");
        croak;
    }

    if ($path =~ /^\//) {}
    elsif (defined $run->{paths}->{script_home}) { # relative path
        $path = File::Spec->catdir($run->{paths}->{script_home}, $path);
    }
    else {
        _print_log('error', 'cache', "Can't create full cache path from [$path]");
        croak;
    }
    $path = fs_abs_path($path);

    # creating path
    unless (fs_exists($path) ) {
        fs_create_path( path => $path, mode => 0775 ) || return;
    }
    unless ( fs_writable($path) ) {
        _print_log('error', 'cache', "Not writable: $path");
        croak;
    }
    _print_log('qa', "cache folder: [$path]");
    $run->{paths}->{cache} = $path;
};

# find root folder for symlinks
$proc->{option}->{init}->{public} ||= sub {
    my $path;
    if (defined $options{public}) {
         $path = decode('utf8',$options{public}); # TODO decode from encoding: STDIN
    }
    $path ||= $config->{paths}->{public};
    unless (defined $path) {
        _print_log('error', 'public', "Can't determine public path");
        croak;
    }
    if ($path =~ /^\//) {}
    elsif (defined $run->{paths}->{script_home}) { # relative path
        $path = File::Spec->catdir($run->{paths}->{script_home}, $path);
    }
    else {
        _print_log('error', 'public', "Can't create full public path from [$path]");
        croak;
    }
    $path = fs_abs_path($path);

    # creating path
    unless (fs_exists($path) ) {
        fs_create_path( path => $path, mode => 0775 ) || return;
    }
    unless ( fs_writable($path) ) {
        _print_log('error', 'public', "Not writable: $path");
        croak;
    }
    _print_log('qa', "public folder: [$path]");
    $run->{paths}->{public} = $path;
};

# finding root for content dirs
$proc->{option}->{init}->{content} ||= sub {
    my $path;
    if (defined $options{content}) {
         $path = decode('utf8',$options{content}); # TODO decode from encoding: STDIN
    }
    $path ||= $config->{paths}->{content} || return;
    $path = fs_abs_path($path);

    unless ( fs_exists($path) && fs_directory($path) ) {
        _print_log('error', 'content', "Can't determine root for content folders");
        return;
    }
    _print_log('qa', "title folder: [$path]");
    $run->{paths}->{content} = $path;
};

# finding root for titles dirs
$proc->{option}->{init}->{title} ||= sub {
    my $path;
    if (defined $options{title}) {
         $path = decode('utf8',$options{title}); # TODO decode from encoding: STDIN
    }
    $path ||= return;
    $path = fs_abs_path($path);

    unless ( fs_exists($path) && fs_directory($path) ) {
        _print_log('error', 'content', "Can't determine root for title folders");
        return;
    }
    _print_log('qa', "title folder: [$path]");
    $run->{paths}->{title} = $path;
};

$proc->{option}->{init}->{db} ||= sub {
    return unless defined $options{'db'};
    $run->{options}->{process} = 'db';
    $run->{options}->{db} = $options{'db'};
};

$proc->{option}->{init}->{preset} ||= sub {
    return unless defined $options{'preset'};
    my $preset = $options{preset};
    if ($preset eq 'parse') {
        init_options_default('ext', 1);
        init_options_default('infosave', 1);
        init_options_default('rename', 1);
    }
    elsif ($preset eq 'check') {
        init_options_default('rename', 1);
        init_options_default('move', 1);
        init_options_default('infocheck', 1);
        init_options_default('infoupdate', 1);
        init_options_default('dupes', 1);
    }
    else {
        _print_log('error', "$preset : unknown preset");
        croak;
    }
};

$proc->{option}->{init}->{symlink} ||= sub {
    return unless defined $options{'symlink'};
    $proc->{option}->{init}->{'public'}->();
    $run->{options}->{symlink} = 1;
    $run->{options}->{no_use_db_info} = 1;
};

$proc->{option}->{init}->{verbose} ||= sub {
    $run->{options}->{verbose} ||= 2; #default;
    my $verbose = $options{verbose};
    my $level;
    if (defined $verbose) {
        $level = 0 if $verbose eq 'error'   || $verbose eq '0';
        $level = 1 if $verbose eq 'warning' || $verbose eq '1';
        $level = 2 if $verbose eq 'qa'      || $verbose eq '2';
        $level = 3 if $verbose eq 'info'    || $verbose eq '3';
        $level = 4 if $verbose eq 'debug'   || $verbose eq '4';
    }
    else { # default log level
        $level = 2;
    }
    unless (defined $level) {
        _print_log('error', "Unknown verbosity level: [$verbose]");
        croak;
    }
    $run->{options}->{verbose} = $level;
};

sub init_options_default {
    my $option = shift || croak;
    my $value = shift || undef;
    _print_log('debug', 'init', "option = $option");
    if (defined $proc->{option}->{init}->{$option} ) {
        $proc->{option}->{init}->{$option}->();
    }
    else {
        $value ||= $options{$option};
        $run->{options}->{$option} = $value if defined $value;
    }
    delete $options{$option};
};

1;