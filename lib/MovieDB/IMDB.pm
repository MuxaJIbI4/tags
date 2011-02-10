#/usr/bin/perl -w
package MovieDB::IMDB;
use base qw(MovieDB::BaseClass);
use strict;
use warnings;
# for building "inside-out" objects
use Class::Std::Utils;
# for HTML parsing
use HTML::TreeBuilder;
# for url creating
use URI::Escape; # uri_escape()  uri_unescape()
# devel
use Carp;
use Data::Dumper;
use feature ':5.10';
use encoding 'utf8';

# properties that you can parse from IMDB
my @prop_list = qw(
title kind type year
genres
rating
directors writers stars countries languages release_dates
cast
storyline
also_known_as
top250
);

# init setters/getters
my %props;
foreach (@prop_list) {
    my $prop = $_;
#    $props{$prop} = undef;
    no strict 'refs';
    *$prop = sub {
        my $self = shift;
        if (@_) {
            my $tmp = shift;
#            say Dumper $tmp;
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
        encoding        => 'utf8',

        # derived class props
        host            => 'http://www.imdb.com',
        query           => 'http://www.imdb.com/title/tt',
        search          => 'http://www.imdb.com/find?s=tt&q=',
        title_search    => 'title\/tt(\d+)',

        _official_sites => [],
        _release_dates  => [],
        _duration       => [],
        _top_info       => [],

        matched         =>  [],
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
    croak "Film IMDB ID or Title should be defined!"
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
#    say __PACKAGE__.": create_url";
    my $self = shift;
    my ($args) = @_;
    my $crit = $args->{crit};
    my $url;
    unless (defined $crit) {
        say Dumper $args;
        croak "crit not defined";
    }
#    say "crit = ".$crit;
    my @chars = split //, $crit;
    foreach (@chars) {
        my $char = $_;
        if (ord $char > 0xFF) {
            $char = '&#'.ord($char).';' ;
        }
        $_ = uri_escape($char, "^A-Za-z0-9\+\-\._\!\'");
    }
    my $crit_escaped = join '', @chars;
#    say $crit_escaped;
    if ($self->method eq 'search') {
        $url = $self->search.$crit_escaped;
#        say $url;
    }
    elsif ($self->method eq 'query') {
        $url = $self->query.$crit_escaped;
#        say $url;
    }
#    say $url;
    return $url;
}


################################################################################

sub find_props {
    my $self = shift;
    my $args = shift || croak;

    my $tree = $self->load_tree($args);
    return unless defined $tree;

    # Head part
    # find url, code, title, possibly type?
    if (my $head = $tree->look_down('_tag', 'head') ) {
        my $done = $self->parse_head($head);
        return if $done;
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
    return unless ref $_;
    say $tag->tag;
    if ($tag->tag eq 'div' && defined $tag->attr('class') && $tag->attr('class') eq 'article title-overview' ) {
        $self->parse_title_overview($tag);
        return;
    }
    if ($tag->tag eq 'div' && defined $tag->attr('class') && $tag->attr('class') eq 'article') {
        $self->parse_article($tag);
        return;
    }
    # TODO other
    foreach my $c ($tag->content_list) {
        $self->traverse($c) if ref $c; # ignore text nodes
    }
}

sub parse_head {
#    say "parse_head";
    my $self = shift;
    my $head = shift;
    my $done = 1;

    if (my $t = $head->look_down('_tag', 'title') ) {
        my $title = $t->as_trimmed_text;
        if ($title =~ /imdb\s+title\s+search/i) {
            if ($self->method ne 'search') {
                $self->_show_message("Go to search page ...", 'DEBUG');
            }
            else { # got search page
                $self->parse_search_results;
            }
            return $done;
        }
        elsif ($title =~ /IMDb Top 250/i) {
            $self->parse_top250();
            return $done;
        }
        else {
               $self->parse_title($title);
        }
    }

    if (my $meta =  $head->look_down('_tag', 'meta', 'property', 'og:type') ) {
        $self->type ( $meta->attr('content') );
    }
    # TODO link rel ?
    if (my $meta =  $head->look_down('_tag', 'meta', 'property', 'og:url') ) {
#        say $meta->attr('content');
        if ($meta->attr('content')=~/^http:\/\/www\.imdb\.com\/title\/tt(\d+)/i) {
            $self->url( "http://www.imdb.com/title/tt$1" );
            $self->code($1);
#            say "DEVEL : code : $1";
        }
        else {
#            say "DEVEL : not found code on page";
        }
    }
    return;
}


=item
Parses search results, ? download first one
=cut
sub parse_search_results {
    my $self = shift;
    my $args = shift; # to filter results

    my $pattern = $self->_get_default_value('title_search');
    # get HTML tree for content;
    my $tree = $self->load_tree;

    my @matched;
    my $count = 0;
    my @p = $tree->look_down('_tag', 'p',
        sub {defined $_[0]->right && $_[0]->right->tag eq 'table' });
    # different kinds of results
    foreach my $p (@p) {
        my $type = $p->as_trimmed_text;
        $type =~ s/\(Displaying.*\)//i;
        trim(\$type);
#        say "found type=>$type<";
        my $list= [];
        my @tr = $p->right->look_down('_tag','tr');
        foreach my $tr (@tr) {
            my ($link, $text,$year);
            my $a = $tr->look_down('_tag','a');
            next unless $a->attr('href') =~ /$pattern/i;
            $link = $self->host.$a->attr('href');
            $text = $tr->content_array_ref->[2]->as_trimmed_text;
            if ($text =~ /\((\d{4})/) {
                $year = $1;
            }
            push @$list, {url=>$link, year=>$year, text=>$text};
            $count++;
        }
        if (@$list) {
            push @matched, $type;
            push @matched, @$list;
        }
    }
    $self->matched( \@matched );
}


sub parse_top250 {
    my $self = shift;
    $self->_show_message("imdb: Parsing top 250", 'DEBUG');
    my $tree = $self->load_tree;

    my $div = $tree->look_down('_tag','div','id', 'main' );
    my @tr = $div->look_down('_tag','tr');
    unless (@tr) {
        $self->_show_message("imdb: Can't parse top 250");
        return;
    }
    my $title_search = $self->title_search;
    my %top250;
    foreach my $tr (@tr) {
        my @td = $tr->look_down('_tag', 'td');
        return unless @td;

        # get imdb title code
        my $a = $tr->look_down('_tag','a','href', qr{$title_search} );
        next unless defined $a;
        my $url = $a->attr('href');
        $url = $self->host.$url;
        my $code;
        if ($url =~ qr{$title_search} ) {
            $code = $1;
        }

        # get index
        my $index = $td[0]->as_trimmed_text;
        $index =~ s/\.$//i;

        $top250{$code} = $index;
    }
    $self->top250(\%top250);
}



sub parse_title_overview {
    my $self = shift;
    my $tag = shift;

    # rating
    $self->parse_rating($tag);

    # director
    $self->parse_directors($tag);

    # writer
    $self->parse_writers($tag);

    # stars
    $self->parse_stars($tag);
}

sub parse_article {
    my $self = shift;
    my $tag = shift;
    my $text = $tag->as_text;
    return unless my $h2 = $tag->look_down('_tag','h2');
    $text = $h2->as_trimmed_text;
#    say "DEVEL: Article : >$text<";
    given ($text) {
#        say "DEVEL: Article-text : >$text<";
        when (/cast/i) {
            $self->parse_cast($tag);
        }
        when (/storyline/i) {
            $self->parse_storyline($tag);
        }
        when (/details/i) {
            $self->parse_details($tag);
        }
        when (/fun facts/i) {
            $self->parse_fun_facts($tag);
        }
        default {
        }
    }
}

sub parse_cast {
    my $self = shift;
    my $tag = shift;
    my $text = $tag->as_trimmed_text;
#    say "DEVEL: cast : >$text<";
    my @a = $tag->look_down('_tag','td','class', 'name');
    my %cast;
    foreach (@a) {
#        $_->dump;
        $cast{$_->as_trimmed_text} = '';
    }
    if ($self->cast) {
        my %tmp = %{$self->cast};
        $tmp{$_}='' foreach (keys %cast);
        $self->cast(\%tmp);
    }
    else {
        $self->cast(\%cast);
    }
    # TODO Fullcast
}


sub parse_storyline {
#    say "storyline";
    my $self = shift;
    my $tag = shift;
    my $text = $tag->as_trimmed_text;
#    say "DEVEL: cast : >$text<";
    if (my $p = $tag->look_down('_tag','p') ) {
        $text = $p->as_trimmed_text;
#        say "DEVEL: storyline : >$text<";
        $self->storyline($text);
    }

    # genres
    $self->parse_genres($tag);

    # TODO plotsummary >> /plotsummary
    # TODO plot synopsis >> /synopsis
    # TODO keywords
    # TODO Taglines
    # SKIPPED MPAA
}

sub parse_details {
    my $self = shift;
    my $tag = shift;
    my @h4 = $tag->look_down('_tag','h4', 'class', 'inline');

    # country
    $self->parse_countries($tag);

    #language
    # $self->parse_language($tag);

    #release dates
    # $self->release_dates($tag);

    # also known as
    $self->parse_also_known_as($tag);

    # Official sites

    # filming locations
}

sub parse_fun_facts {
    my $self = shift;
    my $tag = shift;
#    say "DEVEL: fun facts : >$text<";
    # Trivia;
    # Goofs
    # Quotes
    # Connections
    # soundtracks
}




################################################################################
####  Parsing single props
################################################################################

sub parse_title {
#    say "parse_title";
    my $self = shift;
    my $title = shift;
#    say $title;
    #   'ndash;'    => chr(8211),
    my $ndash = chr(8211);
    $title =~ s/$ndash/-/g;
     # quotemeta ?
    if ($title =~ / (.*?) \s+
                    \( (\d{4}) \) /x)
        {
        my $tmp = $1;
        normalize(\$tmp);
#        say $tmp;
        $self->title($tmp);
        $self->year($2);
#       print "kind: >>$3<<\n title: >>$1<<\n year: >>$2<<\n";
    }
    unless ( $self->title() ) {
        if ($title =~ /(.*) \s+
                       \( (.*?)? \s? ([0-9\-]*) \s? \) /x) {
            my $tmp = $1;
            normalize(\$tmp);
#            say $tmp;
            $self->title($tmp);
            $self->kind($2);
            $self->year ($3);
#            say $self->kind;
#           print "kind: >>$2<<\n title: >>$1<<\n year: >>$3<<\n";
        }
    }

    $self->kind('movie') unless $self->kind(); # Default kind should be movie
    unless ( $self->title() ) {
        say "Warning : not found title in >>> $title";
    }
    # TODO - episodes of shows
#    if( $self->title() =~ /\"[^\"]+\"(\s+.+\s+)?/ ) {
#        $self->kind() = $1 ? 'E' : 'S';
#    }
}

sub parse_rating {
    my $self = shift;
    my $tag = shift || $self->tree;
    if (my $span = $tag->look_down('_tag','span','class', 'rating-rating') ) {
        my $text = join ' ', grep {!ref $_ } $span->content_list;
#        say "DEVEL : rating : $text";
        $self->rating($text);
    }
}

sub parse_directors {
    my $self = shift;
    my $tag = shift;
    if (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /director/i} )) {
        my @directors;
        my @a = $h4->parent->look_down('_tag','a', 'href', qr/^\/name/i);
        foreach my $a (@a) {
#            say "DEVEL : director : ".$a->as_trimmed_text;
            push @directors, $a->as_trimmed_text;
        }
#        say Dumper @directors;
        $self->directors(\@directors);
    }
}

sub parse_writers {
    my $self = shift;
    my $tag = shift || $self->tree;
    if (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /writer/i} )) {
        my @writers;
        my @a = $h4->parent->look_down('_tag','a', 'href', qr/^\/name/i);
        foreach my $a (@a) {
#            say "DEVEL : writer : ".$a->as_trimmed_text;
            push @writers, $a->as_trimmed_text;
        }
#        say Dumper @writers;
        $self->writers(\@writers);
    }
}

