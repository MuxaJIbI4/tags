#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;

# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

### global vars
our ($config, $run, $current, $proc);

################################################################################
#########   Symlink part
################################################################################

sub symlink_create {
    my $info = shift || croak;

    # defining symlink roots
    # TODO creating root on the fly in the loop
    my $roots;
    if (defined $config->{symlink}->{root} ) {
        foreach my $root (keys %{ $config->{symlink}->{root} }) {
            $roots->{$root} = undef;
        }
    }
    unless (defined $roots) {
        $roots->{''} = undef;
    }

    # creating aliases
    my $aliases = symlink_find_aliases($info);

    # find info for releases and tags in .info files in subfolders
    my ($releases, $tags) = symlink_find_info($info);
#    say "releases";yaml_print($releases);
#    say "tags";yaml_print($tags);

    # actual symlink creating
    my $count = 0;
    foreach my $root ( keys %{ $roots } ) {
        if ($root =~ /^value:(.*)/i) {
            my $tag = $1;
            my $value = get_tag_value(info => $info, tag => $tag);
            unless (defined $value) {
                _print_log('info', 'symlink', "Skipping symlink root: $tag");
                next;
            }
            $root = $value;
        }
#        say "symlink root = [$root]";
        $current->{public} =
            "$run->{paths}->{public}".
            ($root eq '' ? '' : "/$root");

        foreach my $alias (keys %{$aliases} ) {
#            say "alias = [$alias]";
            # alternate root as symlink
            next if $alias eq '';
            $current->{publicname} = $alias;
            _print_log('debug', 'symlink', "using public name: $current->{publicname}");
            my $interval = name_get_interval($current->{publicname});
            next unless defined $interval;
            $current->{publicpath} =
                "$current->{public}/!title".
                ($interval eq '' ? '' : "/$interval").
                "/$current->{publicname})";
            _print_log('debug', 'symlink', "using public path: $current->{publicpath}");

            # 1. create main symlink
            # do nothing - paths are created when there is at least one actual symlink

            # 2. create release symlinks
            foreach my $symlink (@{$releases}) {
                my $source =
                    "$current->{path}".
                    ($symlink->{source} eq '' ? '' : "/$symlink->{source}");
                my $dest_path = $current->{publicpath};
                my $dest_name = $symlink->{dest_name};
                my $ok = _symlink_create(
                    source => $source,
                    dest_path => $dest_path,
                    dest_name => $dest_name);
                $count++ if $ok;
            }

            # 3. create tags symlinks
            foreach my $path (keys %{$tags}) {
                my $source = $current->{publicpath};
                my $dest_path = "$current->{public}/$path";
                my $dest_name = $current->{publicname};
                my $ok = _symlink_create(
                    source => $source,
                    dest_path => $dest_path,
                    dest_name => $dest_name,
                    type => 'relative');
                $count++ if $ok;
            }

            # 4. creating symlinks using plugins
            # TODO
            foreach my $db ( keys %{$run->{db}} ) {
                if (defined $proc->{db}->{symlink}->{$db}) {
                    $count += $proc->{db}->{symlink}->{$db}->($info);
                }
            }
        }
    }
    say "Created symlinks: $count";
    return 1;
};

# find info for releases and optional tags in .info files in subfolders
sub symlink_find_info {
    my $info = shift || croak;
    my @releases;
    my @releasestmp;
    my $tags = {};
#    yaml_print($info);

    # tags from title info
    symlink_find_tags(info => $info, tags => $tags);
    # creating release name
    my $name_rel = name_release_tags( info => $info);
    push @releases, {source => '', dest_name => $name_rel} unless $name_rel eq '';

    # checking for release info
    foreach my $rel ( keys %{$current->{files}} ) {
        my %symlink;
        $symlink{source}    = $rel;
        my @files;

        if ( fs_directory($rel) ) {
            @files = File::Find::Rule
                ->file
                ->name( $config->{name}->{info} )
                ->maxdepth(1)
                ->in( fs_encode("$current->{path}/$rel") );
        }
        foreach (@files) {
            my $file = fs_decode($_);
            my $tmpdata = info_load($file);
            next unless defined $tmpdata;

            # tags from release info
            symlink_find_tags(info => $tmpdata, tags => $tags, type => 'release');

            # creating release name from release info
            $name_rel = name_release_tags( info => $tmpdata);
            $symlink{dest_name} = $name_rel unless $name_rel eq '';
        }
        unless (defined $symlink{dest_name}) {
            $symlink{dest_name} = $rel;
        }
        push @releasestmp, \%symlink unless @releases;
    }
    @releases = @releasestmp unless @releases;

    return (\@releases, $tags);
};

