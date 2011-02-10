#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;

use IO::Prompt;
use Text::Unidecode;
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);

# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

### global vars
our ($config, $run, $current, $proc);

################################################################################
#########   .info service subs
################################################################################

sub info_load {
    # TODO $file == 'name:info' ALWAYS if $file not defined
    my ($file) = @_;
    $file = fs_encode($file); # TODO move fs_encode to YAML.pl
    my $data = yaml_load($file);
    _print_log('info', 'info', "Loaded file $file") if defined $data;
    info_check($data) if defined $run->{options}->{infocheck};
    return $data;
}

sub info_save {
    # TODO $file == 'name:info' ALWAYS if $file not defined
    my ($file, $data) = @_;
    $file = fs_encode($file);
    my $ok = yaml_save($file, $data);
    _print_log('info', 'info', "Saved file $file") if $ok;
    return;
}

sub info_check {
    say "STUB: info_check";return;
    my $info = shift || croak;
    my $check = 0;

    # check for title
    unless (exists $info->{title}) {
        _print_log('error', 'info', "Not found tag 'title' in $current->{path}");
        return;
    }

    foreach (keys %{$info}) {
        my $db = $_;

        # chechk for unknown db
        unless (exists $config->{db}->{$db}) {
            _print_log('error', "Unknown db's tag [$db] in $current->{path}");
#            delete $info->{$db};
            next;
        }

        # find missing or undefined required tags:
        foreach my $tag ( keys %{$config->{db}->{$db}->{tags_required}} ) {
            if (exists $info->{$db}->{$tag}) {
                unless (defined $info->{$db}->{$tag}) {
                    _print_log('warning', "Required tag $tag not defined in $current->{path}");
                    $check++;
                }
            }
            else {
                _print_log('warning', "Required tag $tag is missing in $current->{path}");
                $check++;
            }
        }

        # find unknown tags
        foreach my $tag ( keys %{$info->{$db}} ) {
            unless (exists $config->{db}->{$db}->{tags_allowed}->{$tag}) {
                _print_log('warning', "Unknown tag: '$tag' in $current->{path}");
                $check++;
            }
        }
    }
    if ($run->{options}->{'infocheck'} && $check) {
        yaml_print($info);
        my $line = prompt("Press to continue? > ");
    }
    return;
}

sub info_normalize {
    say "STUB: info_normalize";return;
    my $info = shift || croak;

    my %dbs = (title=>, release=>);
    foreach (keys %$info) {
        $dbs{$_} = undef;
    }

    foreach my $db ( keys %dbs ) {
        # undef tags with null values (empty arrays, hashes, '')
        foreach my $tag ( keys %{ $info->{$db} } ) {
            my $tmp = $info->{$db}->{$tag};
            undef $info->{$db}->{$tag} if
            (ref $tmp eq 'HASH'   && not scalar keys %{$tmp})
         || (ref $tmp eq 'ARRAY'  && not scalar @{$tmp})
         || (ref $tmp eq ''       && not $tmp);
        }

        my @tags;
        # adding undefined symlink tags
        push @tags, keys %{$config->{db}->{$db}->{symlink_tags} };
        # adding undefined required tags
        push @tags, keys %{$config->{db}->{$db}->{tags_required} };
        foreach my $tag ( @tags ) {
            hash_set_tag_value(data=>$info, tag => "$db:$tag", value => undef)
                unless hash_is_tag_defined(data=>$info, tag => "$db:$tag");
        }
    }
}

################################################################################
#########   Getting information part
################################################################################

sub info_get {
    my $info;

    my $disk_info = info_get_disk();
    unless (defined $disk_info) {
        _print_log('error', "Can't get info details for folder $current->{path}");
        return;
    }
#    say "disk info:";yaml_print($disk_info);
    $info = $disk_info;
    info_get_hack($info);

#    my $db_info;
#    unless (defined $run->{options}->{no_use_db_info}) {
#        $db_info = info_get_db($disk_info);
#    }
#    say "db info:";yaml_print($db_info);

#    $info = info_get_full(disk => $disk_info, db => $db_info);
#    yaml_print($info);

    return $info;
}

