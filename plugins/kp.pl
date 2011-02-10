#!/usr/bin/perl -w
use strict;
no strict 'refs';
use warnings;
use diagnostics;
use Data::Dumper;
use Carp;
use IO::Prompt;
use feature ":5.10";
#use encoding 'utf8';

#local libs
use FindBin qw($Bin);
use lib "$Bin/../lib";
use MovieDB::Kinopoisk;
#use Lingua::DetectCyrillic;

### global vars
our ($config, $run, $current, $proc);

### vars
my $plugin = 'kp';
my $kp_parse = {};

# fill content and kind
#$proc->{db}->{$db}->{parse_tag}->(data => $db_data, ext_data => $ext_data);
$proc->{db}->{$plugin}->{parse_tag}->{content} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;

    #kind : TV Series, Movie, etc.. only for missing
    my $content;
    if ($ext_data->kind =~ /movie|video|tv/i) {
       $content =  "movie";
    }
    elsif ($ext_data->kind eq "series") {
       $content =  "series";
    }
    else {
        _print_log('warning', $plugin, "Unknown content:".$ext_data->kind );
    }

    my $genres;
    $genres = join( ',' , @{$ext_data->genres} ) if $ext_data->genres;
    my $kind;
    if (defined  $genres && $genres =~ /мультфильм/i) {
        $kind = $content;
        $content = 'animation';
    }
    elsif (defined $genres && $genres =~ /документальный/i) {
        $kind = $content;
        $content = 'documentary';
    }
    elsif (defined $genres && $genres =~ /реальное ТВ/i) {
        $kind = $content;
        $content = 'reality tv';
    }
    elsif (defined $genres && $genres =~ /аниме/i) {
        $kind = $content;
        $content = 'anime';
    }
    hash_set_tag_value(tag => 'kind', value => $kind, data => $data) if defined $kind;
    hash_set_tag_value(tag => 'content', value => $content, data => $data) if defined $content;
};

# fill in year
$proc->{db}->{$plugin}->{parse_tag}->{year} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;
    return if hash_is_tag_protected(data => $data, tag => 'year');

    my $year = $ext_data->year;
    hash_set_tag_value(tag => 'year', value => $year, data => $data);
};

# fill in  code
$proc->{db}->{$plugin}->{parse_tag}->{code} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;

    my $code = $ext_data->code;
    hash_set_tag_value(tag => 'code', value => $code, data => $data);
};

# fill in url
$proc->{db}->{$plugin}->{parse_tag}->{url} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;

    my $url = $ext_data->url;
    hash_set_tag_value(tag => 'url', value => $url, data => $data);
};


# fill in names
$proc->{db}->{$plugin}->{parse_tag}->{names} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;
    return if hash_is_tag_protected(data => $data, tag => 'name:rus');

    my $rus = $ext_data->title;
    hash_set_tag_value(tag => 'name:rus', value => $rus, data => $data);
    # TODO add original AKA
};

$proc->{db}->{$plugin}->{parse_tag}->{countries} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;
    return if hash_is_tag_protected(data => $data, tag => 'country');

    my $countries;
    $countries = join( ',' , @{$ext_data->countries } ) if defined $ext_data->countries;
    hash_set_tag_value(tag => 'country', value => $countries, data => $data);
};

$proc->{db}->{$plugin}->{parse_tag}->{genres} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;
    return if hash_is_tag_protected(data => $data, tag => 'genres');

    my $genres;
    $genres = join( ',' , @{$ext_data->genres} ) if $ext_data->genres;
    hash_set_tag_value(tag => 'genres', value => $genres, data => $data);
};

$proc->{db}->{$plugin}->{parse_tag}->{cast} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;
    return if hash_is_tag_protected(data => $data, tag => 'cast');

    my $cast;
    $cast = join(',' , keys %{$ext_data->cast}) if $ext_data->cast;
    hash_set_tag_value(tag => 'cast', value => $cast, data => $data);
};

### db subs

$proc->{db}->{init}->{kp_top250} ||= sub {
    my $db_name = 'kp_top250';
    return unless db_is_loaded(db_name => $db_name);
    unless (db_get_data_keys({db_name => $db_name})) {
        $proc->{db}->{update}->{$db_name}->();
    }
};

$proc->{db}->{update}->{kp_top250} ||= sub {

    # gettin top
    my %opts;
    $opts{method} = 'query';
    $opts{crit} = 'top250';
    $opts{debug} = '1';
    $opts{url} = 'http://www.kinopoisk.ru/level/20/';

    my $ext_data = $proc->{db}->{_get_data}->{$plugin}->( %opts,
        cache_root          => "$run->{paths}->{cache}/kp_top250",
        parsed_cache_root   => "$run->{paths}->{cache}/kp_top250_parsed",
        cache_exp           => '1 d',
        parsed_cache_exp    => '1 d',
    );
    my $top250;
    if (defined $ext_data) {
        if ($ext_data->status) {
            $top250 = $ext_data->top250();
        }
        else {
            print "Something wrong: ".$ext_data->error();
        }
    }

    # updating db with new data
    if (defined $top250 && scalar keys %$top250 == 250 ) {
        db_truncate(db_name => 'kp_top250');
        db_save_data(
            db_name => 'kp_top250',
            value => $top250);
        db_dump(db_name => 'kp_top250');
    }
    else {
        _print_log('error', $plugin, "Can't update $plugin top");
    }
    return;
};