sub parse_stars {
    my $self = shift;
    my $tag = shift || $self->tree;
    if (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /star/i} )) {
        my %stars;
        my @a = $h4->parent->look_down('_tag','a', 'href', qr/^\/name/i);
        foreach my $a (@a) {
#            say "DEVEL : star : ".$a->as_trimmed_text;
            $stars{$a->as_trimmed_text} = '';
        }

        $self->stars(\%stars);

        # add to cast
        if ($self->cast) {
            my %cast = %{$self->cast};
            $cast{$_}='' foreach keys %stars;
            $self->cast(\%cast);
        }
        else {
            $self->cast(\%stars);
        }
    }
}

sub parse_genres {
    my $self = shift;
    my $tag = shift || $self->tree;
    # genres
    if (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /genres/i} )) {
        my @genres;
        my @a = $h4->parent->look_down('_tag','a', 'href', qr/^\/genre/i);
        foreach my $a (@a) {
#            say "DEVEL : genre : ".$a->as_trimmed_text;
            push @genres, $a->as_trimmed_text;
        }
#        say Dumper @genres;
        $self->genres(\@genres);
    }
}

sub parse_countries {
    my $self = shift;
    my $tag = shift || $self->tree;
    # countries
    if (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /country/i} )) {
        my @countries;
        my @a = $h4->parent->look_down('_tag','a', 'href', qr/^\/country/i);
        foreach my $a (@a) {
#            say "DEVEL : countrie : ".$a->as_trimmed_text;
            push @countries, $a->as_trimmed_text;
        }
#        say Dumper @countries;
        $self->countries(\@countries);
    }
}