# getting info about title
sub info_get_disk {
    my $tmpinfo;
    _print_log('info', "get info from disk");
    if ( defined $current->{files}->{ $config->{name}->{info} } ) {
        _print_log('debug', "Using $config->{name}->{info} file to process $current->{path}");
        $tmpinfo = info_load( $config->{name}->{info} );
        unless (defined $tmpinfo) {
            _print_log('warning', "Can't load or parse $config->{name}->{info} file");
            return;
        }
    }
    else {
        if (fs_exists('.info') ) {
            # HACK
            croak "exists .info, but not .infotest";
        }
        $tmpinfo = info_get_name();
    }
#    yaml_print($tmpinfo);
    return $tmpinfo;
}

#get title details from it's name
sub info_get_name {
    _print_log('info', "Using name to process $current->{path}");
    my $tmpinfo = {};
    my @parts = split /[\(\)\[\]]/x , $current->{folder};
#    yaml_print(\@parts);

    my $tags = 0; # if there was at least one tag. it means title part ended
    for (my $i=0; $i < scalar @parts; $i++ ) {
        my $tag = $parts[$i];
        $tag =~ s/^\s+|\s+$//g;
        next if $tag eq '';
        if ($i == 0 ) {
            # first part always title, next one is also title ???
            if ($tag =~ /\p{CYRILLIC}/i) {
                $tmpinfo->{title}->{name}->{rus} ||= $tag
            }
            else {
                $tmpinfo->{title}->{name}->{eng} ||= $tag
            }
            next;
        }
        given ($tag) {
            when (/^(en|eng|ru|rus|de|ge|ger|it|bg|cz|de|fr|fre|ja|jp|es|ua|pl|kr|se|esp)$/i) {
                $tags = 1;
                $tag =~ s/rus/ru/;
                $tag =~ s/esp/es/;
                $tag =~ s/fre/fr/;
                $tag =~ s/eng/en/;
                $tag =~ s/ja/jp/;
                $tag =~ s/ger?/de/;

                my $old = $tmpinfo->{release}->{lang};
                my @parts = defined $old ? split /,/, $old : ();
                foreach (@parts) {
                    next if $tag =~ /^$_$/i;
                }
                $tmpinfo->{release}->{lang} = join(',', lc($tag), @parts);
            }
            when (/^(animation|documentary|video)$/i) {
                $tags = 1;
                $tmpinfo->{title}->{content} ||= lc($tag)
            }
            when (/^(3D|HDTV|DVD|1080p)$/i) {
                $tags = 1;
                my $old = $tmpinfo->{release}->{quality};
                my @parts = defined $old ? split /,/, $old : ();
                foreach (@parts) {
                    next if $tag =~ /^$_$/i;
                }
                $tmpinfo->{release}->{quality} = join(',', lc($tag), @parts);
            }
            when (/^\d{4}(-\d{4})?/) {
                $tags = 1;
                $tmpinfo->{title}->{year} ||= lc($tag)
            }
            default {
                if ( $tags == 1) {
                    my $old = $tmpinfo->{release}->{unknown};
                    my @parts = defined $old ? split /,/, $old : ();
                    foreach (@parts) {
                        next if $tag =~ /^$_$/i;
                    }
                    $tmpinfo->{title}->{unknown} = join(',', lc($tag), @parts);
                }
                else { # add title
                    if ($tag =~ /\p{CYRILLIC}/i) {
                        $tmpinfo->{title}->{name}->{rus} ||= $tag;
                    }
                    else {
                        $tmpinfo->{title}->{name}->{eng} ||= $tag
                    }
                }
            }
        }
    }
    return $tmpinfo;
}

# loading info from plugn db
sub info_get_db {
    my $info = shift || croak; # original data
    my $db_info; # hash for all db data

    # parsing indexes
    get_index(info => $info);

    # getting all data
    foreach ( keys %{$run->{db}} ) {
        next unless exists $config->{db}->{$_}->{tag};
        # TODO use all $info + $db_info to update db info
        my $tmpdata = $info->{$_} || $info->{title};
#        yaml_print($tmpdata);
        next unless defined $tmpdata;
#        _print_log('info', 'db', "get db data from [$_]");
        my $db_data = $proc->{db}->{get_info}->{$_}->( data => $tmpdata);
        $db_info->{$_} = $db_data if defined $db_data;
    }
    return $db_info;
}

