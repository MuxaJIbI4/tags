#!/usr/bin/perl -w
use strict;
no strict 'refs';
use warnings;
use diagnostics;

use IO::Prompt;
use Time::HiRes qw{ time gettimeofday tv_interval};
# for cloning returned data;
use Storable qw{dclone};
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";
#use encoding 'utf8';

#local libs
#use FindBin qw($Bin);
#use lib "$Bin/../lib";

### global vars
our ($config, $run, $current, $proc);

=config
.info - просто та часть баз, что оносится к данному тайтлу/релизу
=cut
################################################################################
#########   Database low-level part
################################################################################

{ # begin closure
my $db;
my $db_index;

sub db_init_all {
    # creating db path
    my $path = $config->{paths}->{'db'};
    unless (defined $path) {
        _print_log('error', 'cache', "Can't determine db path");
        croak;
    }
    if ($path =~ /^\//) {}
    elsif (defined $run->{paths}->{script_home}) { # relative path
        $path = File::Spec->catdir($run->{paths}->{script_home}, $path);
    }
    else {
        _print_log('error', 'cache', "Can't create full db path from [$path]");
        croak;
    }
    $path = fs_abs_path($path);
    $run->{paths}->{db} = $path || croak;

    # load main db (table)
    foreach (keys %{$config->{db}}) {
        db_init(db_name => $_);
    }
}

$proc->{db}->{init}->{title} ||= sub {
    next unless db_is_loaded(db_name => 'title');
    use List::Util qw{max};
    $db_index = max keys %{$db->{titles}} || 0;
};

sub db_init {
    local %_ = @_;
    croak unless defined $_{db_name};
    my $db_name = $_{db_name};

    # loading db data
    my $filename = "$run->{paths}->{db}/$db_name";
    $db->{$db_name} = yaml_load( fs_encode($filename) );

    if (defined $db->{$db_name}) {
        my $size = scalar keys %{$db->{$db_name}};
        _print_log('qa', 'db', "Found $size entries in [$db_name] db");
    }
    else {
        $db->{$db_name} = {};
        _print_log('warning', 'db', "Can't load [$db_name] db from $filename");
    }

    # using custom db init subs
    if (defined $proc->{db}->{init}->{$db_name}) {
        $proc->{db}->{init}->{$db_name}->();
    }

    $run->{db}->{$db_name}->{path} = $filename;
}

sub db_is_loaded {
    local %_ = @_;
    my $db_name = $_{db_name} || croak;
    return defined $db->{$db_name};
}

# saving db to disk
sub db_dump_all {
    foreach (keys %{$run->{db}}) {
        db_dump(db_name => $_);
    }
}

#db_dump(db_name => $_,db_path => $config->{db}->{$_});
sub db_dump {
    local %_ = @_;
    croak unless defined $_{db_name};
    my $db_name = $_{db_name};
    return unless db_is_loaded(db_name => $db_name);
    my $data = $db->{$db_name};

    my $size = scalar keys %{$data};
    _print_log('qa', 'db', "Found $size entries in $db_name db");

    my $filename = $run->{db}->{$db_name}->{path};
    return unless defined $filename;
    _print_log('info', 'db', "Saving $db_name db to $filename");
    yaml_save( fs_encode($filename), $data);
}

# saving given data to given db
sub db_save_data {
    say "STUB: db_save_data";return;
    local %_ = @_;
    croak unless defined $_{db_name} && exists $_{value};
    my $db_name = $_{db_name};
    my $value = $_{value};
    my $tag = $_{tag};
    my $update = $_{update};

    return unless db_is_loaded(db_name => $db_name);
    my $data = $db->{$db_name};

    hash_set_tag_value_mass(data => $data, tag => $tag, value => $value, update => $update);
}

#db_get_data(db_name => ,tag => );
# TODO index
sub db_get_data {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (db_name=>'',db_index=>'',tag=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $db_name = $_->{db_name};
    my $db_index = $_->{db_index};
    my $tag = $_->{tag};
    croak unless defined $db_name && defined $db_index;

    return unless db_is_loaded(db_name => $db_name);
    my $data = $db->{$db_name};
    my $value = hash_get_tag_value(data => $data, tag => "$db_index:$tag");
    return ref $value ? dclone $value : $value;
}

sub db_get_data_keys {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (db_name=>'',tag=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $db_name = $_->{db_name};
    my $tag = $_->{tag};
    croak unless defined $db_name;

    return unless db_is_loaded(db_name => $db_name);
    my $data = $db->{$db_name};
    my @keys = hash_get_tag_keys(data => $data, tag => $tag);
    return @keys;
}

### USE WITH CAUTION
#db_truncate(db_name => 'kp_top250');
sub db_truncate {
    say "STUB: db_truncate";return;
    local %_ = @_;
    croak unless defined $_{db_name};
    my $db_name = $_{db_name};
    return unless db_is_loaded(db_name => $db_name);
    $db->{$db_name} = {};
    return;
}

# clear db's tag for all indexes
#db_clear_field(db_name => 'titles', field => 'paths');
sub db_clear_field {
    say "STUB: db_clear_field";return;
    local %_ = @_;
    croak unless defined $_{db_name} && defined $_{field};
    my $db_name = $_{db_name} || $run->{options}->{dbname};
    my $field = $_{field};
    unless (db_is_loaded(db_name => $db_name)) {
        _print_log('error','db', "db [$db_name] not loaded: can't clear");
        return;
    }
    _print_log('qa', 'db', "Clear db: [$db_name]");
    my $data = $db->{$db_name};
    my @keys = db_get_data_keys(db_name => $db_name);
    foreach my $key (@keys) {
        hash_set_tag_value( data => $data, tag => "$key:$field", value => undef);
    }
}

sub db_add_title {
    my $index = ++$db_index;
    _print_log('info', 'db', "Added new title index: $index");
    return $index;
}

} # end of low-level db subs closure

################################################################################
#########   Database service part
################################################################################

# TODO support for not one-to-one indexes
$proc->{db}->{check} ||= sub {
    say "STUB: db_check";return;
    local %_ = @_;
    croak unless defined $_{db_name};
    my $db_name = $_{db_name};

    unless (db_is_loaded(db_name => $db_name)) {
        _print_log('error','db', "db [$db_name] not loaded: can't check");
        return;
    }
    _print_log('qa', 'db_check', "Checking db: $db_name");

    my $indexes = {};
    my @indexes = db_get_data_keys(db_name => $db_name);
    foreach my $index (@indexes) {
        _print_log('info', 'db', "checking index $index");

        # check for unique plugin code
        my $data = db_get_data(db_name => $db_name, tag => "$index:index" );
        foreach my $db_name2 (keys %$data) {
            if (defined $indexes->{$db_name2}->{$data->{$db_name2}}->{$db_name} ) {
                _print_log('warning', 'db', "Found nonunique db_name2 code: $db_name2/$data->{$db_name2}");
                _print_log('warning', 'db', "old: $indexes->{$db_name2}->{$data->{$db_name2}}->{$db_name}");
                _print_log('warning', 'db', "now: $index");
            }
            $indexes->{$db_name}->{$index}->{ $db_name2 } = $data->{$db_name2};
            $indexes->{$db_name2}->{$data->{$db_name2}}->{$db_name} ||= $index;
        }
    }
    return $indexes->{$db_name};
};


# TODO support for not one-to-one indexes
# check all dbs for consistency:
sub db_check_all {
    _print_log('qa', 'db_check', "Checking db");
    my $indexes = {};

    # 1. loading all indexes in all databases
    foreach ( keys %{$config->{db}} ) {
        next unless defined $config->{db}->{$_}->{cross};
        $indexes->{$_} = $proc->{db}->{check}->(db_name => $_);
    }

    # 2. check for consistend indexes in all databases
    foreach my $db1 ( keys %$indexes ) {
        foreach my $i1 ( keys %{$indexes->{db1}} ) {
            foreach my $db2 ( keys %$indexes ) {
                foreach my $i2 ( keys %{$indexes->{db2}} ) {
                    next if $db1 eq $db2;
                    my $value12 = $indexes->{$db1}->{$i1}->{$db2}->{$i2};
                    my $value21 = $indexes->{$db2}->{$i2}->{$db1}->{$i1};
                    if (defined $value12 && defined $value21) {
                        next if $value12 eq $value21;
                        _print_log('warning', 'db', "Found non consistent indexes: db1/i1 > db2/i2 = value2");
                        _print_log('warning', 'db', "$db1/$i1 > $db2/$i2 = $value12");
                        _print_log('warning', 'db', "$db2/$i2 > $db1/$i1 = $value21");
                        next;
                    }
                    if (defined $value12 || defined $value21) {
                        _print_log('warning', 'db', "Found non defined index: db1/i1 > db2/i2 = value2");
                        _print_log('warning', 'db', "$db1/$i1 > $db2/$i2 = $value12");
                        _print_log('warning', 'db', "$db2/$i2 > $db1/$i1 = $value21");
                        next;
                    }
                }
            }
        }
    }
}

# updating db data (kp, imdb)
sub db_update {
    say "STUB: db_update";return;
    my $db_name = $run->{options}->{dbname} || croak "Not defined name of db that needs updating";
    unless (db_is_loaded(db_name => $db_name)) {
        _print_log('error', 'db', "db [$db_name] is not loaded");
        return;
    }

    # loading and saving previous cache dumps;
    db_update_load_cache(db_name => $db_name);

    # update db directly
    if (defined $proc->{db}->{$db_name}->{update}) {
        _print_log('qa', 'db_update', "Updating content db: $db_name");
        $proc->{db}->{$db_name}->{update}->();
        return;
    }

    ### update using db's plugin
    return unless defined $config->{db}->{$db_name}->{plugin};
    my $plugin = $config->{db}->{$db_name}->{plugin};
    next unless defined $proc->{plugin}->{$plugin}->{'get_info'};
    _print_log('qa', 'db_update', "Updating content db: $db_name");

    # update index's data;
    my @indexes = db_get_data_keys(db_name => $db_name);
    my $db_cache = {};
    foreach my $index (@indexes) {
        undef $current;
        _print_log('qa', 'db_update', "Processing index: $db_name/$index");

        # skip recently updated
        my $t0 = [gettimeofday];
        my $t1 = db_get_data(db_name => $db_name, tag => "$index:updated") || 0;
        my $t0_t1 = tv_interval([$t1, 0], $t0);
        if ($t0_t1 < 100 ) { # TODO param, option or config default
            _print_log('info', 'db_update', "Skipping recently updated data: $db_name/$index");
            next;
        }

        # loading old db data
        my $db_data = db_get_data(db_name => $db_name, tag => "$index:data") || {};

        # getting new info
        $proc->{plugin}->{$plugin}->{get_info}->(data => $db_data, code => $index);
#        my $line = prompt("\nPress to continue? > ");

        # saving new data to cache
        # TODO promt for auto protect tags
        # TODO option: update only given tags
        $t0 = [gettimeofday];
        hash_set_tag_value(
            data => $db_cache,
            tag => "$index:data",
            value => $db_data,
            update => 1);
        hash_set_tag_value(
            data => $db_cache,
            tag => "$index:updated",
            value => $t0->[0]);

        # dumping cache
        if (scalar keys %$db_cache >=100) {
            db_update_dump_cache(db_name => $db_name, data => $db_cache);
            $db_cache = {};
        }
    }
    db_update_dump_cache(db_name => $db_name, data => $db_cache); # half-empty cache

    # loading and saving previous cache dumps;
    db_update_load_cache(db_name => $db_name);
}
sub db_update_dump_cache {
    local %_ = @_;
    croak unless defined $_{db_name} && defined $_{data};
    my $db_name = $_{db_name};
    my $data = $_{data};
    my $t0 = [gettimeofday];
    my $filename = "$run->{paths}->{db}/$db_name.update.$t0->[0]";
    _print_log('info', 'db_update', "Saving cache dump to $filename");
    yaml_save( fs_encode($filename), $data);
}

sub db_update_load_cache {
    local %_ = @_;
    my $db_name = $_{db_name} || croak;

    _print_log('info', 'db_update', "Loading and saving existing cache dumps");
    my @files = glob ("$run->{paths}->{script_home}/db/$db_name.update.*");
    if (scalar @files) {
        foreach my $file (@files) {
            _print_log('info', 'db_update', "Loading cache dump $file");
            my $db_cache = yaml_load( fs_encode($file) );
            next unless defined $db_cache;
            db_save_data (db_name => $db_name, value => $db_cache, update => 1);
        }

        # dump and reload db
        db_dump(db_name => $db_name);
        db_init(db_name => $db_name);

        # remove old updates if success
        unlink $_ foreach (@files);
    }
}

sub db_process {
    my $command = shift || $run->{options}->{db};

    if ($command eq 'init') {
        db_init_all();
        return;
    }
    if ($command eq 'clearpath') {
        db_clear_field(db_name => 'titles', field => 'paths');
        return;
    }
    elsif ($command eq 'scan') {
        $run->{options}->{process} = 'dir';
        return;
    }
    elsif ($command eq 'update') {
        # TODO
        $run->{options}->{ext} = 1;
        db_update();
        return;
    }
    elsif ($command eq 'check') {
        # TODO
        db_check_all();
        return;
    }
    else {
        _print_log('error','db', "Unknon --db option: $run->{options}->{db}");
        return;
    }
};

1;