#################################################################################
####  Parsing external urls
################################################################################

sub parse_also_known_as {
    my $self = shift;
    my $tag = shift || $self->tree;

    my @akas;
    # using title extra as one of AKAs
    if (my $span = $self->tree->look_down('_tag', 'span', 'class', 'title-extra') ) {
        my $aka = join ' ', grep {!ref $_ } $span->content_list;
        normalize(\$aka);
        my $where;
        if (my $i = $span->look_down('_tag','i')) {
            $where = $i->as_text;
        }
        if ($aka) {
#            say "aka   = $aka<";
#            say "where = $where<";
            push @akas, {aka => $aka, where => $where};
        }

    }

    # search for As Know As  string
    if ($tag->look_down('_tag','a', 'href' , 'releaseinfo#akas') ) {
        # parsing external url for additional AKAs
        $self->also_known_as( \@akas );
        $self->parse_releaseinfo;
    }
    elsif (my $h4 = $tag->look_down('_tag','h4', sub { $_[0]->as_text =~ /also known as/i} )) {
        my @tmp = $h4->parent->content_array_ref;
        my $text = ${$tmp[0]}[1];
        trim(\$text);
#        say "aka   = $text<";
#        say "where = ''<";
        push @akas, {aka => $text, where => 'main page aka'};
        $self->also_known_as( \@akas );
    }
    else {
        say "No known AKAs";
        $self->also_known_as( \@akas );
    }

}