sub info_get_hack {
    my $tmpinfo = shift || croak;
    say "DISK INFO BEFORE HACK";yaml_print($tmpinfo);

    # hack: move db->{data} to db->{db_index}->{data}
    my $found;
    title_get_index({info => $tmpinfo});
    if (defined $tmpinfo->{title}) {
        my $index = $current->{title}; # TODO !!!!!!!!
        say Dumper $index;
        if (defined $index) {
            my $tmp = dclone $tmpinfo->{title};
            delete $tmpinfo->{title};
            $tmpinfo->{title}->{$index} = $tmp;
            _print_log('warning', 'info hack', "moving title to title/$index");
            $found++;
        }
        else {
            _print_log('error', 'info hack', "can't find title index");
            $found++;
        }
    }
    if (defined $tmpinfo->{imdb}
        && (defined $tmpinfo->{imdb}->{code} || defined $tmpinfo->{imdb}->{url}) ) {
        my $code = $proc->{db}->{get_code}->{imdb}->(data => $tmpinfo->{imdb});
        croak unless defined $code;
        say $code;
        my $tmp = dclone $tmpinfo->{imdb};
        delete $tmpinfo->{imdb};
        $tmpinfo->{imdb}->{$code} = $tmp;
        _print_log('warning', 'info hack', "moving imdb to imdb/$code");
        $found++;
    }
    if (defined $tmpinfo->{kp}
        && (defined $tmpinfo->{kp}->{code} || defined $tmpinfo->{kp}->{url}) ) {
        my $code = $proc->{db}->{get_code}->{kp}->(data => $tmpinfo->{kp});
        croak unless defined $code;
        say $code;
        my $tmp = dclone $tmpinfo->{kp};
        delete $tmpinfo->{kp};
        $tmpinfo->{kp}->{$code} = $tmp;
        _print_log('warning', 'info hack', "moving kp to kp/$code");
        $found++;
    }

    # TODO - content = series,..... > move to kind

    if ($found) {
        say "DISK INFO AFTER HACK";
        yaml_print($tmpinfo);
        my $line = prompt("\nPress to continue? > ");
    }
}


