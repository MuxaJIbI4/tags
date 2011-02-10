#/usr/bin/perl -w
package MovieDB::Kinopoisk;
use base qw(MovieDB::BaseClass);
use strict;
use warnings;
# for building "inside-out" objects
use Class::Std::Utils;
# for HTML parsing
use HTML::TreeBuilder;
# for url creating
use URI::Escape; # uri_escape()  uri_unescape()
use Encode;
# devel
use Carp;
use Data::Dumper;
use encoding 'utf8';
use feature ':5.10';

# properties that you can parse from KP
my @prop_list = qw(
    title kind year
    directors writers cast
    genres countries release_dates storyline rating
    top250
);

# init setters/getters
my %props;
foreach (@prop_list) {
    my $prop = $_;
    no strict 'refs';
    *$prop = sub {
        my $self = shift;
        if (@_) {
            my $tmp = shift;
            $props{ident $self}->{$prop} = $tmp;
        }
        return $props{ident $self}->{$prop};
    };
}

# default values
{
    my %_defaults = (
        # base class props
        cache           => 0,
        debug           => 0,
        error           => [],
        cache_exp       => '1 h',
        cache_root      => "/tmp",
        status          => 0,
        timeout         => 10,
        user_agent      => 'Mozilla/8.0',
        cookies         => "./cookies.txt",
        decode_html     => 1,
        encoding        => 'windows-1251',

        # derived class props
        host            => 'http://www.kinopoisk.ru',
        query           => 'http://www.kinopoisk.ru/level/1/film/',
#        search          => 'http://s.kinopoisk.ru/index.php?first=no&kp_query=',
        search          => 'http://s.kinopoisk.ru/level/7/type/all/find/',
        title_search    => 'level\/1\/film\/(\d+)',
    );
    sub _get_default_attrs { keys %_defaults }
    sub _get_default_value {
        my($self, $attr) = @_;
        return $_defaults{$attr};
    }
}

sub _init {
    my $self = shift;
    my %args = @_;
    croak "Film Kinopoisk ID or Title should be defined!"
        unless defined $args{crit} || defined $args{url};
    $self->SUPER::_init(%args);
    $props{ident $self} = {};

    $self->find_props(\%args);
    return;
}

sub DESTROY {
    my ($self) = @_;
    delete $props{ident $self};
    $self->SUPER::DESTROY();
    return;
}

sub create_url {
    my $self = shift;
    my ($args) = @_;
    my $url;
    my $crit = $args->{crit};
    unless (defined $crit) {
        say Dumper $args;
        croak "crit not defined";
    }
    $self->_show_message("crit =  [$crit]", 'DEBUG');
    $crit =~ tr/\ /\+/;
    my @chars = split //, $crit;
    foreach (@chars) {
        my $char = $_;
        if (ord $char < 0x7F) {}
        elsif (ord decode('utf8', encode('cp1251',$char) ) != 0xFFFD ) { # HACK
            $char = '&#'.ord($char).';' ;
        }
        else {
            $char = Encode::encode('cp1251',$char);
        }
        $_ = uri_escape($char, "^A-Za-z0-9\+\-\._\!");
    }
    my $crit_escaped = join '', @chars;
    $self->_show_message("crit_escaped =  [$crit_escaped]", 'DEBUG');

    if ($self->method eq 'search') {
        $url = $self->search.$crit_escaped;
    }
    elsif ($self->method eq 'query') {
        $url = $self->query.$crit_escaped;
    }
    $self->_show_message("url =  [$url]", 'DEBUG');
    return $url;
}

################################################################################

sub find_props {
    my $self = shift;
    my $args = shift || croak;
    $self->_show_message("finding properties", 'DEBUG');
    my $tree = $self->load_tree($args);
    return unless defined $tree;


    # Head part
    if (my $head = $tree->look_down('_tag', 'head') ) {
        my $done = $self->parse_head($head);
        return if $done;
    }

    # find code and url
    # TODO move to traverse and fnd_code
    my $title_search = $self->title_search;
    if (my $ul = $tree->look_down('_tag','ul','class','film_menu') ) {
        my $a = $ul->look_down('_tag','a');
        my $tmp = $a->attr('href');
        $tmp =~ s/level\/(\d+)\/film/level\/1\/film/x;
        my $url = $self->host.$tmp;
        $self->url( $url );
        $self->_show_message("URL: $url", 'DEBUG');
        my ($code) = $tmp =~ qr{$title_search};
        $self->code( $code );
        $self->_show_message("CODE: $code", 'DEBUG');
    }

    # Body part
    if (my $body = $tree->look_down('_tag', 'body') ) {
        $self->traverse($body);
    }
}

sub traverse {
#    say "traverse";
    my $self = shift;
    my $tag = shift;
    # TODO properties

#    return unless ref $_;
    if ($tag->tag eq 'h1' && $tag->attr('class') && $tag->attr('class') eq 'moviename-big' ) {
        $self->parse_title($tag) unless defined $self->title;
        return;
    }

    if ($tag->tag eq 'table' && $tag->attr('class') && $tag->attr('class') eq 'info' ) {
#        say "parse_table_info";
        $self->parse_table_info($tag);
        return;
    }
    if ($tag->tag eq 'td' && $tag->attr('class') && $tag->attr('class') eq 'actor_list' ) {
#        say "parse_cast";
        $self->parse_cast($tag);
        return;
    }

    foreach my $c ($tag->content_list) {
        $self->traverse($c) if ref $c; # ignore text nodes
    }
}

