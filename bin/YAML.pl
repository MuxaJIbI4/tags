#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;
use YAML::XS;
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

################################################################################
#########   YAML low-level part
################################################################################

# loading YAML file from disk
sub yaml_load {
    my ($file) = @_;
    my $data;
    eval {
        $data = YAML::XS::LoadFile($file);
    };
    if($@) {
        _print_log('warning', 'yaml', $@);
    }
    return $data;
}

# saving data to YAML file on disk
sub yaml_save {
    my ($file, $data) = @_;
    eval {
        YAML::XS::DumpFile($file, $data);
    };
    if($@) {
        _print_log('warning', 'yaml', $@);
        return 0;
    }
    else {
        return 1;
    }
    return;
}

# dumping complex data to YAML format
sub yaml_dump {
    my $data = shift;
    my $tmp = YAML::XS::Dump($data);
    utf8::decode($tmp);
    return $tmp;
}

# nice printing of complex data using YAML
sub yaml_print {
    my $data = shift;
    my $tmp = yaml_dump($data);
    say $tmp;
}

1;