$proc->{symlink}->{parse_tag}->{default}->{default} ||= sub {
    local %_ = @_;
    my %allowed_keys = (tags=>'',value=>'',symlink_name=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $value = $_{value};
    my $tags = $_{tags};
    my $symlink_name = $_{symlink_name} || '';
    croak unless defined $value && defined $tags;
#    say "find_tag:default:$value";

    # multivalue tag
    #TODO multidepth tags (not only 1 level)
    my @parts = split /,/, $value;
    foreach my $part (@parts) {
        my $path = "$symlink_name/$part";
        $tags->{$path} = undef;
    }
};

$proc->{symlink}->{parse_tag}->{default}->{year} ||= sub {
    local %_ = @_;
    my %allowed_keys = (tags=>'',value=>'',symlink_name=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $value = $_{value};
    my $tags = $_{tags};
    my $symlink_name = $_{symlink_name} || '';
    croak unless defined $value && defined $tags;
#    say "find_tag:year:$value";
    # TODO fs_catdir
    $value = $1 if $value =~ /^(\d{4})/i;
    my $path = "$symlink_name/$value";
    $tags->{$path} = undef;
};

# find optional symlink tags
sub symlink_find_tags {
    local %_ = @_;
    my %allowed_keys = (tags=>'',info=>'',type=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $info = $_{info};
    my $tags = $_{tags};
    my $type = $_{type};
    croak unless defined $info && defined $tags;

    my @type = ($type) || keys %{$info};
    foreach my $type ( @type ) {
        next unless exists $config->{db}->{$type};
        next unless exists $config->{db}->{$type}->{symlink_tags};
        my @tags = hash_get_tags(data => $info->{$type});
        foreach (@tags) {
            my $tag = $_->{tag_name};
            my $value = $_->{value};
            next unless defined $value;
            next unless exists $config->{db}->{$type}->{symlink_tags}->{$tag};

            # custom symlink subroutine
            if (defined $proc->{symlink}->{tag}->{$type}->{$tag}) {
                $proc->{symlink}->{tag}->{$type}->{$tag}->(tag => $tag, value => $value, tags => $tags);
                next;
            }

            # tag name
            unless (exists $config->{tags}->{$tag}) {
                say "NOT EXISTS IN CONFIG: $tag";
                next;
            }
            my $symlink_name = $config->{tags}->{$tag}->{symlink_name} || $tag;

            # custom sub
            my $parse_tag = $proc->{symlink}->{parse_tag}->{$type}->{$tag}
                         || $proc->{symlink}->{parse_tag}->{default}->{$tag}
                         || $proc->{symlink}->{parse_tag}->{default}->{default};
            $parse_tag->(
                value => $value,
                tags => $tags,
                symlink_name => $symlink_name);
        }
     }
};

# creating alisases for main public name
sub symlink_find_aliases {
    my $info = shift || croak;
    my %names;

    my @articles = keys %{$config->{name}->{articles}};
    foreach ( qw{eng rus} ) {
        my $name = create_folder_name(info => $info, lang => $_);
        $names{$name} = undef;
        foreach ( @articles ) {
            if ($name =~ /^ $_\s /ix ) {
                $name =~ s/^ $_\s+ //xi;
                $name = ucfirst $name;
                $names{$name} = undef;
            }
        }
    }
    return \%names;
};

# actual creating of symlink
sub _symlink_create {
    local %_ = @_;
    # TODO options : create unexisted paths or throw exception
#    say Dumper %_;
    my $source      = $_{source}    || return;
    my $dest_path   = $_{dest_path} || return;
    my $dest_name   = $_{dest_name} || return;


    unless (fs_exists($dest_path) ) {
        fs_create_path( path => $dest_path, mode => 0775 ) || return;
    }

    if ( fs_exists("$dest_path/$dest_name") ) {
        _print_log( 'debug', 'symlink', "destinations exists $dest_path/$dest_name ---> $source");
        return 0;
    }

    # relative symlink
    if (defined $_{type} && $_{type} eq 'relative' ) {
        $source = File::Spec->abs2rel($source, $dest_path);
    }
    my $sym = eval { fs_symlink( $source, "$dest_path/$dest_name" ) };
    if ($@) {
        _print_log( 'warning', 'symlink' , $@);
        return 0;
    }
    elsif ($sym) {
        _print_log( 'debug', 'symlink', "created symlink $dest_path/$dest_name -> $source");
        return 1;
    }
    else { # $sym == 0;
        _print_log( 'debug', 'symlink', "can't create symlink $dest_path/$dest_name -> $source");
        return 0;
    }
    return;
}

1;