sub parse_releaseinfo {
    my $self = shift;

    my $tree = $self->load_tree( {url => $self->url.'/releaseinfo',crit => $self->code} );
    return unless defined $tree;

    my @akas = @{ $self->also_known_as};

    # Searching header right befire AKAS table.
    if (my $a = $tree->look_down('_tag','a', 'name' , 'akas') ) {
        my $table = $a->parent->right;
        my @tr = $table->look_down('_tag','tr');
        my ($tr, $td, $aka, $where);
        foreach $tr (@tr) {
            my @td = $tr->look_down('_tag','td');
            $aka = $td[0]->as_trimmed_text;
            normalize(\$aka);
            $where = $td[1]->as_trimmed_text;
#            say "$aka:\t $where";say "aka   = $aka<";say "where = $where<";
            push @akas, {aka => $aka, where => $where};
        }
    }
    $self->also_known_as( \@akas );
}


=item episodes()
Retrieve episodes info list each element of which is hash reference for tv series -
{ id => <ID>, title => <Title>, season => <Season>, episode => <Episode>, date => <Date>, plot => <Plot> }:
    my @episodes = @{ $film->episodes() };
=cut

#sub episodes {
#    my CLASS_NAME $self = shift;
#
#    return if !$self->kind or $self->kind ne "tv series";
#
#    unless($self->{_episodes}) {
#        my $page;
#        $page = $self->_cacheObj->get($self->code . '_episodes') if $self->_cache;
#
#        unless($page) {
#            my $url = "http://". $self->{host} . "/" . $self->{query} .  $self->code . "/episodes";
#            $self->_show_message("URL for episodes is $url ...", 'DEBUG');
#
#            $page = $self->_get_page_from_internet($url);
#            $self->_cacheObj->set($self->code.'_episodes', $page, $self->_cache_exp) if $self->_cache;
#        }
#
#        my $parser = $self->_parser(FORCED, \$page);
#        while(my $tag = $parser->get_tag('h3')) {
#            my $id;
#            my($season, $episode);
#            next unless(($season, $episode) = $parser->get_text =~ /Season\s+(.*?),\s+Episode\s+([^:]+)/);
#            my $imdb_tag = $parser->get_tag('a');
#            ($id) = $imdb_tag->[1]->{href} =~ /(\d+)/ if $imdb_tag->[1]->{href};
#            my $title = $parser->get_trimmed_text;
#            $parser->get_tag('strong');
#            my($date) = $parser->get_trimmed_text;
#            $parser->get_tag('br');
#            my $plot = $parser->get_trimmed_text;
#
#            push @{ $self->{_episodes} }, {
#                                season     => $season,
#                                episode => $episode,
#                                id         => $id,
#                                title     => $title,
#                                date     => $date,
#                                plot     => $plot
#                            };
#        }
#    }
#
#    return $self->{_episodes};
#}