sub parse_head {
    my $self = shift;
    my $head = shift;
    my $done = 1;

    if (my $t = $head->look_down('_tag', 'title') ) {
        my $title = $t->as_trimmed_text;
        if ($title =~ /Результаты поиска/i) {
            if ($self->method ne 'search') {
                $self->_show_message("Go to search page ...", 'DEBUG');
            }
            else { # got search page
                $self->parse_search_results();
            }
            return $done;
        }
        #IMDb Top 250
        elsif ($title =~ /250 лучших фильмов/i) { #250 лучших фильмов на КиноПоиск.ru
            $self->parse_top250();
            return $done;
        }
    }
    return;
}

sub parse_search_results {
    my $self = shift;
    my $args = shift; # to filter results

    $self->_show_message("parsing search results", 'DEBUG');

    my $pattern = $self->_get_default_value('title_search');

    # get HTML tree for content;
    my $tree = $self->load_tree;


    my $el = $tree->look_down('_tag','div','class', 'block_left_pad' );
#    $el->dump;
    unless ($el) {
        $el = $tree->look_down('_tag','td','id', 'block_left_pad' );
    }
    unless ($el) {
        croak "WARNING: Can't parse search page";
    }

    # parse search results
    my @matched;
    my $count = 0;
    my $title_search = $self->title_search;
    my @results = $el->look_down('_tag','div','class', qr{search_results} );
    my @result;
    foreach (@results) {
        push @result, $_->look_down('_tag','div','class', 'info' );
    }

    foreach my $div (@result) {
        # get name
        my $a = $div->look_down('_tag','a','href', qr{$title_search} );
        next unless defined $a;

        my $url = $a->attr('href');
        $url =~ s/film\/(\d+)(.*)/film\/$1/;
        $url = $self->host.$url;
        my $code;
        if ($url =~ qr{$title_search} ) {
            $code = $1;
        }

        # get text
        my $text = $div->as_trimmed_text;

        # get year
        my $year;
        #<span class="year">2008</span>
        my $span = $div->look_down('_tag','span','class','year');
#        $span->dump;
        if (defined $span) {
            $year = $span->as_trimmed_text;
        }
        unless (defined $year) {
            if ( $text =~ /(\d{4})/ ) {
                $year = $1;
            }
        }
        # TODO add type: скорее всего вы искали и похожие результаты
        push @matched, {code=>$code, url=>$url, year=>$year, text=>$text};
        $count++;
    }
    $self->matched( \@matched );
}

sub parse_top250 {
    my $self = shift;
    $self->_show_message("Parsing kinopoisk top 250", 'DEBUG');
    my $tree = $self->load_tree;

    my @tr = $tree->look_down('_tag','tr','id', qr{top250_place_} );
    unless (@tr) {
        $self->_show_message("kp: Can't parse top 250");
        return;
    }

    my $title_search = $self->title_search;
    my %top250;
    foreach my $tr (@tr) {
        my @td = $tr->look_down('_tag', 'td');

        # get index
        my ($index) = $tr->attr('id') =~ /top250_place_(\d+)/i;
#        say $index;

        # get kp title code
        my $a = $tr->look_down('_tag','a','href', qr{$title_search} );
        next unless defined $a;

        my $url = $a->attr('href');
        $url =~ s/film\/(\d+)(.*)/film\/$1/;
        $url = $self->host.$url;
        my $code;
        if ($url =~ qr{$title_search} ) {
            $code = $1;
        }
        $top250{$code} = $index;
    }

    $self->top250(\%top250);
}

################################################################################
####  Parsing single props
################################################################################

sub parse_table_info {
    my $self = shift;
    my $tag = shift;
    $self->_show_message("parse_table_info", 'DEBUG');
#    $tag->dump;

    if (my $a = $tag->look_down('_tag','a', 'href', qr{m_act%5Byear%5D}) ) {
        my $text = $a->as_trimmed_text;
#        say $text;
        $self->year($text);
    }
    if (my @a = $tag->look_down('_tag','a', 'href', qr{m_act%5Bcountry%5D}) ) {
        my @countries;
        foreach (@a) {
#            say $_->as_trimmed_text;
            push @countries, $_->as_trimmed_text;
        }
        $self->countries(\@countries);
    }
  if (my @a = $tag->look_down('_tag','a', 'href', qr{m_act%5Bgenre%5D}) ) {
        my @genres;
        foreach (@a) {
#            say $_->as_trimmed_text;
            push @genres, $_->as_trimmed_text;
        }
        $self->genres(\@genres);
    }
    # TODO
    # SKIPPED country
    # SKIPPED etc...
}

sub parse_title {
    my $self = shift;
    my $tag = shift;
    $self->_show_message("parse_title", 'DEBUG');
    # get title
#    $tag->dump;
    my @nodes = $tag->content_list;
    foreach (@nodes) {
        next if ref $_;
        my $title = $_;
        $title =~ s/^\s+//;
        $title =~ s/\s+$//;
        $self->title($title);
        $self->_show_message("TITLE: $title", 'DEBUG');
        last;
    }

    # get kind
    my $text = $tag->as_trimmed_text;
    if ($text =~ /\(сериал/i) {
        $self->kind('series');
    }
    elsif ($text =~ /\(видео/i) {
        $self->kind('video');
    }
    elsif ($text =~ /\(тв/i) {
        $self->kind('tv');
    }
    else {
        $self->kind('movie');
    }
}

sub parse_cast {
    my $self = shift;
    my $tag = shift;
    my %cast;
    $self->_show_message("parse_cast", 'DEBUG');
    my @a = $tag->look_down('_tag', 'a', 'href', qr{\/level\/4\/people});
    foreach my $a (@a) {
        my $text = $a->as_trimmed_text;
        $cast{$text}='';
    }
    $self->cast(\%cast);
}


1;