$proc->{db}->{symlink}->{kp_top250} ||= sub {
    my $info = shift || return; # $info
    my $db_name = 'kp_top250';
#    say $db_name;
    return unless db_is_loaded(db_name => $db_name);
    my $code = $proc->{db}->{get_code}->{$plugin}->( data => $info);
    return unless defined $code;
    my $place = db_get_data (db_name => $db_name, tag => $code);
    return unless defined $place;

    my $path = $current->{publicpath};
    my $dest_path = File::Spec->catdir($run->{paths}->{public}, 'top', 'kinopoisk top 250');
    my $dest_name = create_folder_name( info => $info);
    $dest_name = sprintf "%03s. %s", $place, $dest_name;
    _print_log('info', $db_name, "Found kinopoisk top 250: [$dest_name]");

    _symlink_create(
        source      => $path,
        dest_path   => $dest_path,
        dest_name   => $dest_name,
        type        => 'relative');

    return 1; # number of created symlinks
};

### plugin's subs

$proc->{hack}->{$plugin}->{search_name} ||= sub {
    # kinopoisk hack - delete starting 'the'
    my $name_ref = shift || croak;
    $$name_ref =~ s/^the\s+//i;
};


# getting and updating (optionally) db data
$proc->{db}->{get_info}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_info}->{default}->(db => $plugin, %_);
};

# updating db data
$proc->{db}->{update_info}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{update_info}->{default}->(db => $plugin, %_);
};

$proc->{db}->{get_info}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_info}->{default}->(db => $plugin, %_);
};

$proc->{db}->{get_data}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_data}->{default}->(db => $plugin, %_);
};

$proc->{db}->{get_code}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_code}->{default}->(db => $plugin, %_);
};

$proc->{db}->{get_url}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_url}->{default}->(db => $plugin, %_);
};

#Wrapper for  new MovieDB::Kinopoisk with given options and exception catching
$proc->{db}->{_get_data}->{$plugin} ||= sub {
    my %opts = @_;
#    say Dumper %opts;
    my $ext_data;

    $opts{cache}                ||= 1;
    $opts{parsed_cache}         ||= 1;
    $opts{cache_root}           ||= "$run->{paths}->{cache}/kp";
    $opts{parsed_cache_root}    ||= "$run->{paths}->{cache}/kp_parsed";
    $opts{cache_exp}            ||= '10 d';
    $opts{parsed_cache_exp}     ||= '10 d';

    $opts{timeout}              ||= 20;
    $opts{decode_html}          ||= 1;
    $opts{cookies}              ||= "$run->{paths}->{script_home}/cookies.txt";
#    $opts{debug}                ||= 1;

    eval {
        $ext_data = new MovieDB::Kinopoisk( %opts );
    };
    if($@) {
            # Opsssss! We got an exception!
            print "EXCEPTION: $@!";
            return;
    }
    return $ext_data;
};

$proc->{db}->{code_to_url}->{$plugin} ||= sub {
    return "http://www.kinopoisk.ru/level/1/film/$_[0]";
};

$proc->{db}->{url_to_code}->{$plugin} ||= sub {
    my $url_to_code = 'level\/1\/film\/(\d+)';
    if ($_[0] =~ qr{$url_to_code} ) {
        return $1;
    }
    else {
        _print_log('warning', $plugin, "get_code: Wrong $plugin title url");
    }
};

$proc->{plugin}->{$plugin}->{init} ||= sub {
#    say "init plugin: $plugin";
    # TODO load custom config into $config
    # TODO check if plugin is working write
    @{$run->{db}->{tags}->{$plugin}} = qw{content url code year names countries genres cast};

};
$proc->{plugin}->{$plugin}->{init}->();

1;

=about
Parse kinopoisk.ru for data
http://www.kinopoisk.ru/level/404/

Медиа
# Фотографии                http://www.kinopoisk.ru/level/13/
# Обои                      http://www.kinopoisk.ru/level/12/view/main/
# Постеры                   http://www.kinopoisk.ru/level/17/view/main/
# Трейлеры                  http://www.kinopoisk.ru/level/16/
# Подкасты                  http://www.kinopoisk.ru/level/58/
# Саундтреки                http://www.kinopoisk.ru/level/93/

>>>level/1/film/276762/ film

level/10/m_act[year]/2009/
???level/10/m_act[country]/3/
>>>level/10/m_act[genre]/3/  genre
level/10/m_act[company]/12/

level/12/film/276762/ walppapers
level/13/film/276762/ screenshots ??
level/13/film/276762/ ??? photos
level/15/film/276762/ sites
level/16/film/276762/ trailers
level/17/film/276762/ posters
18 -
>>>level/19/film/276762/ cast, directors, writers, etc...

MPAA rating
level/38/film/276762/rn/PG-13/

level/80/film/276762/ release date
level/83/film/276762/ rating
level/85/film/276762/ budget, money

TODO
1. measures agains ban - google cache ?
=cut