=item episodeof()
Retrieve parent tv series list each element of which is hash reference for episode -
{ id => <ID>, title => <Title>, year => <Year> }:
    my @tvseries = @{ $film->episodeof() };
=cut

#sub episodeof {
#   my CLASS_NAME $self = shift;
#   my $forced = shift || 0;
#
#   return if !$self->kind or $self->kind ne "episode";
#
#   if($forced) {
#       my($episodeof, $title, $year, $episode, $season, $id);
#       my($parser) = $self->_parser(FORCED);
#
#       while($parser->get_tag(MAIN_TAG)) {
#           last if $parser->get_text =~ /^TV Series/i;
#       }
#
#       while(my $tag = $parser->get_tag('a')) {
#           ($title, $year) = ($1, $2) if $parser->get_text =~ m!(.*?)\s+\(([\d\?]{4}).*?\)!;
#           last unless $tag->[1]{href} =~ /title/i;
#           ($id) = $tag->[1]{href} =~ /(\d+)/;
#       }
#
#       #start again
#       $parser = $self->_parser(FORCED);
#       while($parser->get_tag(MAIN_TAG)) {
#           last if $parser->get_text =~ /^Original Air Date/i;
#       }
#
#       $parser->get_token;
#       ($season, $episode) = $parser->get_text =~ /\(Season\s+(\d+),\s+Episode\s+(\d+)/;
#
#       push @{ $self->{_episodeof} }, {title => $title, year => $year, id => $id, season => $season, episode => $episode};
#   }
#
#   return $self->{_episodeof};
#}

# TODO - pass str to trim by ref
sub trim {
   my ($str_ref) = @_;
   $$str_ref =~ s/^\s+//;
   $$str_ref =~ s/\s+$//;
}

sub normalize  {
    my ($str_ref) = @_;
    trim($str_ref);

    $$str_ref =~ s/"$//g;
    $$str_ref =~ s/^"//g;
}

1;