# TODO
# calculate required tags in title: content, kind, origin, year, name, etc...
#title_get_final_info(disk => $disk_info, db => $db_info);
sub info_get_full {
    local %_ = @_;
    my %allowed_keys = (disk=>'',db=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $data = $_{disk} || croak;
    my $db_data = $_{db};
#    my ($data) = shift || croak;

    # merging db data to disk
    hash_set_tag_value_mass(
        data => $data,
        value => $db_data,
        no_protect => 1);

#    yaml_print($data);
    # remove not allowed tags
    foreach my $tag (keys %{$data->{title}}) {
        next if exists $config->{db}->{title}->{tags_allowed}->{$tag};
        _print_log('warning', "Deleting tag: title/$tag");
        delete $data->{title}->{$tag};
    }

    # calculate required values
    my @tags = hash_get_tags(data => $data->{title});
    my $new = {}; # just hash of already found values
    foreach (@tags) {
        my $tag = $_->{tag_name};

        #1. tag name
        my @parts = split /:/, $tag;
        my $tag_first = $parts[0];

        # skip tags
        next unless exists $config->{db}->{title}->{tags_required}->{$tag_first};
        #skip already found
        next if defined $new->{$tag};

        # tag value
        my $old = hash_get_tag_value(data => $data, tag => "title:$tag");
        hash_set_tag_value(data => $data, tag => "title:$tag", value => undef );
        my $value = get_tag_value(info => $data, tag => "title:$tag");
        $new->{$tag} = $value;
        $new->{$tag} = $old unless defined $new->{$tag};
        hash_set_tag_value(data => $data, tag => "title:$tag", value => $new->{$tag});
    }
    return $data;
}

=info_get_tag_value
Retrieve tag's value from .info.

- using origin
- multi-title info

# TODO rewrite for multiple titles and also searching in release part
# TODO support for param: origin, and orig
=cut
sub info_get_tag_value {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',tag=>'',origin=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $tag =  $_->{tag} || croak;

    if ($tag =~ /^release:(.+)/i) { # tag in release part
        my $value = hash_get_tag_value(data => $info,tag => $tag);
        return $value;
    }
    # else it's title's tag
    if ($tag =~ /^title:(.+)/i) { # tag in title part
        $tag = $1;
    }

    ### determine what title to use
    my $title_index;
    my @titles = info_titles({info=>$info});
    croak "Not found any titles" unless scalar @titles;
    if (scalar @titles > 1) { # many titles (repack or official collection)
        if (defined $info->{title}->{'0'}) {
            # TODO
            if (defined $info->{title}->{'0'}->{primary}) {
                $title_index = $info->{title}->{'0'}->{primary}; # index of primary title
            }
            else {
                # if doesn't exist official (with ext db) primary title
                $title_index = '0';
            }
        }
        else {
            _print_log('error', 'info', "Can't find primary title/0 for collection of titles");
            croak;
        }
    }
    else { # if one title: create name from it
        $title_index = $titles[0];
    }

    my $value = title_get_tag_value({info=>$info,title=>$title_index,tag=>$tag});
    return $value;
}

# TODO title_get_origin
sub info_get_origin {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;

    my $origin = info_get_tag_value({info=>$info,tag=>'origin'});
    my $orig;
    if (defined $origin) {
        if ($origin =~ /(russian|soviet)/i) {$orig = 'rus';}
        elsif ($origin =~ /(eng)/i)         {$orig = 'eng';}
        else {_print_log('error', 'name', "Unknown origin: $origin");}
    }
    unless (defined $orig) { # default
        # TODO choose from criteria: name, country
        $orig = 'eng';
    }
    return $orig;
}

# return content of title
# TODO title_get_content
# TODO $content_main(:$content_subtype)*
sub info_get_content {
    local %_ = @_;
    my %allowed_keys = (data=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $data = $_{data} || croak;

    if (defined $current->{content}) {
        return $current->{content};
    }

    my $content_type = info_get_tag_value(info=>$data,tag=>'content');
    return unless defined $content_type;
    my $content;
    # hack
    if ($content_type =~ /^(movie|series)$/i) {
        $content = 'video';
    }
    if ($content_type =~ /^(animation|tv|video|documentary|reality tv|anime)$/i) {
        $content = 'video';
    }
    if (!defined $content && $content_type =~ /^video:(.+)/i) {
        $content = 'video';
        # TODO check for allowed $1
    }
    if (defined $content) {
        $current->{content} ||= $content;
        return $content;
    }
    else {
        _print_log('error', "Undefined content in $current->{path}");
        return;
    }
}

#my @titles = info_titles({info=>$info});
sub info_titles {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    # TODO if multipe titles: check if in release part the same titles
    my $info = $_->{info} || croak;

    return keys %{ $info->{title} };
}

################################################################################
#########   Title processing part
################################################################################

=info_get_index
TODO for all titles

#info_get_index( {info => $info);

sub info_get_index {
    foreach ( info_titles() ) {title_get_index({info=>$info,title=>$_})};
}
=cut

=title_get_index
input:
  info: info data
  title: title index
  db: 'title'/'name of external db'
output:
  index of current title in 'db'
  + assign $current->{title}->{index}->{$db} and for each newly found db index

#title_get_index( {info => $info, title => $title });
=cut
sub title_get_index {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',title=>'',db=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $title = $_->{title} || croak;
    my $db = $_->{db};

    if (defined $db && defined $current->{title}->{$title}->{index}->{$db}) {
        return $current->{title}->{$title}->{index}->{$db};
    }

    # for symmetry
    $current->{title}->{$title}->{index}->{title} = $title;

    if (defined $info) {
        # get all codes from title data
        # TODO check for existing db data for all codes (but somewhere else)
        my $codes = $info->{title}->{$title}->{codes};
        if (defined $codes) {
            foreach my $db ( keys %{ $codes } ) {
                unless (exists $config->{db}->{$db}) {
                    _print_log('error', 'info', "Unknown db in .info: $db");
                    next;
                }
                # TODO check for existing and not equal value
                $current->{title}->{$title}->{index}->{$db} = $codes->{$db};
            }
        }
    }

    if (defined $db && defined $current->{title}->{$title}->{index}->{$db}) {
        return $current->{title}->{$title}->{index}->{$db};
    }
    # TODO if returned value REF, do nothing; return $ref
    # TODO if returned value '', convert it to REF: $ref->{$value}=undef;return $ref;
    return;
}

=title_get_tag_value
Retrieve tag's value for one given title.

#title_get_tag_value({info=>$info,title=>$title_index,tag=>$tag});
=cut
sub title_get_tag_value {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',title=>'',tag=>'',origin=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $title = $_->{title} || croak;
    my $tag =  $_->{tag} || croak;
    my $origin =  $_->{origin};


    # order of importance
    # TODO create sub db_ordered;
    my @db_order;
    # using origin
    $origin ||= hash_get_tag_value(data => $info,tag => "title:$title:origin");
    if (defined $origin) {
        @db_order = sort {
            $config->{db}->{$a}->{order}->{origin}->{$origin} <=>
            $config->{db}->{$b}->{order}->{origin}->{$origin}}
        grep {exists $config->{db}->{$_}->{order}->{origin}->{$origin}}
        grep {exists $config->{db}->{$_}->{tag}}
        keys %{$config->{db}};
    }
    else {
        @db_order = sort {
            $config->{db}->{$a}->{order}->{default} <=>
            $config->{db}->{$b}->{order}->{default}}
        grep {exists $config->{db}->{$_}->{order}->{default}}
        grep {exists $config->{db}->{$_}->{tag}}
        keys %{$config->{db}};
    }

    my $value = hash_get_tag_value(data => $info,tag => "title:$title:$tag");
    foreach my $db (@db_order) {
        next if $db eq 'title';
        my $db_indexes = title_get_index({info=>$info,title=>$title,db=> $db});
        next unless defined $db_indexes;
        next if scalar keys %{$db_indexes} > 1;
        foreach my $db_index (keys %{$db_indexes}) {
            $value ||= hash_get_tag_value(data => $info,tag => "$db:$db_index:$tag");
        }
        last if defined $value;
    }
    return $value;
}

# TODO somewhere it should be used
sub title_add_new {
    return db_add_title();
}

# save data from .info to db
#title_update_db({info=>$info,title=>$title});
sub title_update_db {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',title=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $title = $_->{title} || croak;

    ### add current path to paths
    title_update_db_paths({ title=>$title, path=>$current->{path} });

    ### update title db data
    title_get_index( {info => $info, title => $title });
    # TODO ???? update indexes??
    foreach my $db ( keys %{ $current->{title}->{$title}->{index} } ) {
        next unless exists $config->{db}->{$db};
        next unless exists $config->{db}->{$db}->{tag};
        foreach my $index (keys %{ $current->{title}->{$title}->{index}->{$db} } ) {
            unless (defined $info->{$db}->{$index}) {
                _print_log('error', 'info', "Not found data on title=$title $db=$index");
                next;
            }
            db_save_data(
                db_name => $db,
                tag => "$index:data",
                value => $info->{$db}->{$index},
                update => 1);
            _print_log('info', 'db', "Updated db: $db=$index");
        }
    }
}

#title_update_db_paths({title=>$title,path=>$current->{path}});
sub title_update_db_paths {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (path=>'',title=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $title = $_->{title} || croak;
    my $path = $_->{path} || croak;

    # HACK for paths
    if (defined $proc->{hack}->{db_path}) {
        $proc->{hack}->{db_path}->(\$path);
    }

    # title info part
    db_save_data(
        db_name => 'title',
        tag => "$title:paths:$path",
        value => 1);
}

# TODO move somewhere
#db_update_indexes;
sub title_update_db_indexes {
    say "STUB: db_update_indexes";return;
#    my $indexes = shift || croak;
#
#    # always return an integer - add new title if needed
#    if (!defined $indexes->{title}) {
#        # TODO add new index only if defined at least ine external db index
#        $indexes->{title} = ++$db_index;
#        _print_log('info', 'db', "Added new title index: $indexes->{title}");
#    }
#
#    # TODO not one-to-one indexes (one imdb index >> includes 3 kp indexes)
#    foreach my $index1 (keys %$indexes) {
#        foreach my $index2 ( keys %{$indexes} ) {
#            next if $index1 eq $index2;
#            db_save_data(
#                db_name => $index1,
#                tag => "$indexes->{$index1}:index:$index2",
#                value => $indexes->{$index2});
#            db_save_data(
#                db_name => $index2,
#                tag => "$indexes->{$index2}:index:$index1",
#                value => $indexes->{$index1});
#        }
#    }
}

$proc->{hack}->{db_path} ||= sub {
    my $pathref = shift || croak;
    if ($$pathref =~ /\/mnt\/(.*)/i) {
        $$pathref = $1;
    }
};

=about
Searches duplicates of given title in given folder and prints paths to them
Input: .info
=cut
sub title_dupes {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (title=>'',path=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $title = $_->{title} || croak;
    my $path = $_->{path};

    my $found = 0;
    my $first = 1;
    my $db_data = db_get_data(db_name => 'title', tag => "$title:paths");
    return $found unless defined $db_data;
    foreach my $path ( keys %{$db_data} ) {
        if (defined $path) {
            next if index($current->{path}, $path) >= 0;
        }
        # TODO calculate name (instead of $title)
        say "Title $title is also in folders:" if $first; # at least one path known
        $first = 0;
        $found++;
        say $path;
    }
    return $found;
}

################################################################################
#########   DB Informations part
################################################################################

# loading info from plugn d
$proc->{db}->{get_info}->{default} ||= sub {
    local %_ = @_;
    my %allowed_keys = (data=>'',db=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    croak unless defined $_{db};
    my $db = $_{db};
    my $data = $_{data};
    return unless db_is_loaded (db_name => $db);
    _print_log('info', 'db', "getting db data from [$db]");

    if (defined $run->{options}->{ext}) {
        # updating
        last unless defined $proc->{db}->{update_info}->{$db};
        undef $run->{options}->{ext};
        $proc->{db}->{update_info}->{$db}->(data => $data);
        $run->{options}->{ext} = 1;
    }

    # loading db data
    my $index = get_index(db => $db) || $proc->{db}->{get_code}->{$db}->(data => $data);
    return unless defined $index;
    _print_log('info', 'db', "getting db data: $db/$index");
    $current->{db}->{data}->{$db} = db_get_data( db_name => $db, tag => "$index:data");
    return $current->{db}->{data}->{$db};
};

# TODO other options: clear_cache, debug, etc...
$proc->{db}->{update_info}->{default} ||= sub {
    local  %_ = @_;
    my %allowed_keys = (data=>'',db=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $db = $_{db};
    my $data = $_{data}; # can be undefined
    _print_log('info', 'update_info', "updating db: $db");
    print BOLD, BLUE, "\nSearching in $db\n", RESET;

    # search criteria
    my %opts;
    my $code = get_index(db => $db) || $proc->{db}->{get_code}->{$db}->(data => $data);
    if (defined $code) {
        _print_log('info', 'update_info', "using code $code for retrieving data");
        my $url = $proc->{db}->{get_url}->{$db}->(code => $code);
        $opts{method} = 'query';
        $opts{url} = $url;
    }
    else {
        my $name;
        # order of name chosing
        # HACK name order - by plugin
        my @order = ('name:orig', 'name:eng', 'name:rus' );
        foreach ( @order ) {
            $name = hash_get_tag_value(data => $data, tag => $_);
            last if defined $name;
        }
        if (defined $proc->{hack}->{$db}->{search_name}) {
            $proc->{hack}->{$db}->{search_name}->(\$name);
        }
        $opts{method} = 'search';
        $opts{crit} = $name;
        _print_log('info', 'update_info', "using name $name for retrieving data");
    }
    $opts{year} = hash_get_tag_value(data => $data, tag => 'year');

    # getting info about film
    my $ext_data = $proc->{db}->{get_data}->{$db}->(%opts);
    return unless defined $ext_data;
    # TODO print found $ext_data url

    # processing film info
    if($ext_data->status) {

        # updating current code (if first time seen)
        $code ||= $ext_data->code;
        return unless defined $code;
        $current->{db}->{index}->{$db} ||= $code;

        # loading db data
        _print_log('info', 'update_info', "Loading db data");
        my $db_data = $proc->{db}->{get_info}->{$db}->( data => $data);
#        yaml_print($db_data);

        # parsing returned info
        _print_log('info', 'update_info', "Parsing returned info");
        foreach ( @{ $run->{db}->{tags}->{$db} } ) {
            $proc->{db}->{$db}->{parse_tag}->{$_}->(data => $db_data, ext_data => $ext_data);
        }
        yaml_print($db_data);
        $current->{db}->{data}->{$db} = $db_data;

        # TODO saving updated data (to cache)
        _print_log('info', 'update_info', "Saving updated db data");
        db_save_data(
            db_name => $db,
            tag => "$code:data",
            value => $db_data,
            no_protect => 1); # TODO option
        return $db_data;

    } else {
        print "Something wrong: ".$ext_data->error();
        _print_log("warning", "Can't get $db data");
        return;
    }
};

# TODO
$proc->{db}->{get_info}->{title} ||= sub {
    return $proc->{db}->{get_info}->{default}->(db => 'title', %_);
};

# TODO
$proc->{db}->{get_info}->{release} ||= sub {
    return;
    return $proc->{db}->{get_info}->{default}->(db => 'release', %_);
};

$proc->{db}->{get_data}->{default} ||= sub {
    my (%opts) = @_;
    my $plugin = $opts{db} || croak;
#    say $plugin;
#    yaml_print(\%opts);
    unless (defined $opts{crit} || defined $opts{url}) {
        _print_log('error', $plugin , "not defined search criteria");
        return;
    }

    my @tmp;
    my $i = 0;
    my $print_title ||= sub {
        local %_ = @_;
        print color 'bold yellow';
        printf ("%-4d", $i);
        print color 'reset';
        printf (" >> %s >> ", $_{url});
        print color 'bold yellow';
        if (defined $opts{year}) {
            my ($year) = $opts{year} =~ /^(\d{4})/;
            print color 'bold red'  if defined $_{year} && $_{year} =~ /^$year/i;
        }
        printf "%s", ($_{year} || '????' );
        print color 'reset';
        say " >> " . $_{text};
        $tmp[$i] = $_{url};
        $i++;
    };
    my $ext_data;
    if (defined $opts{url}) { # title already known
        $ext_data = $proc->{db}->{_get_data}->{$plugin}->(%opts);
        $print_title->(url=>$ext_data->url, year => $ext_data->year, text => $ext_data->title);
    }
    elsif (defined $opts{crit}) { # searching for title
        say $plugin;
        $ext_data = $proc->{db}->{_get_data}->{$plugin}->(%opts);
        say "Found using $plugin with search criteria: ".
            (defined $opts{crit} ? "\n\ttitle: $opts{crit} " : "").
            (defined $opts{url}  ? "\n\turl: $opts{url} " : "").
            (defined $opts{year} ? "\n\tyear: $opts{year} " : "");
        if (defined $ext_data) {
            if (defined $ext_data->code) { # if redirected to found title
                $print_title->(url=>$ext_data->url, year => $ext_data->year, text => $ext_data->title);
            }
            elsif (defined $ext_data->matched) {
                foreach (@{$ext_data->matched}) {
                    if (ref $_) {
                        $print_title->(url=>$_->{url}, year => $_->{year}, text => $_->{text});
                    }
                    else {
                        print color 'bold yellow';
                        say "\n$_ >>>";
                        print color 'reset';
                    }
                }
            }
        }
        say "$i  skip $plugin ";
        # prompt
        my $id = prompt -i, -d=>0 , "\nWhat id to use ? [default: 0] > ";
        if ($id == 0 && defined $ext_data && defined $ext_data->code) {
            $ext_data = $ext_data;
        }
        elsif ($id < $i) {
            _print_log('debug', "Downloading url=$tmp[$id]");
            $ext_data = $proc->{db}->{_get_data}->{$plugin}->( method => 'query' , url => $tmp[$id] );
        }
        elsif ($id > $i) {
            _print_log('debug', "Downloading code=$id");
            $ext_data = $proc->{db}->{_get_data}->{$plugin}->( method => 'query' , crit => $id );
        }
        else {
            _print_log('info', "Manually skipped $plugin search");
            undef $ext_data;
        }
    } # end of search

    return unless defined $ext_data && defined $ext_data->code;
    return $ext_data;
};

$proc->{db}->{get_code}->{default} ||= sub {
    local %_ = @_;
    my %allowed_keys = (db=>'',data=>'',url=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $db = $_{db} || croak;
    my $data = $_{data};
    my $url = $_{url};
    croak unless defined $data || defined $url;

    unless (defined $url ) {
        return unless defined $data;
        return $data->{code} if defined $data->{code};
        $url = $data->{url} if defined $data->{url};
    }
    return unless defined $url;

    # url_to_code
    return unless defined $proc->{db}->{url_to_code}->{$db};
    return $proc->{db}->{url_to_code}->{$db}->($url);
};

$proc->{db}->{get_url}->{default} ||= sub {
    local %_ = @_;
    my %allowed_keys = (db=>'',data=>'',url=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    my $db = $_{db} || croak;
    my $data = $_{data};
    my $code = $_{code};
    croak unless defined $data || defined $code;

    unless (defined $code ) {
        return unless defined $data;
        return $data->{url} if defined $data->{url};
        $code = $data->{code} if defined $data->{code};
    }
    return unless defined $code;

    # code_to_url
    return unless defined $proc->{db}->{code_to_url}->{$db};
    return $proc->{db}->{code_to_url}->{$db}->($code);
};

1;
