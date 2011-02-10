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
use MovieDB::IMDB;
use Lingua::DetectCyrillic;

### global vars
our ($config, $run, $current, $proc);

### vars
my $plugin = 'imdb';
my $imdb_parse = {};

# fill content and kind
$proc->{db}->{$plugin}->{parse_tag}->{content} ||= sub {
    local %_ = @_;
    my $data = $_{data};
    my $ext_data = $_{ext_data} || croak;

    #kind : TV Series, Movie, etc.. only for missing
#    say "content = ".$ext_data->kind;
    my $content;
    if ($ext_data->kind =~ /series/i) {
       $content =  "series";
    }
    elsif ($ext_data->kind =~ /movie|video|tv/i) {
       $content =  "movie";
    }
    else {
        _print_log('warning', $plugin, "Unknown content:".$ext_data->kind );
    }

    my $genres;
    $genres = join( ',' , @{$ext_data->genres} ) if $ext_data->genres;
    my $kind;
    if (defined  $genres && $genres =~ /animation/i) {
        $kind = $content;
        $content = 'animation';
    }
    elsif (defined $genres && $genres =~ /documentary/i) {
        $kind = $content;
        $content = 'documentary';
    }
    elsif (defined $genres && $genres =~ /Reality-TV/i) {
        $kind = $content;
        $content = 'reality tv';
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

# fill in code
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

    # finding fitting names
    my (%eng,%orig);
    my $title = $ext_data->title();
    unless ($title =~ /\p{CYRILLIC}/) {
        $orig{ $title } = "Main IMDB Title";
        $eng { $title } = "Main IMDB Title";
    }
    if (defined $ext_data->also_known_as ) {
        foreach ( @{$ext_data->also_known_as } ) {
            next
                if $_->{where} =~ /(working|original script|promotional|subtitle|poster|credits)/i;
            $eng{  $_->{aka} } ||= $_->{where}
                if $_->{where} =~ /(USA|UK|English|International|original|undefined)/i
                && $_->{where} !~ /IMAX/i;
            $orig{ $_->{aka} } ||= $_->{where}
                if $_->{where} =~ /original/i;
        }
    }
    else {
        $eng {$ext_data->title } = "Main IMDB Title";
    }

    # dumping all names
    say "Title\t >> ".$ext_data->title();
    if (scalar keys %eng) {
        say "English Titles";
        printf("\t%-20s >> %s\n", $_, $eng{$_} )
            foreach keys %eng;
    }
    if (scalar keys %orig) {
        say "Original Titles";
        printf("\t%-20s >> %s\n", $_, $orig{$_} )
            foreach keys %orig;
    }

    # choosing name
    my $imdb_choose_names ||= sub {
        my ($lang, $tag, %hash) = @_;
        return if scalar keys %hash == 0;
        if (scalar keys %hash < 2) {
            my @tmp = keys %hash;
            return $tmp[0];
        }

        # interactive prompt
        my $i = 0;
        my @hash = ();
        say "";
        foreach ( sort keys %hash) {
            printf("\t%-4d: %-20s >> %s\n", $i, $_, $hash{$_} );
            $hash[$i] = $_;
            $i++;
        }
        my $ch;
        my $id;
        while (1) {
            $id = prompt -i, -d=>0 , "What $lang title to use? [default:0] ";
            last if $id < scalar @hash;
        };
        $ch = $hash[$id];
        hash_set_tag_value(data => $data, tag => "_protected:$tag", value => undef);
        _print_log('info', "Chosen $lang Title: $ch");
        return $ch;
    };

    my ($eng,$orig);
    if (hash_is_tag_protected(data => $data, tag => 'name:eng')) {
        $eng = hash_get_tag_value(data => $data, tag => 'name:eng');
    }
    else {
        $eng = $imdb_choose_names->('English', 'name:eng', %eng);
    }
    _print_log('info', "Chosen English Title: $eng") if defined $eng;

    if (hash_is_tag_protected(data => $data, tag => 'name:orig')) {
        $orig = hash_get_tag_value(data => $data, tag => 'name:orig');
    }
    else {
        $orig = $imdb_choose_names->('Original', 'name:orig', %orig);
    }
    _print_log('info', "Chosen Original Title: $orig") if defined $orig;

    # cleaning names
    $eng = $orig unless defined $eng;
    undef $orig if defined $eng && defined $orig && $orig eq $eng;
    # TODO unidecode ????

    if ($ext_data->kind =~ /series/i) {
        $eng =~ s/^"(.*)"$/$1/
            if defined $eng;
        $orig =~ s/^"(.*)"$/$1/
            if defined $orig;
    }

    hash_set_tag_value(data => $data, tag => 'name:orig', value => $orig);
    hash_set_tag_value(data => $data, tag => 'name:eng', value => $eng);
};

# fill in country
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

$proc->{db}->{init}->{imdb_top250} ||= sub {
    my $db_name = 'imdb_top250';
    return unless db_is_loaded(db_name => $db_name);
    unless (db_get_data_keys({db_name => $db_name})) {
        $proc->{db}->{update}->{$db_name}->();
    }
};

$proc->{db}->{update}->{imdb_top250} ||= sub {
    # getting top
    my %opts;
    $opts{method} = 'query';
    $opts{crit} = 'top250';
    $opts{debug} = '1';
    $opts{url} = 'http://www.imdb.com/chart/top';

    my $ext_data = $proc->{db}->{_get_data}->{$plugin}->( %opts,
        cache_root          => "$run->{paths}->{cache}/imdb_top250",
        parsed_cache_root   => "$run->{paths}->{cache}/imdb_top250_parsed",
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
        db_truncate(db_name => 'imdb_top250');
        db_save_data(
            db_name => 'imdb_top250',
            value => $top250);
        db_dump(db_name => 'imdb_top250');
    }
    else {
        _print_log('error', $plugin, "Can't update $plugin top");
    }
};

### symlink subs

$proc->{db}->{symlink}->{imdb_top250} ||= sub {
    my $info = shift || return; # $info
    my $db_name = 'imdb_top250';
#    say $db_name;
    return unless db_is_loaded(db_name => $db_name);
    my $code = $proc->{db}->{get_code}->{$plugin}->( data => $info);
    return unless defined $code;
    my $place = db_get_data (db_name => $db_name, tag => $code);
    return unless defined $place;

    my $path = $current->{publicpath};
    my $dest_path = File::Spec->catdir($run->{paths}->{public}, 'top', 'imdb top 250');
    my $dest_name = create_folder_name( info => $info);
    $dest_name = sprintf "%03s. %s", $place, $dest_name;
    _print_log('info', $db_name, "Found imdb top 250: [$dest_name]");

    _symlink_create(
        source      => $path,
        dest_path   => $dest_path,
        dest_name   => $dest_name,
        type        => 'relative');

    return 1; # number of created symlinks
};

### plugin's subs

#Get title details from imdb

$proc->{db}->{get_info}->{$plugin} ||= sub {
    local %_ = @_;
    return $proc->{db}->{get_info}->{default}->(db => $plugin, %_);
};

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

#Wrapper for  new MovieDB::IMDB with given options and exception catching
$proc->{db}->{_get_data}->{$plugin} ||= sub {
    my (%opts) = @_;
#    $opts{crit} =~ s/&/ /g if $opts{crit};

    $opts{cache}                ||= 1;
    $opts{parsed_cache}         ||= 1;
    $opts{cache_root}           ||= "$run->{paths}->{cache}/imdb";
    $opts{parsed_cache_root}    ||= "$run->{paths}->{cache}/imdb_parsed";
    $opts{cache_exp}            ||= '10 d';
    $opts{parsed_cache_exp}     ||= '10 d';

    $opts{timeout}              ||= 20;
    $opts{decode_html}          ||= 1;
    $opts{cookies}              ||= "$run->{paths}->{script_home}/cookies.txt";
#    $opts{debug}                ||= 1;

    my $ext_data;
    eval {
        $ext_data = new MovieDB::IMDB( %opts );
    };
    if($@) {
            # Opsssss! We got an exception!
            print "EXCEPTION: $@!";
            return;
    }
    return $ext_data;
};

$proc->{db}->{code_to_url}->{$plugin} ||= sub {
    return "http://www.imdb.com/title/tt$_[0]";
};

$proc->{db}->{url_to_code}->{$plugin} ||= sub {
    my $url_to_code = 'title\/tt(\d+)';
    if ($_[0] =~ qr{$url_to_code} ) {
        return $1;
    }
    else {
        _print_log('warning', $plugin, "get_code: Wrong $plugin title url");
    }
};

$proc->{plugin}->{$plugin}->{init} ||= sub {
#    say "init plugin: $plugin";
    if (defined $config->{plugins}->{$plugin}->{config} ) {
        # TODO load custom config into $config
    }
    # TODO check if plugin is working write

    @{$run->{db}->{tags}->{$plugin}} = qw{content url code year names countries genres cast};

};
$proc->{plugin}->{$plugin}->{init}->();

1;

## detecting charset for russian title
#    foreach (keys %rus) {
#        next unless $_ =~ /\p{CYRILLIC}/i;
#        say "\n$_\t    $rus{$_}";
#        my $str = $_;
#        # detect encoding
#        my $CyrDetector = Lingua::DetectCyrillic->new();
#        my ($encoding,$lang,$Chars,$Algorithm);
#        ($encoding,$lang,$Chars,$Algorithm) = $CyrDetector->Detect( $str );
##        $CyrDetector -> LogWrite();
#        if ($encoding !~ /(cp1251|iso)/ ) {
#            say "$encoding\t$lang";
#            my $tmp = decode('cp1251', encode($encoding, $str));
#            $rus{$tmp} = $rus{$_};
#            delete $rus{$_};
#            _print_log('debug', "Converted title from $encoding to cp1251", $tmp);
#        }
#    }
